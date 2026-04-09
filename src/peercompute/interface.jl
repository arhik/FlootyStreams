"""
    peercompute/interface.jl

Interface implementations for FlootyAbstract.
"""

using PeerCompute

# ═══════════════════════════════════════════════════════════════════════
# Message Interface
# ═══════════════════════════════════════════════════════════════════════

FlootyAbstract.role(msg::PeerComputeMessage) = msg.role
FlootyAbstract.content(msg::PeerComputeMessage) = msg.content

FlootyAbstract.create_message(provider::PeerComputeProvider, role::String, content::String) =
    PeerComputeMessage(role=role, content=content)

FlootyAbstract.create_message(provider::PeerComputeProvider, role::String, content::String, images::Vector{<:AbstractProviderObject}) =
    error("PeerCompute does not support image attachments")

FlootyAbstract.create_message(provider::PeerComputeProvider, role::String, content::String, attachments::Vector{<:AbstractAttachment}) =
    error("PeerCompute does not support attachments")

FlootyAbstract.tool_calls(msg::PeerComputeMessage) = nothing

# ═══════════════════════════════════════════════════════════════════════
# Image Attachments (not supported)
# ═══════════════════════════════════════════════════════════════════════

FlootyAbstract.create_attachments(provider::PeerComputeProvider, paths::Vector{String}, mime_types::Vector{String}) =
    error("PeerCompute does not support attachments")

FlootyAbstract.create_image_data(provider::PeerComputeProvider, path::String) =
    error("PeerCompute does not support image attachments")

FlootyAbstract.images(msg::PeerComputeMessage) = nothing

# ═══════════════════════════════════════════════════════════════════════
# Provider Instance
# ═══════════════════════════════════════════════════════════════════════

function FlootyAbstract.create_provider_instance(::Val{:peercompute}; config::Dict{Symbol, Any} = Dict{Symbol, Any}())
    # Support both direct bootstrap_peers and nested bootstrap config
    bootstrap_peers = get(config, :bootstrap_peers, String[])
    
    # Also check for bootstrap.multiaddresses from FlootyCore
    if haskey(config, :bootstrap) && config[:bootstrap] isa Dict
        bootstrap = config[:bootstrap]
        if haskey(bootstrap, :multiaddresses)
            addrs = bootstrap[:multiaddresses]
            append!(bootstrap_peers, addrs)
        end
        if haskey(bootstrap, :enable) && bootstrap[:enable]
            @info "PeerCompute configured with FlootyCore bootstrap node"
        end
    end
    
    service_topic = get(config, :service_topic, "peercompute-nodes-v1")
    PeerComputeProvider(bootstrap_peers=bootstrap_peers, service_topic=service_topic)
end

FlootyAbstract.provider_name(provider::PeerComputeProvider) = :peercompute

# ═══════════════════════════════════════════════════════════════════════
# Model Discovery
# ═══════════════════════════════════════════════════════════════════════

function FlootyAbstract.list_provider_models(::Val{:peercompute}, config::Dict{Symbol,Any})
    # Get verified peers
    peers = PeerCompute.get_verified_peers_by_topic(get(config, :service_topic, "peercompute-nodes-v1"))
    
    models = PeerComputeModel[]
    for peer in peers
        peer_models = PeerCompute.get_peer_models(peer)
        for model_name in peer_models
            push!(models, PeerComputeModel(
                name=model_name,
                peer_id=peer
            ))
        end
    end
    
    return models
end

# ═══════════════════════════════════════════════════════════════════════
# Chat/Stream Interface
# ═══════════════════════════════════════════════════════════════════════

function FlootyAbstract.create_stream(provider::PeerComputeProvider, model::String, messages::Vector{<:AbstractMessage},
    stream::Bool=false,
    format::Union{Nothing, OrderedDict}=nothing,
    options::Union{Nothing, Dict{String,Any}}=nothing,
    tools::Union{Vector{<:AbstractTool}, Nothing}=nothing)
    
    # Build prompt from messages
    prompt = build_prompt_from_messages(messages)
    
    # Get verified peers for this topic
    peers = PeerCompute.get_verified_peers_by_topic(provider.service_topic)
    isempty(peers) && throw(error("No peers available for topic: $(provider.service_topic)"))
    
    # Select best peer (could use reputation here)
    peer_id = peers[1]
    
    # Send inference request
    result = PeerCompute.send_inference_request(peer_id, model, prompt)
    
    # Build response
    msg = PeerComputeMessage(
        role="assistant",
        content=result.response
    )
    
    return PeerComputeResponse(msg, model, peer_id, Int(result.latency_ms), result.success)
end

function FlootyAbstract.chat_stream(provider::PeerComputeProvider, model::String, messages::Vector{<:AbstractMessage},
    stream::Bool=false,
    format::Union{Nothing, OrderedDict}=nothing,
    options::Union{Nothing, Dict{String,Any}}=nothing,
    tools::Union{Vector{<:AbstractTool}, Nothing}=nothing)
    
    # PeerCompute uses synchronous inference
    FlootyAbstract.create_stream(provider, model, messages, stream, format, options, tools)
end

# ═══════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════

function build_prompt_from_messages(messages::Vector{<:AbstractMessage})::String
    io = IOBuffer()
    
    for msg in messages
        role = FlootyAbstract.role(msg)
        content = FlootyAbstract.content(msg)
        content === nothing && continue
        
        if role == "system"
            println(io, "System: ", content)
        elseif role == "user"
            println(io, "User: ", content)
        elseif role == "assistant"
            println(io, "Assistant: ", content)
        elseif role == "tool"
            println(io, "Tool result: ", content)
        end
    end
    
    # Add final assistant prompt
    println(io, "Assistant: ")
    
    return String(take!(io))
end

# ═══════════════════════════════════════════════════════════════════════
# Tool Building (not supported)
# ═══════════════════════════════════════════════════════════════════════

function FlootyAbstract.build_tool(tool::FlootyAbstract.AbstractTool, provider::PeerComputeProvider)
    error("PeerCompute does not support tool calling")
end

# ═══════════════════════════════════════════════════════════════════════
# Embedder (not supported)
# ═══════════════════════════════════════════════════════════════════════

FlootyAbstract.create_embedder(provider::PeerComputeProvider, model::String; kwargs...) =
    error("PeerCompute does not support embeddings")
