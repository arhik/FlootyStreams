using HTTP
using JSON3

# Helper function to handle HTTP requests
function _request(provider::OpenAIProvider, method::String, endpoint::String, body=nothing; stream::Bool=false)
    url = string(provider.baseURL, endpoint)
    headers = [
        "Content-Type" => "application/json",
        "Authorization" => "Bearer $(provider.apiKey)"
    ]
    
    try
        if stream
            return Channel(Inf) do channel
                HTTP.open(method, url, headers=headers) do jsonstream
                    if body !== nothing
                        write(jsonstream, JSON3.write(body))
                    end
                    closewrite(jsonstream)
                    r = startread(jsonstream)
                    while !eof(jsonstream)
                        line = readline(jsonstream)
                        isempty(line) && continue
                        # Handle SSE format: "data: {...}"
                        if startswith(line, "data: ")
                            data_str = strip(line[7:end])
                            if data_str == "[DONE]"
                                break
                            end
                            try
                                data = JSON3.read(data_str)
                                put!(channel, data)
                            catch e
                                @warn "Failed to parse SSE data: $data_str" exception=e
                            end
                        end
                    end
                end
            end
        end
        
        response = if body !== nothing
            HTTP.request(method, url, headers, JSON3.write(body); readtimeout=provider.timeout)
        else
            HTTP.request(method, url, headers; readtimeout=provider.timeout)
        end
        return JSON3.read(String(response.body))
    catch e
        if e isa HTTP.StatusError
            error_body = String(e.response.body)
            try
                error_json = JSON3.read(error_body)
                error_type = get(error_json, :error, Dict()) |> x -> get(x, :type, "unknown")
                error_message = get(error_json, :error, Dict()) |> x -> get(x, :message, error_body)
                throw(OpenAIError(error_message, e.status, error_type))
            catch
                throw(OpenAIError(error_body, e.status, "unknown"))
            end
        else
            rethrow(e)
        end
    end
end

function chat(provider::OpenAIProvider, messages::Vector{OpenAIMessage},
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

    if stream
        response = _request(provider, "POST", "/chat/completions", request, stream=true)
        return Channel{ChatCompletionChunk}(Inf) do ch
            for chunk in response
                put!(ch, JSON3.read(JSON3.write(chunk), ChatCompletionChunk))
            end
        end
    else
        response_data = _request(provider, "POST", "/chat/completions", request)
        return JSON3.read(JSON3.write(response_data), ChatCompletionResponse)
    end
end

function embed(provider::OpenAIProvider, text::String, model::String="text-embedding-3-small")
    request = EmbeddingRequest(
        model=model,
        input=text
    )
    response = _request(provider, "POST", "/embeddings", request)
    return JSON3.read(JSON3.write(response), EmbeddingResponse)
end

function embed(provider::OpenAIProvider, texts::Vector{String}, model::String="text-embedding-3-small")
    request = EmbeddingRequest(
        model=model,
        input=texts
    )
    response = _request(provider, "POST", "/embeddings", request)
    return JSON3.read(JSON3.write(response), EmbeddingResponse)
end

function list(provider::OpenAIProvider)
    try
        response_data = _request(provider, "GET", "/models")
        # Manually parse since external API doesn't have _type field
        models = OpenAIModel[]
        for m in get(response_data, :data, [])
            push!(models, OpenAIModel(
                id = m.id,
                object = get(m, :object, "model"),
                created = get(m, :created, 0),
                owned_by = get(m, :owned_by, "openai")
            ))
        end
        return models
    catch e
        rethrow(e)
    end
end

function retrieve_model(provider::OpenAIProvider, model::String)
    try
        response_data = _request(provider, "GET", "/models/$model")
        return JSON3.read(JSON3.write(response_data), OpenAIModel)
    catch e
        rethrow(e)
    end
end
