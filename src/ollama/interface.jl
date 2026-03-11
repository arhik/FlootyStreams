role(msg::OllamaMessage) = role.msg
content(msg::OllamaMessage) = role.content

create_message(provider::OllamaProvider, role::String, content::String; ) =
    OllamaMessage(role=role, content=content)

create_provider_instance(::Val{:ollama}; config::Dict{Symbol, Any} = Dict{Symbol, Any}()) = OllamaProvider()

function create_stream(provider::OllamaProvider, model::String, messages::Vector{OllamaMessage},
    stream::Bool=false,
    format::Union{Nothing, OrderedDict}=nothing,
    options::Union{Nothing, Dict{String,Any}}=nothing,
    tools::Vector{OrderedDict}=OrderedDict[])
    chat(provider, messages, model, stream, format, options, tools)
end
