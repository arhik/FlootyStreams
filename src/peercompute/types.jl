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
end

StructTypes.StructType(::Type{PeerComputeResponse}) = StructTypes.Struct()
StructTypes.omitempties(::Type{PeerComputeResponse}) = (:model, :peer_id)

FlootyAbstract.response_message(response::PeerComputeResponse) = response.message

# ═══════════════════════════════════════════════════════════════════════
# P2P Inference Response (symmetric wrap/unwrap for P2P transport)
# ═══════════════════════════════════════════════════════════════════════

"""
    PeerComputeInferenceResponse

Structured wrapper used by the PeerCompute P2P inference endpoint
(`_handle_inference_request`) to serialize the wrapped provider's chat
response. The receiving `create_stream` unwraps it back into the native
message type (e.g. `OllamaMessage`).

This replaces the fragile pattern of passing raw Ollama `ChatResponse` JSON
through the P2P layer and hoping `JSON3.read` can deserialize it.
"""
struct PeerComputeInferenceResponse
    status::String
    message::OllamaMessage
    model::Union{String, Nothing}
end

StructTypes.StructType(::Type{PeerComputeInferenceResponse}) = StructTypes.Struct()
StructTypes.omitempties(::Type{PeerComputeInferenceResponse}) = (:model,)

# ═══════════════════════════════════════════════════════════════════════
# Model Information
# ═══════════════════════════════════════════════════════════════════════

@kwdef struct PeerComputeModel <: AbstractModel
    name::String
    peer_id::Union{String, Nothing} = nothing
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