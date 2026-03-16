FlootyAbstract.role(msg::OllamaMessage) = msg.role
FlootyAbstract.content(msg::OllamaMessage) = msg.content

FlootyAbstract.create_message(provider::OllamaProvider, role::String, content::String; kwargs...) =
    OllamaMessage(role=role, content=content)

FlootyAbstract.create_message(provider::OllamaProvider, role::String, content::String, images::Vector{<:AbstractProviderObject}; kwargs...) =
    OllamaMessage(role=role, content=content, images=convert(Vector{ImageData}, images))

# New interface: create message with attachments (ImageAttachment, etc.)
FlootyAbstract.create_message(provider::OllamaProvider, role::String, content::String, attachments::Vector{<:AbstractAttachment}; kwargs...) =
    OllamaMessage(role=role, content=content, images=[get_image_data(att) for att in attachments])

FlootyAbstract.create_image_data(provider::OllamaProvider, data::Union{String, Vector{UInt8}}) =
    ImageData(data)

FlootyAbstract.images(msg::OllamaMessage) = msg.images

# Create ImageAttachment objects from file paths
FlootyAbstract.create_attachments(provider::OllamaProvider, paths::Vector{String}, mime_types::Vector{String}) =
    [ImageAttachment(path, mime) for (path, mime) in zip(paths, mime_types)]

FlootyAbstract.create_provider_instance(::Val{:ollama}; config::Dict{Symbol, Any} = Dict{Symbol, Any}()) = OllamaProvider()

FlootyAbstract.provider_name(provider::OllamaProvider) = :ollama

function FlootyAbstract.list_provider_models(::Val{:ollama}, config::Dict{Symbol,Any})
    baseURL = get(config, :baseURL, "http://localhost:11434")
    timeout = get(config, :timeout, 120)
    provider = OllamaProvider(; baseURL=baseURL, timeout=timeout)
    response = list(provider)
    return response.models
end

FlootyAbstract.create_embedder(provider::OllamaProvider, model::String; kwargs...) =
    OllamaEmbedder(provider, model)

function FlootyAbstract.create_stream(provider::OllamaProvider, model::String, messages::Vector{<:AbstractMessage},
    stream::Bool=false,
    format::Union{Nothing, OrderedDict}=nothing,
    options::Union{Nothing, Dict{String,Any}}=nothing,
    tools::Union{Vector{<:AbstractTool}, Nothing}=nothing)
    # Convert AbstractMessage to OllamaMessage
    ollama_messages = [m isa OllamaMessage ? m : OllamaMessage(role=role(m), content=content(m)) for m in messages]
    # Tools should already be OllamaTool from FlootyAgents
    ollama_tools = tools === nothing ? nothing : convert(Vector{OllamaTool}, tools)
    chat(provider, ollama_messages, model, stream, format, options, ollama_tools)
end

function FlootyAbstract.chat_stream(provider::OllamaProvider, model::String, messages::Vector{<:AbstractMessage},
    stream::Bool=false,
    format::Union{Nothing, OrderedDict}=nothing,
    options::Union{Nothing, Dict{String,Any}}=nothing,
    tools::Union{Vector{<:AbstractTool}, Nothing}=nothing)
    # Convert AbstractMessage to OllamaMessage
    ollama_messages = [m isa OllamaMessage ? m : OllamaMessage(role=role(m), content=content(m)) for m in messages]
    # Tools should already be OllamaTool from FlootyAgents
    ollama_tools = tools === nothing ? nothing : convert(Vector{OllamaTool}, tools)
    chat(provider, ollama_messages, model, stream, format, options, ollama_tools)
end
