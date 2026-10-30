"""
    flootycompute/types.jl

FlootyCompute is a P2P TRANSPORT (Rust/iroh via libflootycompute) that routes
requests to actual providers (Ollama, OpenAI, ...) running on remote peers.
"""

import StructTypes
using Dates

using FlootyAbstract: AbstractLLMProvider, AbstractModel, AbstractProviderObject, AbstractTool

mutable struct FlootyComputeProvider <: AbstractLLMProvider
    nodeRunning::Bool
    bootstrap_node::Bool
    bootstrap_peers::Vector{String}
    p2pPort::Int
    apiPort::Int
    discoveryTopic::String
    enableRelay::Bool
    enableMdns::Bool
    keyFile::Union{String,Nothing}
    apiUrl::Union{String,Nothing}
    nodeId::String
    wrapped::Union{AbstractLLMProvider,Nothing}
    model_providers::Dict{String,String}
    model_peers::Dict{String,String}

    function FlootyComputeProvider(;
        bootstrap_node::Bool=false,
        bootstrap_peers::Vector{String}=String[],
        p2pPort::Int=0,
        apiPort::Int=0,
        discoveryTopic::String="flootycompute-nodes-v1",
        enableRelay::Bool=true,
        enableMdns::Bool=true,
        keyFile::Union{String,Nothing}=nothing,
        apiUrl::Union{String,Nothing}=nothing,
        wrapped::Union{AbstractLLMProvider,Nothing}=nothing,
    )
        new(false, bootstrap_node, bootstrap_peers, p2pPort, apiPort, discoveryTopic,
            enableRelay, enableMdns, keyFile, apiUrl, "",
            wrapped, Dict{String,String}(), Dict{String,String}())
    end
end

StructTypes.StructType(::Type{FlootyComputeProvider}) = StructTypes.Mutable()

const GLOBAL_FLOOTYCOMPUTE_PROVIDER = Ref{Union{FlootyComputeProvider,Nothing}}(nothing)

# ─── Model info ────────────────────────────────────────────────────────

@kwdef struct FlootyComputeModel <: AbstractModel
    name::String
    original_provider::String = "ollama"
    peer_id::Union{String,Nothing} = nothing
    capabilities::Vector{Symbol} = Symbol[]
end

StructTypes.StructType(::Type{FlootyComputeModel}) = StructTypes.Struct()
StructTypes.omitempties(::Type{FlootyComputeModel}) = (:peer_id,)

FlootyAbstract.model_name(m::FlootyComputeModel) = m.name
FlootyAbstract.model_provider(m::FlootyComputeModel) = :flootycompute

FlootyStreams.model_capabilities(m::FlootyComputeModel) = m.capabilities
FlootyStreams.has_capability(m::FlootyComputeModel, c::Symbol) = c in m.capabilities
