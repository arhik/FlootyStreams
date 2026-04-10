"""
    barelibp2p/types.jl

Provider types for BareLibP2P P2P integration using pure Julia libp2p.
"""

import StructTypes
import BareLibP2P
import BareLibP2P.DHT
import BareLibP2P.GossipSub
import BareLibP2P.Identity
using Dates

using FlootyAbstract: AbstractProviderObject, AbstractAttachment, AbstractLLMProvider, AbstractMessage, AbstractTool, AbstractModel, AbstractChatResponse

# ═══════════════════════════════════════════════════════════════════════
# BareLibP2P Provider
# ═══════════════════════════════════════════════════════════════════════

mutable struct BareLibP2PProvider <: AbstractLLMProvider
    node_running::Bool
    bootstrap_peers::Vector{String}
    service_topic::String
    p2p_port::Int
    api_port::Int
    bootstrap_node::Bool
    
    # BareLibP2P node state
    identity::Union{Nothing, BareLibP2P.Identity.PrivateKey}
    peer_id::String
    dht::Union{Nothing, DHT.DHTNode}
    gossip::Union{Nothing, GossipSub.GossipSubNode}
    local_addrs::Vector{BareLibP2P.MultiaddrStruct}
    
    # Announced models
    announced_models::Vector{String}

    function BareLibP2PProvider(;
        bootstrap_peers::Vector{String}=String[],
        service_topic::String="peercompute-nodes-v1",
        p2p_port::Int=4001,
        api_port::Int=5001,
        bootstrap_node::Bool=false
    )
        new(false, bootstrap_peers, service_topic, p2p_port, api_port, bootstrap_node,
            nothing, "", nothing, nothing, BareLibP2P.MultiaddrStruct[], String[])
    end
end

StructTypes.StructType(::Type{BareLibP2PProvider}) = StructTypes.Mutable()

# ═══════════════════════════════════════════════════════════════════════
# Process-level singleton: only one P2P node per process
# ═══════════════════════════════════════════════════════════════════════
const GLOBAL_BARELIBP2P_PROVIDER = Ref{Union{BareLibP2PProvider, Nothing}}(nothing)

# ═══════════════════════════════════════════════════════════════════════
# Messages
# ═══════════════════════════════════════════════════════════════════════

@kwdef struct BareLibP2PMessage <: AbstractMessage
    role::String = "user"
    content::Union{String, Nothing} = nothing
    thinking::Union{String, Nothing} = nothing
    _type::String = "BareLibP2PMessage"
end

StructTypes.StructType(::Type{BareLibP2PMessage}) = StructTypes.Struct()
StructTypes.omitempties(::Type{BareLibP2PMessage}) = (:content, :thinking)
StructTypes.defaults(::Type{BareLibP2PMessage}) = (role = "user", _type = "BareLibP2PMessage")

# ═══════════════════════════════════════════════════════════════════════
# Chat Response
# ═══════════════════════════════════════════════════════════════════════

struct BareLibP2PResponse <: AbstractChatResponse
    message::BareLibP2PMessage
    model::Union{String, Nothing}
    peer_id::Union{String, Nothing}
    latency_ms::Int
    success::Bool
end

StructTypes.StructType(::Type{BareLibP2PResponse}) = StructTypes.Struct()
StructTypes.omitempties(::Type{BareLibP2PResponse}) = (:model, :peer_id)

FlootyAbstract.response_message(response::BareLibP2PResponse) = response.message

# ═══════════════════════════════════════════════════════════════════════
# P2P Inference Response
# ═══════════════════════════════════════════════════════════════════════

"""Raw response from P2P inference"""
Base.@kwdef struct BareLibP2PInferenceResponse
    status::String = "unknown"
    response::String = ""
    model::String = ""
    timestamp::Int = 0
end

StructTypes.StructType(::Type{BareLibP2PInferenceResponse}) = StructTypes.Struct()
StructTypes.omitempties(::Type{BareLibP2PInferenceResponse}) = (:model, :timestamp)

# ═══════════════════════════════════════════════════════════════════════
# Model Information
# ═══════════════════════════════════════════════════════════════════════

@kwdef struct BareLibP2PModel <: AbstractModel
    name::String
    peer_id::Union{String, Nothing} = nothing
    reputation::Float64 = 1.0
    latency_ms::Int = 0
end

StructTypes.StructType(::Type{BareLibP2PModel}) = StructTypes.Struct()
StructTypes.omitempties(::Type{BareLibP2PModel}) = (:peer_id,)

FlootyAbstract.model_name(model::BareLibP2PModel) = model.name
FlootyAbstract.model_provider(model::BareLibP2PModel) = :barelibp2p

function Base.show(io::IO, model::BareLibP2PModel)
    print(io, "BareLibP2PModel(", model.name, ")")
    !isnothing(model.peer_id) && print(io, " peer=", model.peer_id[1:min(12, length(model.peer_id))], "...")
end

# ═══════════════════════════════════════════════════════════════════════
# Peer Information
# ═══════════════════════════════════════════════════════════════════════

struct BareLibP2PPeerInfo
    peer_id::String
    addrs::Vector{BareLibP2P.MultiaddrStruct}
    models::Vector{String}
    last_seen::Float64
end

# ═══════════════════════════════════════════════════════════════════════
# Service Announcement
# ═══════════════════════════════════════════════════════════════════════

"""Service announcement published to GossipSub"""
Base.@kwdef struct BareLibP2PServiceAnnouncement
    node_id::String
    models::Vector{String}
    timestamp::Float64
    p2p_port::Int
    api_port::Int
end

StructTypes.StructType(::Type{BareLibP2PServiceAnnouncement}) = StructTypes.Struct()
