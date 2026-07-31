using FlootyAbstract: OpenAICompatibleProvider

mutable struct ChutesProvider <: OpenAICompatibleProvider
    baseURL::String
    apiKey::String
    timeout::Int64
    chute::String

    function ChutesProvider(; baseURL::String="https://llm.chutes.ai", apiKey::String="", timeout::Int64=120, chute::String="")
        new(rstrip(baseURL, '/'), apiKey, timeout, chute)
    end
end

StructTypes.StructType(::Type{ChutesProvider}) = StructTypes.Mutable()

FlootyAbstract.provider_name(provider::ChutesProvider) = :chutes

function FlootyAbstract.create_provider_instance(::Val{:chutes}; config::Dict{Symbol, Any} = Dict{Symbol, Any}())
    ChutesProvider(
        baseURL = get(config, :baseURL, "https://llm.chutes.ai"),
        apiKey = get(config, :apiKey, get(ENV, "CHUTES_API_TOKEN", "")),
        timeout = get(config, :timeout, 120),
        chute = get(config, :chute, "")
    )
end

function FlootyAbstract.list_provider_models(::Val{:chutes}, config::Dict{Symbol,Any})
    baseURL = get(config, :baseURL, "https://llm.chutes.ai")
    apiKey = get(config, :apiKey, "")
    timeout = get(config, :timeout, 120)
    ttl = get(config, :cache_ttl, DEFAULT_CACHE_TTL)

    # Use cached model list if available
    cache_key = "chutes:$(baseURL):$(length(apiKey))"
    cached, hit = get_cached_models(cache_key, ttl)
    if hit
        return cached
    end

    # Fetch fresh models
    provider = ChutesProvider(; baseURL=baseURL, apiKey=apiKey, timeout=timeout)
    models = list(provider)

    cache_models(cache_key, models)
    return models
end

# Chutes uses the same chat implementation as OpenAI but adds custom headers
function chat(provider::ChutesProvider, messages::Vector{OpenAIMessage},
              model::String,
              stream::Bool=false;
              temperature::Union{Float64, Nothing}=nothing,
              top_p::Union{Float64, Nothing}=nothing,
              max_tokens::Union{Int, Nothing}=nothing,
              tools::Union{Vector{OpenAITool}, Nothing}=nothing,
              tool_choice::Union{String, Nothing}=nothing,
              response_format::Union{Dict{String,Any}, Nothing}=nothing,
              kwargs...
)
    request = ChatCompletionRequest(
        model=model,
        messages=messages,
        stream=stream,
        temperature=temperature,
        top_p=top_p,
        max_tokens=max_tokens,
        tools=tools,
        tool_choice=tool_choice,
        response_format=response_format
    )

    url = string(provider.baseURL, "/v1/chat/completions")
    headers = [
        "Content-Type" => "application/json",
        "Authorization" => "Bearer $(provider.apiKey)"
    ]
    
    # Add chute-specific header if specified
    if !isempty(provider.chute)
        push!(headers, "X-Chute" => provider.chute)
    end

    if stream
        return Channel{ChatCompletionChunk}(Inf) do ch
            try
                HTTP.open("POST", url, headers=headers; connect_timeout=Int(provider.timeout), readtimeout=Int(provider.timeout)) do jsonstream
                    write(jsonstream, JSON3.write(request))
                    closewrite(jsonstream)
                    HTTP.startread(jsonstream)
                    
                    while !eof(jsonstream)
                        data = String(readavailable(jsonstream))
                        isempty(data) && continue
                        
                        # Parse SSE format
                        for line in split(data, "\n")
                            line = strip(line)
                            isempty(line) && continue
                            startswith(line, "data: ") || continue
                            
                            data_str = strip(line[7:end])
                            if data_str == "[DONE]"
                                close(ch)
                                return
                            end
                            
                            try
                                chunk_data = JSON3.read(data_str)
                                put!(ch, JSON3.read(JSON3.write(chunk_data), ChatCompletionChunk))
                            catch e
                                @debug "Failed to parse SSE chunk" error=e
                            end
                        end
                    end
                end
            catch e
                @error "Chutes streaming error" error=e
                close(ch)
            end
        end
    else
        response = try
            HTTP.post(url, headers, JSON3.write(request); readtimeout=provider.timeout)
        catch e
            if e isa HTTP.StatusError
                error_body = String(e.response.body)
                try
                    error_json = JSON3.read(error_body)
                    error_message = get(error_json, :error, error_body) |> x -> get(x, :message, error_body)
                    throw(OpenAIError(error_message, e.status, "api_error"))
                catch
                    throw(OpenAIError(error_body, e.status, "unknown"))
                end
            else
                rethrow(e)
            end
        end
        
        if response.status != 200
            error_body = String(response.body)
            throw(OpenAIError(error_body, response.status, "api_error"))
        end
        
        response_data = JSON3.read(String(response.body))
        return JSON3.read(JSON3.write(response_data), ChatCompletionResponse)
    end
end

function list(provider::ChutesProvider)
    url = string(provider.baseURL, "/v1/models")
    headers = [
        "Content-Type" => "application/json",
        "Authorization" => "Bearer $(provider.apiKey)"
    ]
    
    try
        response = HTTP.get(url, headers; readtimeout=provider.timeout)
        
        if response.status != 200
            @warn "Chutes API returned HTTP $(response.status) when listing models"
            return OpenAIModel[]
        end
        
        data = JSON3.read(String(response.body))
        models = OpenAIModel[]
        
        for m in get(data, :data, [])
            push!(models, OpenAIModel(
                m.id,
                get(m, :object, "model"),
                get(m, :created, 0),
                "chutes"
            ))
        end
        
        return models
    catch e
        @warn "Failed to list Chutes models" exception=e
        # Return default Chutes models as fallback
        return OpenAIModel[
            OpenAIModel("Qwen/Qwen3-Coder-Next", "model", 0, "chutes"),
            OpenAIModel("moonshotai/Kimi-K2.5-TEE", "model", 0, "chutes"),
            OpenAIModel("zai-org/GLM-5-TEE", "model", 0, "chutes"),
            OpenAIModel("XiaomiMiMo/MiMo-V2-Flash-TEE", "model", 0, "chutes"),
            OpenAIModel("nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16", "model", 0, "chutes"),
        ]
    end
end

# Helper to create messages (delegates to OpenAI implementation)
FlootyAbstract.create_message(provider::ChutesProvider, role::String, content::String; kwargs...) =
    OpenAIMessage(role=role, content=content)

# Build tools for Chutes (uses OpenAI format since Chutes is OpenAI-compatible)
function FlootyAbstract.build_tool(tool::AbstractTool, provider::ChutesProvider)
    # Delegate to OpenAI implementation since Chutes uses OpenAI format
    openai_provider = OpenAIProvider(baseURL=provider.baseURL, apiKey=provider.apiKey, timeout=provider.timeout)
    FlootyAbstract.build_tool(tool, openai_provider)
end

FlootyAbstract.create_message(provider::ChutesProvider, role::String, content::String, attachments::Vector{<:AbstractAttachment}; kwargs...) =
    FlootyAbstract.create_message(OpenAIProvider(), role, content, attachments; kwargs...)

FlootyAbstract.create_image_data(provider::ChutesProvider, path::String) = OpenAIImageContent("data:image/png;base64,$(Base64.base64encode(read(path)))")

FlootyAbstract.create_attachments(provider::ChutesProvider, paths::Vector{String}, mime_types::Vector{String}) =
    FlootyAbstract.create_attachments(OpenAIProvider(), paths, mime_types)

FlootyAbstract.create_embedder(provider::ChutesProvider, model::String; kwargs...) =
    OpenAIEmbedder(OpenAIProvider(baseURL=provider.baseURL, apiKey=provider.apiKey, timeout=provider.timeout), model)

# Implement chat_stream for Chutes provider
function FlootyAbstract.chat_stream(provider::ChutesProvider, model::String, messages::Vector{<:AbstractMessage},
                                    stream::Bool=false, format=nothing, options=nothing, tools=nothing)
    # Convert AbstractMessage to OpenAIMessage
    openai_messages = OpenAIMessage[]
    for m in messages
        if m isa OpenAIMessage
            push!(openai_messages, m)
        else
            content_val = FlootyAbstract.content(m)
            push!(openai_messages, OpenAIMessage(role=FlootyAbstract.role(m), content=content_val))
        end
    end
    
    # Convert tools to OpenAITool if provided
    openai_tools = if tools === nothing
        nothing
    else
        map(t -> FlootyAbstract.build_tool(t, provider), tools)
    end
    
    # Call the Chutes-specific chat function
    chat(provider, openai_messages, model, stream; tools=openai_tools)
end
