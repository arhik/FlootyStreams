FlootyAbstract.role(msg::OllamaMessage) = msg.role
FlootyAbstract.content(msg::OllamaMessage) = msg.content

FlootyAbstract.create_message(provider::OllamaProvider, role::String, content::String; ) =
    OllamaMessage(role=role, content=content)

FlootyAbstract.create_provider_instance(::Val{:ollama}; config::Dict{Symbol, Any} = Dict{Symbol, Any}()) = OllamaProvider()

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
