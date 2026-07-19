"""
PeerCompute type definitions.

PeerCompute is a pure P2P forwarding wrapper that delegates to a wrapped
provider (typically OllamaProvider). It does NOT define its own message or
tool-call types — it always returns the wrapped provider's concrete types
(e.g. OllamaMessage, OllamaToolCall).
"""

import StructTypes
using Dates
using FlootyAbstract: AbstractProviderObject, AbstractAttachment, AbstractLLMProvider, AbstractMessage, AbstractTool, AbstractModel, AbstractChatResponse

# ═══════════════════════════════════════════════════════════════════════
# PeerCompute Provider
# ═══════════════════════════════════════════════════════════════════════

"""
    PeerComputeProvider{T} <: AbstractLLMProvider

A P2P forwarding provider. `wrapped::T` holds the original provider
(typically `OllamaProvider`) to which message creation, tool building, and
response parsing are delegated. PeerCompute only owns the P2P transport:
discovering peers, serializing the wrapped provider's request to JSON,
forwarding via libp2p, and deserializing the response back into the wrapped
provider's native types.
"""
mutable struct PeerComputeProvider{T} <: AbstractLLMProvider
    node_running::Bool
    bootstrap_peers::Vector{String}
    service_topic::String
    p2p_port::Int
    api_port::Int
    bootstrap_node::Bool
    wrapped::T

    function PeerComputeProvider{T}(;bootstrap_peers::Vector{String}=String[],
                                     service_topic::String="peercompute-nodes-v1",
                                     p2p_port::Int=9002, api_port::Int=9003,
                                     bootstrap_node::Bool=false, wrapped=nothing) where {T}
        new(false, bootstrap_peers, service_topic, p2p_port, api_port, bootstrap_node, wrapped)
    end

    function PeerComputeProvider(;bootstrap_peers::Vector{String}=String[],
                                  service_topic::String="peercompute-nodes-v1",
                                  p2p_port::Int=9002, api_port::Int=9003,
                                  bootstrap_node::Bool=false, wrapped=nothing)
        T = typeof(wrapped)
        new{T}(false, bootstrap_peers, service_topic, p2p_port, api_port, bootstrap_node, wrapped)
    end
end

StructTypes.StructType(::Type{PeerComputeProvider}) = StructTypes.Mutable()

# ═══════════════════════════════════════════════════════════════════════
# Process-level singleton: only one P2P node per process (Go limitation)
# ═══════════════════════════════════════════════════════════════════════

const GLOBAL_PROVIDER = Ref{Union{PeerComputeProvider, Nothing}}(nothing)

# ═══════════════════════════════════════════════════════════════════════
# Tool Support
# ═══════════════════════════════════════════════════════════════════════

"""
Tool definition for PeerCompute (Ollama-compatible JSON schema format).
PeerCompute forwards tools as-is to the remote peer; the wrapped provider
(typically Ollama) is responsible for building the typed tool structure.
"""
struct PeerComputeTool <: AbstractTool
    type::String
    function_::Dict{String,Any}
end

FlootyAbstract.tool_name(tool::PeerComputeTool) = get(tool.function_, "name", "unknown")
FlootyAbstract.tool_description(tool::PeerComputeTool) = get(tool.function_, "description", "")
FlootyAbstract.tool_parameters(tool::PeerComputeTool) = get(tool.function_, "parameters", Dict())

# ═══════════════════════════════════════════════════════════════════════
# Chat Response
# ═══════════════════════════════════════════════════════════════════════

"""
Response from a PeerCompute inference call. `message` holds the wrapped
provider's native message type (e.g. OllamaMessage) — PeerCompute does NOT
define its own message type.
"""
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
    print(io, "PeerComputeModel(\"$(model.name)\"")
    if model.peer_id !== nothing
        print(io, ", peer=$(model.peer_id[1:min(12, length(model.peer_id))])…")
    end
    print(io, ")")
end