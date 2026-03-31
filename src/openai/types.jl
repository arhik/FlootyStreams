import StructTypes
using JSON3
using OrderedCollections
using Base64

using FlootyAbstract: AbstractProviderObject, AbstractAttachment, AbstractLLMProvider, AbstractMessage, AbstractTool, AbstractToolCall, AbstractModel, model_name, model_provider

# OpenAI Provider implementation
# OpenAI is the canonical OpenAI-compatible provider

mutable struct OpenAIProvider <: OpenAICompatibleProvider
    baseURL::String
    apiKey::String
    timeout::Int64

    function OpenAIProvider(; baseURL::String="https://api.openai.com/v1", apiKey::String="", timeout::Int64=120)
        new(rstrip(baseURL, '/'), apiKey, timeout)
    end
end

StructTypes.StructType(::Type{OpenAIProvider}) = StructTypes.Mutable()

# Base types for the type system
abstract type OpenAIObject <: AbstractProviderObject end
abstract type OpenAIRequest <: OpenAIObject end
abstract type OpenAIResponse <: OpenAIObject end

struct OpenAIError <: AbstractFlootyError
    message::String
    status::Int
    type::String
end

StructTypes.StructType(::Type{OpenAIError}) = StructTypes.Struct()

Base.show(io::IO, e::OpenAIError) = print(io, "OpenAIError($(e.status)): $(e.type) - $(e.message)")

struct OpenAIFunction <: AbstractProviderObject
    name::String
    description::String
    parameters::OrderedDict{String,Any}
end

StructTypes.StructType(::Type{OpenAIFunction}) = StructTypes.Struct()

struct OpenAITool <: AbstractTool
    type::String
    function_::OpenAIFunction
end

StructTypes.StructType(::Type{OpenAITool}) = StructTypes.Struct()
StructTypes.names(::Type{OpenAITool}) = ((:function_, :function),)

FlootyAbstract.tool_name(tool::OpenAITool) = tool.function_.name
FlootyAbstract.tool_description(tool::OpenAITool) = tool.function_.description
FlootyAbstract.tool_parameters(tool::OpenAITool) = tool.function_.parameters

struct OpenAIToolCall <: AbstractToolCall
    id::String
    type::String
    function_::OpenAIFunction
end

StructTypes.StructType(::Type{OpenAIToolCall}) = StructTypes.Struct()
StructTypes.names(::Type{OpenAIToolCall}) = ((:function_, :function),)

FlootyAbstract.call_name(call::OpenAIToolCall) = call.function_.name
FlootyAbstract.call_arguments(call::OpenAIToolCall) = call.function_.parameters
FlootyAbstract.call_id(call::OpenAIToolCall) = call.id

# Image content for vision models
struct OpenAIImageUrl <: AbstractProviderObject
    url::String
    detail::String

    function OpenAIImageUrl(url::String; detail::String="auto")
        new(url, detail)
    end
end

StructTypes.StructType(::Type{OpenAIImageUrl}) = StructTypes.Struct()

struct OpenAIImageContent <: AbstractProviderObject
    type::String
    image_url::OpenAIImageUrl

    function OpenAIImageContent(url::String; detail::String="auto")
        new("image_url", OpenAIImageUrl(url; detail=detail))
    end
end

StructTypes.StructType(::Type{OpenAIImageContent}) = StructTypes.Struct()

# Text content for multimodal messages
struct OpenAITextContent <: AbstractProviderObject
    type::String
    text::String

    function OpenAITextContent(text::String)
        new("text", text)
    end
end

StructTypes.StructType(::Type{OpenAITextContent}) = StructTypes.Struct()

# Message content can be String or Vector of content items
const OpenAIMessageContent = Union{String, Vector{<:AbstractProviderObject}}

@kwdef struct OpenAIMessage <: AbstractMessage
    role::String = "user"
    content::Union{String, Vector{<:AbstractProviderObject}, Nothing} = nothing
    tool_calls::Union{Vector{OpenAIToolCall}, Nothing} = nothing
    tool_call_id::Union{String, Nothing} = nothing
    name::Union{String, Nothing} = nothing
    _type::String = "OpenAIMessage"
end

StructTypes.StructType(::Type{OpenAIMessage}) = StructTypes.Struct()
StructTypes.omitempties(::Type{OpenAIMessage}) = (:content, :tool_calls, :tool_call_id, :name)

# Custom serialization for OpenAI API format
function StructTypes.lower(msg::OpenAIMessage)
    d = Dict{String,Any}(
        "role" => msg.role,
        "_type" => "OpenAIMessage"  # Include type discriminator
    )
    if msg.content !== nothing
        d["content"] = msg.content
    end
    if msg.tool_calls !== nothing && !isempty(msg.tool_calls)
        d["tool_calls"] = msg.tool_calls
    end
    if msg.tool_call_id !== nothing
        d["tool_call_id"] = msg.tool_call_id
    end
    if msg.name !== nothing
        d["name"] = msg.name
    end
    return d
end

# Request Types
@kwdef struct ChatCompletionRequest <: OpenAIRequest
    model::String = "gpt-4"
    messages::Vector{OpenAIMessage} = []
    temperature::Union{Float64, Nothing} = nothing
    top_p::Union{Float64, Nothing} = nothing
    n::Union{Int, Nothing} = nothing
    stream::Bool = false
    stop::Union{String, Vector{String}, Nothing} = nothing
    max_tokens::Union{Int, Nothing} = nothing
    presence_penalty::Union{Float64, Nothing} = nothing
    frequency_penalty::Union{Float64, Nothing} = nothing
    tools::Union{Vector{OpenAITool}, Nothing} = nothing
    tool_choice::Union{String, Nothing} = nothing
    response_format::Union{Dict{String,Any}, Nothing} = nothing
end

StructTypes.StructType(::Type{ChatCompletionRequest}) = StructTypes.Struct()
StructTypes.omitempties(::Type{ChatCompletionRequest}) = (
    :temperature, :top_p, :n, :stop, :max_tokens,
    :presence_penalty, :frequency_penalty, :tools, :tool_choice, :response_format
)

# Delta content for streaming
struct DeltaContent <: OpenAIObject
    role::Union{String, Nothing}
    content::Union{String, Nothing}
    tool_calls::Union{Vector{OpenAIToolCall}, Nothing}
end

StructTypes.StructType(::Type{DeltaContent}) = StructTypes.Struct()
StructTypes.omitempties(::Type{DeltaContent}) = (:role, :content, :tool_calls)

@kwdef struct ChatCompletionChoice <: OpenAIResponse
    index::Int = 0
    message::Union{OpenAIMessage, Nothing} = nothing
    delta::Union{DeltaContent, Nothing} = nothing
    finish_reason::Union{String, Nothing} = nothing
    logprobs::Union{Nothing, Any} = nothing
end

StructTypes.StructType(::Type{ChatCompletionChoice}) = StructTypes.Struct()
StructTypes.omitempties(::Type{ChatCompletionChoice}) = (:message, :delta, :finish_reason, :logprobs)

# Token details
struct TokenDetails <: OpenAIObject
    cached_tokens::Int
end

StructTypes.StructType(::Type{TokenDetails}) = StructTypes.Struct()

# Completion token details
struct CompletionTokenDetails <: OpenAIObject
    reasoning_tokens::Int
end

StructTypes.StructType(::Type{CompletionTokenDetails}) = StructTypes.Struct()

# Usage statistics
struct CompletionUsage <: OpenAIObject
    prompt_tokens::Int
    completion_tokens::Int
    total_tokens::Int
    prompt_tokens_details::Union{TokenDetails, Nothing}
    completion_tokens_details::Union{CompletionTokenDetails, Nothing}
end

StructTypes.StructType(::Type{CompletionUsage}) = StructTypes.Struct()
StructTypes.omitempties(::Type{CompletionUsage}) = (:prompt_tokens_details, :completion_tokens_details)

@kwdef struct ChatCompletionResponse <: OpenAIResponse
    id::String
    object::String
    created::Int
    model::String
    choices::Vector{ChatCompletionChoice}
    usage::Union{CompletionUsage, Nothing} = nothing
    service_tier::Union{String, Nothing} = nothing
    system_fingerprint::Union{String, Nothing} = nothing
end

StructTypes.StructType(::Type{ChatCompletionResponse}) = StructTypes.Struct()
StructTypes.omitempties(::Type{ChatCompletionResponse}) = (:usage, :service_tier, :system_fingerprint)

@kwdef struct ChatCompletionChunk <: OpenAIResponse
    id::String
    object::String
    created::Int
    model::String
    choices::Vector{ChatCompletionChoice}
end

StructTypes.StructType(::Type{ChatCompletionChunk}) = StructTypes.Struct()

# Embedding request/response
@kwdef struct EmbeddingRequest <: OpenAIRequest
    model::String = "text-embedding-3-small"
    input::Union{String, Vector{String}} = ""
    encoding_format::Union{String, Nothing} = nothing
    dimensions::Union{Int, Nothing} = nothing
end

StructTypes.StructType(::Type{EmbeddingRequest}) = StructTypes.Struct()
StructTypes.omitempties(::Type{EmbeddingRequest}) = (:encoding_format, :dimensions)

struct EmbeddingData <: OpenAIResponse
    object::String
    embedding::Vector{Float64}
    index::Int
end

StructTypes.StructType(::Type{EmbeddingData}) = StructTypes.Struct()

@kwdef struct EmbeddingResponse <: OpenAIResponse
    object::String
    data::Vector{EmbeddingData}
    model::String
    usage::Union{Dict{String,Int}, Nothing} = nothing
end

StructTypes.StructType(::Type{EmbeddingResponse}) = StructTypes.Struct()
StructTypes.omitempties(::Type{EmbeddingResponse}) = (:usage,)

# Models
struct OpenAIModel <: AbstractModel
    id::String
    object::String
    created::Int
    owned_by::String
end

StructTypes.StructType(::Type{OpenAIModel}) = StructTypes.Struct()

FlootyAbstract.model_name(model::OpenAIModel) = model.id
FlootyAbstract.model_provider(model::OpenAIModel) = :openai

function Base.show(io::IO, model::OpenAIModel)
    print(io, "OpenAIModel(", model.id, ")")
    print(io, " owned_by=", model.owned_by)
end

# Embedder implementation for ContextManager
using FlootyAbstract: AbstractEmbedder

struct OpenAIEmbedder <: AbstractEmbedder
    provider::OpenAIProvider
    model::String
end

function FlootyAbstract.embed(embedder::OpenAIEmbedder, text::String)
    response = embed(embedder.provider, text, embedder.model)
    return response.data[1].embedding
end

function FlootyAbstract.embed(embedder::OpenAIEmbedder, texts::Vector{String})
    response = embed(embedder.provider, texts, embedder.model)
    return [d.embedding for d in response.data]
end
