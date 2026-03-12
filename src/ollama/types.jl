import StructTypes
using JSON3
using OrderedCollections

using FlootyAbstract: AbstractProviderObject, AbstractLLMProvider, AbstractMessage, AbstractTool

# absract/provider.jl - OllamaProvider implementation

struct OllamaProvider <: AbstractLLMProvider
    baseURL::String
    timeout::Int64

    function OllamaProvider(; baseURL::String="http://localhost:11434", timeout::Int64=120)
        new(rstrip(baseURL, '/'), timeout)
    end
end

# Core type definitions for OllamaJL

# Base types for the type system
abstract type OllamaObject <: AbstractProviderObject end
abstract type OllamaRequest <: OllamaObject end
abstract type OllamaResponse <: OllamaObject end

struct OllamaError <: Exception
    message::String
    status::Int
end

StructTypes.StructType(::Type{OllamaError}) = StructTypes.Struct()

Base.show(io::IO, e::OllamaError) = print(io, "OllamaError($(e.status)): $(e.message)")

struct OllamaFunction
    name::String
    description::String
    parameters::OrderedDict{String,Any}
end

StructTypes.StructType(::Type{OllamaFunction}) = StructTypes.Struct()

struct OllamaTool <: AbstractTool
    type::String
    function_::OllamaFunction
end

StructTypes.StructType(::Type{OllamaTool}) = StructTypes.Struct()
StructTypes.names(::Type{OllamaTool}) = ((:function_, :function),)

FlootyAbstract.tool_name(tool::OllamaTool) = tool.function_.name
FlootyAbstract.tool_description(tool::OllamaTool) = tool.function_.description
FlootyAbstract.tool_parameters(tool::OllamaTool) = tool.function_.parameters

struct OllamaToolCallFunction
    name::String
    arguments::Dict{String,Any}
end

StructTypes.StructType(::Type{OllamaToolCallFunction}) = StructTypes.Struct()

struct OllamaToolCall <: AbstractToolCall
    function_::OllamaToolCallFunction
end

StructTypes.StructType(::Type{OllamaToolCall}) = StructTypes.Struct()
StructTypes.names(::Type{OllamaToolCall}) = ((:function_, :function),)

FlootyAbstract.call_name(call::OllamaToolCall) = call.function_.name
FlootyAbstract.call_arguments(call::OllamaToolCall) = call.function_.arguments
FlootyAbstract.call_id(::OllamaToolCall) = nothing


struct ImageData end

@kwdef struct OllamaMessage <: AbstractMessage
    role::String = "user"
    content::Union{String, Nothing} = nothing
    thinking::Union{String, Nothing} = nothing
    images::Union{Vector{ImageData}, Nothing} = nothing
    tool_calls::Union{Vector{OllamaToolCall}, Nothing} = nothing
    tool_name::Union{String, Nothing} = nothing
end

StructTypes.StructType(::Type{OllamaMessage}) = StructTypes.Struct()
StructTypes.omitempties(::Type{OllamaMessage}) = (:content, :thinking, :images, :tool_calls, :tool_name)

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
    format::Union{OrderedDict, Nothing} = nothing
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
