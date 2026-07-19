"""
    peercompute/types.jl

Provider types for PeerCompute P2P integration.
"""

import StructTypes
import PeerCompute
using Dates

using FlootyAbstract: AbstractProviderObject, AbstractAttachment, AbstractLLMProvider, AbstractMessage, AbstractTool, AbstractModel, AbstractChatResponse

# ═══════════════════════════════════════════════════════════════════════
# PeerCompute Provider
# ═══════════════════════════════════════════════════════════════════════

mutable struct PeerComputeProvider{T} <: AbstractLLMProvider
    node_running::Bool
    bootstrap_peers::Vector{String}
    service_topic::String
    p2p_port::Int
    api_port::Int
    bootstrap_node::Bool  # If true, start as bootstrap node
    wrapped::T  # The original provider (e.g., OllamaProvider) to delegate to

    function PeerComputeProvider{T}(;
        bootstrap_peers::Vector{String}=String[],
        service_topic::String="peercompute-nodes-v1",
        p2p_port::Int=4001,
        api_port::Int=5001,
        bootstrap_node::Bool=false,
        wrapped::T
    ) where T
        new{T}(false, bootstrap_peers, service_topic, p2p_port, api_port, bootstrap_node, wrapped)
    end
end

StructTypes.StructType(::Type{PeerComputeProvider}) = StructTypes.Mutable()

# ═══════════════════════════════════════════════════════════════════════
# Process-level singleton: only one P2P node per process (Go limitation)
const GLOBAL_PROVIDER = Ref{Union{PeerComputeProvider{Any}, Nothing}}(nothing)

# ═══════════════════════════════════════════════════════════════════════
# Tool Support (must be before Message since PeerComputeMessage references it)
# ═══════════════════════════════════════════════════════════════════════

"""Tool definition for PeerCompute (Ollama-compatible format)"""
struct PeerComputeTool <: AbstractTool
    type::String
    function_::Dict{String,Any}  # Ollama uses nested function structure
end

FlootyAbstract.tool_name(tool::PeerComputeTool) = get(tool.function_, "name", "unknown")
FlootyAbstract.tool_description(tool::PeerComputeTool) = get(get(tool.function_, "parameters", Dict()), "description", "")
FlootyAbstract.tool_parameters(tool::PeerComputeTool) = get(get(tool.function_, "parameters", Dict()), "properties", Dict())

"""Tool call from model response"""
struct PeerComputeToolCall <: AbstractToolCall
    function_::Dict{String,Any}
end

FlootyAbstract.call_name(call::PeerComputeToolCall) = get(get(call, :function_, Dict()), "name", "unknown")
FlootyAbstract.call_arguments(call::PeerComputeToolCall) = get(get(call, :function_, Dict()), "arguments", Dict())
FlootyAbstract.call_id(::PeerComputeToolCall) = nothing

# ═══════════════════════════════════════════════════════════════════════
# Messages
# ═══════════════════════════════════════════════════════════════════════

@kwdef struct PeerComputeMessage <: AbstractMessage
    role::String = "user"
    content::Union{String, Nothing} = nothing
    thinking::Union{String, Nothing} = nothing
    tool_calls::Union{Vector{PeerComputeToolCall}, Nothing} = nothing
    _type::String = "PeerComputeMessage"
end

StructTypes.StructType(::Type{PeerComputeMessage}) = StructTypes.Struct()
StructTypes.omitempties(::Type{PeerComputeMessage}) = (:content, :thinking, :tool_calls)
StructTypes.defaults(::Type{PeerComputeMessage}) = (role = "user", _type = "PeerComputeMessage")
# ═══════════════════════════════════════════════════════════════════════
# Chat Response
# ═══════════════════════════════════════════════════════════════════════

struct PeerComputeResponse <: AbstractChatResponse
    message::AbstractMessage
    model::Union{String, Nothing}
    peer_id::Union{String, Nothing}
    latency_ms::Int
    success::Bool
end

StructTypes.StructType(::Type{PeerComputeResponse}) = StructTypes.Struct()
StructTypes.omitempties(::Type{PeerComputeResponse}) = (:model, :peer_id)

FlootyAbstract.response_message(response::PeerComputeResponse) = response.message

# ═══════════════════════════════════════════════════════════════════════
# P2P Inference Response (from Go layer) — imported from PeerCompute
# PeerCompute.P2PInferenceResponse is used for parsing Go responses
# ═══════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════
# Model Information
# ═══════════════════════════════════════════════════════════════════════

@kwdef struct PeerComputeModel <: AbstractModel
    name::String
    peer_id::Union{String, Nothing} = nothing
    reputation::Float64 = 1.0
    latency_ms::Int = 0
end

StructTypes.StructType(::Type{PeerComputeModel}) = StructTypes.Struct()
StructTypes.omitempties(::Type{PeerComputeModel}) = (:peer_id,)

FlootyAbstract.model_name(model::PeerComputeModel) = model.name
FlootyAbstract.model_provider(model::PeerComputeModel) = :peercompute

function Base.show(io::IO, model::PeerComputeModel)
    print(io, "PeerComputeModel(", model.name, ")")
    !isnothing(model.peer_id) && print(io, " peer=", model.peer_id[1:min(12, length(model.peer_id))], "...")
end

# ═══════════════════════════════════════════════════════════════════════
# Model Information
# ═══════════════════════════════════════════════════════════════════════
