import StructTypes
using JSON3
using OrderedCollections
using Base64

using FlootyAbstract: AbstractProviderObject, AbstractAttachment, AbstractLLMProvider, AbstractMessage, AbstractTool, AbstractModel, model_name, model_provider, AbstractChatResponse, response_message

# absract/provider.jl - OllamaProvider implementation

mutable struct OllamaProvider <: AbstractLLMProvider
    baseURL::String
    timeout::Int64

    function OllamaProvider(; baseURL::String="http://localhost:11434", timeout::Int64=120)
        new(rstrip(baseURL, '/'), timeout)
    end
end

StructTypes.StructType(::Type{OllamaProvider}) = StructTypes.Mutable()

# Core type definitions for OllamaJL

# Base types for the type system
abstract type OllamaObject <: AbstractProviderObject end
abstract type OllamaRequest <: OllamaObject end
abstract type OllamaResponse <: AbstractChatResponse end

struct OllamaError <: AbstractFlootyError
    message::String
    status::Int
end

StructTypes.StructType(::Type{OllamaError}) = StructTypes.Struct()

Base.show(io::IO, e::OllamaError) = print(io, "OllamaError($(e.status)): $(e.message)")

struct OllamaFunction <: AbstractProviderObject
    name::String
    description::String
    parameters::Vector{ToolParameter}
end

StructTypes.StructType(::Type{OllamaFunction}) = StructTypes.CustomStruct()

struct OllamaTool <: AbstractTool
    type::String
    function_::OllamaFunction
end

StructTypes.StructType(::Type{OllamaTool}) = StructTypes.Struct()
StructTypes.names(::Type{OllamaTool}) = ((:function_, :function),)

FlootyAbstract.tool_name(tool::OllamaTool) = tool.function_.name
FlootyAbstract.tool_description(tool::OllamaTool) = tool.function_.description
FlootyAbstract.tool_parameters(tool::OllamaTool) = tool.function_.parameters

struct OllamaToolCallFunction <: AbstractProviderObject
    name::String
    arguments::Dict{String,Any}
end

StructTypes.StructType(::Type{OllamaToolCallFunction}) = StructTypes.Struct()

struct OllamaToolCall <: AbstractToolCall
    function_::OllamaToolCallFunction
    id::Union{String,Nothing}
end

StructTypes.StructType(::Type{OllamaToolCall}) = StructTypes.Struct()
StructTypes.names(::Type{OllamaToolCall}) = ((:function_, :function),)
    
    # Constructor from Dict (e.g., from JSON.parse)
    function OllamaToolCall(data::Dict)
        func_data = get(data, "function", data)
        name = get(func_data, "name", "unknown")
        args = get(func_data, "arguments", Dict{String,Any}())
        # Ollama returns arguments as a JSON string, parse it
        if args isa String
            args = try
                JSON.parse(args)
            catch
                Dict{String,Any}("raw" => args)
            end
        end
        id = get(data, "id", nothing)
        if id === nothing
            id = get(func_data, "id", nothing)
        end
        new(OllamaToolCallFunction(name, args), id)
    end

FlootyAbstract.call_name(call::OllamaToolCall) = call.function_.name
FlootyAbstract.call_arguments(call::OllamaToolCall) = call.function_.arguments
FlootyAbstract.call_id(call::OllamaToolCall) = call.id


struct ImageData <: AbstractProviderObject
    path::String        # Original file path (empty if deserialized from JSON)
    data::String        # Base64 encoded image data
end

# Constructor from file path - reads and encodes to base64
ImageData(path::String) = ImageData(path, Base64.base64encode(read(path)))

# Serialization: ImageData serializes as base64 string (just the data)
StructTypes.StructType(::Type{ImageData}) = StructTypes.StringType()
StructTypes.lower(img::ImageData) = img.data

# Deserialization: JSON string -> ImageData (empty path, just base64 data)
StructTypes.construct(::Type{ImageData}, s::String) = ImageData("", s)

Base.string(img::ImageData) = img.data

# ImageAttachment - stores file path and loads ImageData on demand
struct ImageAttachment <: AbstractAttachment
    path::String
    mime::String
    _data::Ref{Union{ImageData, Nothing}}  # Lazy-loaded base64 data

    function ImageAttachment(path::String, mime::String="image/png")
        isfile(path) || throw(ArgumentError("File not found: $path"))
        new(path, mime, Ref{Union{ImageData, Nothing}}(nothing))
    end
end

# Attachment interface implementation
FlootyAbstract.attachment_path(att::ImageAttachment) = att.path
FlootyAbstract.attachment_type(att::ImageAttachment) = :image
FlootyAbstract.attachment_mime(att::ImageAttachment) = att.mime

# Lazy load the ImageData
function get_image_data(att::ImageAttachment)
    if att._data[] === nothing
        att._data[] = ImageData(att.path)
    end
    att._data[]
end

@kwdef struct OllamaMessage <: AbstractMessage
    role::String = "user"
    content::Union{String, Nothing} = nothing
    thinking::Union{String, Nothing} = nothing
    images::Union{Vector{ImageData}, Nothing} = nothing
    tool_calls::Union{Vector{OllamaToolCall}, Nothing} = nothing
    tool_name::Union{String, Nothing} = nothing
    tool_call_id::Union{String, Nothing} = nothing
    _type::String = "OllamaMessage"
end

StructTypes.StructType(::Type{OllamaMessage}) = StructTypes.Struct()
StructTypes.omitempties(::Type{OllamaMessage}) = (:content, :thinking, :images, :tool_calls, :tool_name, :tool_call_id)
StructTypes.defaults(::Type{OllamaMessage}) = (role = "user", _type = "OllamaMessage")

# Request Types
@kwdef struct GenerateRequest <: OllamaRequest
    model::String = ""
    prompt::Union{String, Nothing} = nothing
    system::Union{String, Nothing} = nothing
    template::Union{String, Nothing} = nothing
    context::Union{Vector{Int}, Nothing} = nothing
    stream::Bool = false
    raw::Union{Bool, Nothing} = false
    format::Union{OrderedDict, Nothing} = nothing
    options::Union{Dict{String,Any}, Nothing} = nothing
    images::Union{Vector{ImageData}, Nothing} = nothing
end

StructTypes.StructType(::Type{GenerateRequest}) = StructTypes.Struct()
StructTypes.omitempties(::Type{GenerateRequest}) = (:prompt, :system, :template, :context, :raw, :format, :options, :images)

@kwdef struct ChatRequest <: OllamaRequest
    model::String = "llama3.2"
    messages::Vector{OllamaMessage} = []
    stream::Bool = false
    format::Union{String, OrderedDict, Nothing} = nothing
    options::Union{Dict{String,Any}, Nothing} = nothing
    tools::Union{Vector{OllamaTool}, Nothing} = nothing
end

StructTypes.StructType(::Type{ChatRequest}) = StructTypes.Struct()
StructTypes.omitempties(::Type{ChatRequest}) = (:format, :options, :tools)

@kwdef struct GenerateResponse <: OllamaResponse
    response::Union{String, Nothing} = nothing
    model::Union{String, Nothing} = nothing
    created_at::Union{String, Nothing} = nothing
    done::Bool = false
    done_reason::Union{String, Nothing} = nothing
    context::Union{Vector{Int}, Nothing} = nothing
    total_duration::Union{Int, Nothing} = nothing
    load_duration::Union{Int, Nothing} = nothing
    prompt_eval_count::Union{Int, Nothing} = nothing
    prompt_eval_duration::Union{Int, Nothing} = nothing
    eval_count::Union{Int, Nothing} = nothing
    eval_duration::Union{Int, Nothing} = nothing
end

StructTypes.StructType(::Type{GenerateResponse}) = StructTypes.Struct()
StructTypes.omitempties(::Type{GenerateResponse}) = (:model, :created_at, :total_duration, :load_duration, :prompt_eval_count, :prompt_eval_duration, :eval_count, :eval_duration)

struct ChatResponse <: OllamaResponse
    message::OllamaMessage
    model::Union{String, Nothing}
    created_at::Union{String, Nothing}
    done::Bool
    total_duration::Union{Int, Nothing}
    load_duration::Union{Int, Nothing}
    prompt_eval_count::Union{Int, Nothing}
    eval_count::Union{Int, Nothing}
    eval_duration::Union{Int, Nothing}
end

StructTypes.StructType(::Type{ChatResponse}) = StructTypes.Struct()
StructTypes.omitempties(::Type{ChatResponse}) = (:model, :created_at, :total_duration, :load_duration, :prompt_eval_count, :eval_count, :eval_duration)

FlootyAbstract.response_message(response::ChatResponse) = response.message

@kwdef struct EmbedRequest <: OllamaRequest
    model::String = ""
    input::Union{Vector{String}, String} = ""
    options::Union{Dict{String,Any}, Nothing} = nothing
end

StructTypes.StructType(::Type{EmbedRequest}) = StructTypes.Struct()
StructTypes.omitempties(::Type{EmbedRequest}) = (:options,)

struct EmbedResponse <: OllamaResponse
    embeddings::Vector{Vector{Float64}}
    model::Union{String, Nothing}
end

StructTypes.StructType(::Type{EmbedResponse}) = StructTypes.Struct()
StructTypes.omitempties(::Type{EmbedResponse}) = (:model,)

@kwdef struct ModelDetails
    parent_model::String = ""
    format::String = ""
    family::String = ""
    families::Union{Vector{String}, Nothing} = nothing
    parameter_size::String = ""
    quantization_level::String = ""
end

StructTypes.StructType(::Type{ModelDetails}) = StructTypes.Struct()
StructTypes.omitempties(::Type{ModelDetails}) = (:families,)

@kwdef struct OllamaModel <: AbstractModel
    name::String
    model::String
    modified_at::String
    size::Int64
    digest::String
    details::ModelDetails
    remote_model::Union{String, Nothing} = nothing
    remote_host::Union{String, Nothing} = nothing
    capabilities::Union{Vector{Symbol}, Nothing} = nothing
end

StructTypes.StructType(::Type{OllamaModel}) = StructTypes.Struct()
StructTypes.omitempties(::Type{OllamaModel}) = (:capabilities, :remote_model, :remote_host)

FlootyAbstract.model_name(model::OllamaModel) = model.name
FlootyAbstract.model_provider(model::OllamaModel) = :ollama

function Base.show(io::IO, model::OllamaModel)
    print(io, "OllamaModel(", model.name, ")")
    isempty(model.details.family) || print(io, " family=", model.details.family)
    isempty(model.details.parameter_size) || print(io, " params=", model.details.parameter_size)
    print(io, " size=", model.size, " bytes")
    !isnothing(model.remote_model) && print(io, " [remote]")
end

# Embedder implementation for ContextManager
using FlootyAbstract: AbstractEmbedder

struct OllamaEmbedder <: AbstractEmbedder
    provider::OllamaProvider
    model::String
end

function FlootyAbstract.embed(embedder::OllamaEmbedder, text::String)
    response = embed(embedder.provider, text, embedder.model)
    return response.embeddings[1]
end

function FlootyAbstract.embed(embedder::OllamaEmbedder, texts::Vector{String})
    response = embed(embedder.provider, texts, embedder.model)
    return response.embeddings
end

# ═══════════════════════════════════════════════════════════════════════
# Web Search Types
# ═══════════════════════════════════════════════════════════════════════

struct WebSearchResult <: AbstractProviderObject
    title::String
    url::String
    content::String
end

StructTypes.StructType(::Type{WebSearchResult}) = StructTypes.Struct()

struct WebSearchResponse <: OllamaResponse
    results::Vector{WebSearchResult}
end

StructTypes.StructType(::Type{WebSearchResponse}) = StructTypes.Struct()

struct WebFetchResponse <: OllamaResponse
    title::String
    content::String
    links::Vector{String}
end

StructTypes.StructType(::Type{WebFetchResponse}) = StructTypes.Struct()


# LlamaCpp provider: FlootyHub is Ollama-compatible, so reuse OllamaProvider.
const LlamaCppProvider = OllamaProvider

# LlamaCpp (FlootyHub) base URL registry. FlootyHub sets this when it serves;
# Flooty reads it via create_provider_instance(:llamacpp) without importing
# FlootyHub (avoids circular dependency).
const LLAMACPP_BASE_URL = Ref{String}("http://localhost:11434")
function set_llamacpp_base_url!(url::AbstractString)
    s = String(url)
    endswith(s, "/") && (s = chop(s))
    endswith(s, "/v1") && (s = s[1:end-3])
    LLAMACPP_BASE_URL[] = s
    return s
end
