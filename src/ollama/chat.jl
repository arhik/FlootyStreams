using HTTP
using JSON3

# Helper function to handle HTTP requests
function _request(provider::OllamaProvider, method::String, endpoint::String, body=nothing; stream::Bool=false)
    url = string(provider.baseURL, endpoint)
    headers = ["Content-Type" => "application/json"]
    try
        if stream
            return Channel(Inf) do channel
                HTTP.open(method, url, headers=headers) do jsonstream
                    write(jsonstream, JSON3.write(body))
                    closewrite(jsonstream)
                    r = startread(jsonstream)
                    while !eof(jsonstream)
                        a = readavailable(jsonstream)
                        c = JSON3.read(a)
                        put!(channel, c)  # Use synchronous put! instead of @async
                        if c.done == true
                            break
                        end
                    end
                end
            end
        end
        response = if !isnothing(body)
            HTTP.request(method, url, headers, JSON3.write(body); readtimeout=provider.timeout)
        else
            HTTP.request(method, url, headers; readtimeout=provider.timeout)
        end
        return JSON3.read(String(response.body))
    catch e
        if e isa HTTP.StatusError
            throw(OllamaError(String(e.response.body), e.status))
        else
            rethrow(e)
        end
    end
end

function generate(provider::OllamaProvider, prompt::String,
                 model::String,
                 system::Union{String, Nothing}=nothing,
                 template::Union{String, Nothing}=nothing,
                 options::Dict{String, Any}=Dict{String, Any}(),
                 stream::Bool=false,
                 format::Union{OrderedDict, Nothing}=nothing)

    request = GenerateRequest(
        model=model,
        prompt=prompt,
        system=system,
        template=template,
        options=options,
        stream=stream,
        format=format
    )

    if stream
        response = _request(provider, "POST", "/api/generate", request, stream=true)
        return Channel{Any}(Inf) do ch
            for i in response
                put!(ch, JSON3.read(JSON3.write(i), GenerateResponse))  # Use synchronous put! instead of @async
            end
        end
    else
        response = _request(provider, "POST", "/api/generate", request)
        return GenerateResponse(; response...)
    end
end

function chat(provider::OllamaProvider, messages::Vector{OllamaMessage},
              model::String,
              stream::Bool=false,
              format::Union{Nothing, OrderedDict}=nothing,
              options::Union{Nothing, Dict{String,Any}}=nothing,
              tools::Union{Vector{OllamaTool}, Nothing}=nothing
)
    request = ChatRequest(
        model=model,
        messages=messages,
        stream=stream,
        format=format,
        options=options,
        tools=tools
    )

    if stream
        response = _request(provider, "POST", "/api/chat", request, stream=true)
        return Channel{ChatResponse}(Inf) do ch
            for i in response
                put!(ch, JSON3.read(JSON3.write(i), ChatResponse))  # Use synchronous put! instead of @async
            end
        end
    else
        response_data = _request(provider, "POST", "/api/chat", request)
        return JSON3.read(JSON3.write(response_data), ChatResponse)
    end
end

function embed(provider::OllamaProvider, text::String,
              model::String,
              options::Union{Dict{String,Any}, Nothing}=nothing)

    request = EmbedRequest(
        model=model,
        input=text,
        options=options
    )

    response = _request(provider, "POST", "/api/embed", request)
    return response
end

function embed(provider::OllamaProvider, text::Vector{String}, model::String,  options::Union{Dict{String,Any}, Nothing}=nothing)
    request = EmbedRequest(
        model=model,
        input=text,
        options=options
    )
    response = _request(provider, "POST", "/api/embed", request)
    return response
end

function pull(provider::OllamaProvider, model::String; stream::Bool=false)
    if stream
        response = _request(provider, "POST", "/api/pull", Dict("name" => model), stream=true)
        return Channel(32) do channel
            for line in eachline(response.body)
                isempty(line) && continue
                status = JSON3.read(line)
                put!(channel, status)
                status.status == "success" && break
            end
        end
    else
        try
            return _request(provider, "POST", "/api/pull", Dict("name" => model))
        catch e
            rethrow(e)
        end
    end
end

function push(provider::OllamaProvider, model::String; stream::Bool = false)
    if stream
        response = _request(provider, "POST", "/api/push", Dict("name" => model), stream=true)
        return Channel(32) do channel
            for line in eachline(response.body)
                isempty(line) && continue
                status = JSON3.read(line)
                put!(channel, status)
                status.status == "success" && break
            end
        end
    else
        try
            return _request(provider, "POST", "/api/push", Dict("name" => model))
        catch e
            rethrow(e)
        end
    end
end

function create(provider::OllamaProvider, model::String;
                system::Union{String, Nothing}=nothing,
                template::Union{String, Nothing}=nothing,
                stream::Bool=false)

    request = CreateRequest(
        name=model,
        system=system,
        template = template,
    )

    if stream
        response = _request(provider, "POST", "/api/create", request, stream = true)
        return Channel(32) do channel
            for line in eachline(response.body)
                isempty(line) && continue
            status = JSON3.read(line)
                put!(channel, status)
                status.status == "success" && break
            end
        end
    else
        try
            return _request(provider, "POST", "/api/create", request)
        catch e
            rethrow(e)
        end
    end
end

function list(provider::OllamaProvider)
   try
        return _request(provider, "GET", "/api/tags")
   catch e
        rethrow(e)
   end
end

function delete(provider::OllamaProvider, model::String)
    try
        return _request(provider, "DELETE", "/api/delete", Dict("name" => model))
    catch e
        rethrow(e)
    end
end

function copy(provider::OllamaProvider, source::String, destination::String)
   try
        return _request(provider, "POST", "/api/copy",
            Dict("source" => source, "destination" => destination))
   catch e
        rethrow(e)
   end
end

function show(provider::OllamaProvider, model::String)
    try
        return _request(provider, "POST", "/api/show", Dict("name" => model))
    catch e
        rethrow(e)
    end
end

function ps(provider::OllamaProvider)
    try
        return _request(provider, "GET", "/api/ps")
    catch e
        rethrow(e)
    end
end
