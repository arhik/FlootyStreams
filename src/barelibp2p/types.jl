"""
    barelibp2p/types.jl

BareLibP2P is a P2P TRANSPORT that routes to actual providers (Ollama, OpenAI, etc.)
"""

import StructTypes
import BareLibP2P
using Dates

using FlootyAbstract: AbstractLLMProvider, AbstractModel, AbstractProviderObject, AbstractTool


# ═══════════════════════════════════════════════════════════════════════
# Peer Selection Strategy — abstraction for choosing which peer to route to
# ═══════════════════════════════════════════════════════════════════════

"""
    PeerSelectionStrategy

Abstract type for peer selection strategies.
Implementations decide which peer to route a model request to.
"""
abstract type PeerSelectionStrategy end

"""
    FirstMatchStrategy

Returns the first peer in the list that has the requested model.
Simple, predictable, no overhead.
"""
struct FirstMatchStrategy <: PeerSelectionStrategy end

"""
    RandomPeerStrategy

Picks a random peer from those that have the requested model.
Provides basic load distribution across peers.

TODO: implement random selection
"""
struct RandomPeerStrategy <: PeerSelectionStrategy end

"""
    LatencyAwareStrategy

Prefers peers with lowest measured round-trip time.
Requires periodic latency probes to each peer.

TODO: implement latency tracking and probing
"""
struct LatencyAwareStrategy <: PeerSelectionStrategy end

"""
    RoundRobinStrategy

Distributes requests evenly across all peers that have the model.
Uses a per-model round-robin counter.

TODO: implement round-robin counter
"""
struct RoundRobinStrategy <: PeerSelectionStrategy end

# Default strategy — first match keeps current behavior
const DEFAULT_PEER_SELECTOR = FirstMatchStrategy()

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
    dht::Union{Nothing, BareLibP2P.DHT.DHTNode}
    gossip::Union{Nothing, BareLibP2P.GossipSub.GossipSubNode}
    transport::Union{Nothing, BareLibP2P.Transport.TransportNode}
    local_addrs::Vector{BareLibP2P.Multiaddr.MultiaddrStruct}

    # Model routing: model_name => "ollama" / "openai" / etc
    model_providers::Dict{String,String}

    # Peer routing: model_name => (peer_id, provider_type)
    model_peers::Dict{String,Tuple{String,String}}

    # LOCAL actual provider instance!
    # When set, chat() delegates to this provider
    local_provider::Union{AbstractLLMProvider,Nothing}

    # Peer selection strategy for routing requests
    peer_selector::PeerSelectionStrategy

    function BareLibP2PProvider(;
        bootstrap_peers::Vector{String}=String[],
        service_topic::String="barelibp2p-nodes-v1",
        p2p_port::Int=4001,
        api_port::Int=5001,
        bootstrap_node::Bool=false,
        local_provider::Union{AbstractLLMProvider,Nothing}=nothing,
        peer_selector::PeerSelectionStrategy=DEFAULT_PEER_SELECTOR
    )
        new(false, bootstrap_peers, service_topic, p2p_port, api_port, bootstrap_node,
            nothing, "", nothing, nothing, nothing, BareLibP2P.Multiaddr.MultiaddrStruct[],
            Dict{String,String}(), Dict{String,Tuple{String,String}}(),
            local_provider, peer_selector)
    end
end

StructTypes.StructType(::Type{BareLibP2PProvider}) = StructTypes.Mutable()

const GLOBAL_BARELIBP2P_PROVIDER = Ref{Union{BareLibP2PProvider,Nothing}}(nothing)

# ═══════════════════════════════════════════════════════════════════════
# Model Info
# ═══════════════════════════════════════════════════════════════════════

@kwdef struct BareLibP2PModel <: AbstractModel
    name::String
    original_provider::String  # "ollama", "openai"
    peer_id::Union{String,Nothing} = nothing
end

StructTypes.StructType(::Type{BareLibP2PModel}) = StructTypes.Struct()
StructTypes.omitempties(::Type{BareLibP2PModel}) = (:peer_id,)

FlootyAbstract.model_name(m::BareLibP2PModel) = m.name
FlootyAbstract.model_provider(m::BareLibP2PModel) = :barelibp2p

# ═══════════════════════════════════════════════════════════════════════
# Peer Info
# ═══════════════════════════════════════════════════════════════════════

struct BareLibP2PPeerInfo
    peer_id::String
    addrs::Vector{BareLibP2P.Multiaddr.MultiaddrStruct}
    models::Dict{String,String}  # model_name => provider_type
    last_seen::Float64
end

# ═══════════════════════════════════════════════════════════════════════
# P2P Request/Response
# ═══════════════════════════════════════════════════════════════════════

@kwdef struct BareLibP2PChatRequest
    original_provider::String
    model::String
    messages::Vector{<:AbstractProviderObject}
    tools::Vector{<:AbstractTool}
    stream::Bool = false
end

StructTypes.StructType(::Type{BareLibP2PChatRequest}) = StructTypes.Struct()

@kwdef struct BareLibP2PChatResponse
    success::Bool
    response_json::String
    error::Union{String,Nothing} = nothing
end

StructTypes.StructType(::Type{BareLibP2PChatResponse}) = StructTypes.Struct()
StructTypes.omitempties(::Type{BareLibP2PChatResponse}) = (:error,)
