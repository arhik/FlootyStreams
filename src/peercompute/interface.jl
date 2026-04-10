"""
    peercompute/interface.jl

Interface implementations for FlootyAbstract.

Architecture:
──────────────────────────────────────────────────────────────
  FlootyCore (Provider)                FlootyApp (Consumer)
  ┌──────────────────────┐            ┌──────────────────────┐
  │ Bootstrap + Peer      │◄─── P2P ──►│ Peer (no Ollama)     │
  │ Has Ollama locally    │            │ Discovers models     │
  │ Announces models      │            │ Forwards requests    │
  │ Serves inference      │            │ via P2P              │
  └──────────────────────┘            └──────────────────────┘

  FlootyApp NEVER calls Ollama directly.
  It discovers peers via P2P and forwards inference requests.

  FlootyCore serves inference when peers request it (handled in Go).
  FlootyCore can also consume — but only via P2P (never self).

Usage:
  # In FlootyCore (bootstrap node with Ollama):
  provider = create_provider_instance(:peercompute; config=Dict(
    :bootstrap_node => true,
    :p2p_port => 4002,
    :api_port => 5002,
  ))
  start_provider(provider)

  # In FlootyApp (consumer, no Ollama needed):
  provider = create_provider_instance(:peercompute; config=Dict(
    :bootstrap_peers => ["/ip4/127.0.0.1/tcp/4002/p2p/<id>"],
    :p2p_port => 4001,
    :api_port => 5001,
  ))
  start_provider(provider)

  # Use inference (routes through P2P to the peer that has the model):
  messages = [create_message(provider, "user", "Hello!")]
  response = create_stream(provider, "qwen3.5:cloud", messages)
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
# Provider Instance & Lifecycle
# ═══════════════════════════════════════════════════════════════════════

function FlootyAbstract.create_provider_instance(::Val{:peercompute}; config::Dict{Symbol, Any} = Dict{Symbol, Any}())
    # Singleton: only one P2P node per process (Go limitation)
    # If a provider already exists and is running, return it regardless of config.
    existing = GLOBAL_PROVIDER[]
    if existing !== nothing && existing.node_running
        return existing
    end
    
    # Build config from ENV + explicit config (ENV provides defaults, config overrides)
    bootstrap_peers = get(config, :bootstrap_peers, String[])
    env_bootstrap = get(ENV, "PEERCOMPUTE_BOOTSTRAP_ADDR", "")
    if !isempty(env_bootstrap)
        # ENV can contain comma-separated addresses
        for addr in split(env_bootstrap, ",")
            addr = strip(addr)
            !isempty(addr) && push!(bootstrap_peers, addr)
        end
    end
    
    service_topic = get(config, :service_topic, "peercompute-node-v1")
    p2p_port = get(config, :p2p_port, parse(Int, get(ENV, "PEERCOMPUTE_P2P_PORT", "4001")))
    api_port = get(config, :api_port, parse(Int, get(ENV, "PEERCOMPUTE_API_PORT", "5001")))
    bootstrap_node = get(config, :bootstrap_node, get(ENV, "PEERCOMPUTE_BOOTSTRAP", "") == "true")
    
    # If a provider exists but isn't running, update its config
    if existing !== nothing
        existing.bootstrap_peers = bootstrap_peers
        existing.service_topic = service_topic
        existing.p2p_port = p2p_port
        existing.api_port = api_port
        existing.bootstrap_node = bootstrap_node
        return existing
    end
    
    provider = PeerComputeProvider(
        bootstrap_peers=bootstrap_peers,
        service_topic=service_topic,
        p2p_port=p2p_port,
        api_port=api_port,
        bootstrap_node=bootstrap_node,
    )
    GLOBAL_PROVIDER[] = provider
    return provider
end

"""
    start_provider(provider::PeerComputeProvider; config=Dict())

Start the PeerCompute P2P node.

- If `bootstrap_node=true`, starts a bootstrap node first, then a peer node.
- If `bootstrap_peers` is set, starts a peer node that connects to them.
- If neither, starts a standalone peer node (for local testing).
"""
function start_provider(provider::PeerComputeProvider; config::Dict{Symbol,Any}=Dict{Symbol,Any}())
    if provider.node_running
        # Already running — just announce models if requested
        models = get(config, :models, String[])
        if !isempty(models)
            PeerCompute.announce_models(models)
        end
        return true
    end
    
    try
        # ── Bootstrap node (if configured) ──
        if provider.bootstrap_node
            bootstrap_key = get(config, :bootstrap_key, "keys/bootstrap.key")
            mkpath(dirname(bootstrap_key))
            
            if !isfile(bootstrap_key)
                result = PeerCompute.generate_static_key(bootstrap_key)
                result != 0 && (@error "Failed to generate bootstrap key"; return false)
                @info "Generated bootstrap key: $bootstrap_key"
            end
            
            @info "Starting PeerCompute bootstrap node on port $(provider.p2p_port)..."
            PeerCompute.start_bootstrap_node(provider.p2p_port, provider.api_port, bootstrap_key)
            sleep(2)
            
            bootstrap_id = PeerCompute.get_bootstrap_node_id()
            bootstrap_addrs = PeerCompute.get_bootstrap_multiaddresses()
            @info "Bootstrap node started" bootstrap_id = bootstrap_id
            
            # Peer runs on different ports than bootstrap
            peer_p2p_port = provider.p2p_port + 10
            peer_api_port = provider.api_port + 10
            
            # Build full bootstrap addresses (add /p2p/<id> if missing)
            full_bootstrap_addrs = String[]
            for addr in bootstrap_addrs
                if !contains(addr, "/p2p/")
                    push!(full_bootstrap_addrs, "$addr/p2p/$bootstrap_id")
                else
                    push!(full_bootstrap_addrs, addr)
                end
            end
            
            # Set ENV so any future provider instances can find the bootstrap
            ENV["PEERCOMPUTE_BOOTSTRAP_ADDR"] = join(full_bootstrap_addrs, ",")
            
            provider.bootstrap_peers = full_bootstrap_addrs
            provider.p2p_port = peer_p2p_port
            provider.api_port = peer_api_port
        end
        
        # ── Peer node ──
        peer_key = get(config, :peer_key, "keys/peer.key")
        mkpath(dirname(peer_key))
        
        if !isfile(peer_key)
            result = PeerCompute.generate_static_key(peer_key)
            result != 0 && (@error "Failed to generate peer key"; return false)
            @info "Generated peer key: $peer_key"
        end
        
        models = get(config, :models, String[])
        enable_mdns = get(config, :enable_mdns, true)
        
        settings = PeerCompute.PeerComputeSettings(
            provider.p2p_port,
            provider.api_port,
            provider.bootstrap_peers,
            String[],                       # allowed_models
            "info",                         # log_level
            false,                          # enable_tls
            60,                             # request_timeout
            120,                            # ollama_timeout
            10,                             # max_concurrent_requests
            15,                             # discovery_interval
            "0.0.0.0",                      # bind_address
            provider.service_topic,         # service_topic
            false,                          # use_ipfs_bootstrap
            String[],                       # ipfs_bootstrap_peers
            true,                           # enable_nat
            true,                           # enable_relay
            true,                           # enable_hole_punching
            enable_mdns,                    # enable_mdns
            "",                             # external_address
            String[],                       # announce_addresses
            true,                           # peer_exchange_enabled
            50,                             # max_peer_connections
            3,                              # retry_attempts
            1.0,                            # retry_delay
            0.7,                            # reputation_threshold
            peer_key                        # static_key_file
        )
        
        @info "Starting PeerCompute peer node on port $(provider.p2p_port)..." bootstrap_count=length(provider.bootstrap_peers)
        PeerCompute.start_daemon(settings)
        sleep(3)
        
        if !isempty(models)
            PeerCompute.announce_models(models)
            @info "Announced $(length(models)) models"
        end
        
        provider.node_running = true
        @info "PeerCompute node started" peer_id=PeerCompute.get_node_id()
        return true
        
    catch e
        @error "Failed to start PeerCompute node" exception=(e, catch_backtrace())
        return false
    end
end

"""
    stop_provider(provider::PeerComputeProvider)

Stop the PeerCompute P2P node.
"""
function stop_provider(provider::PeerComputeProvider)
    if !provider.node_running
        @warn "PeerCompute node is not running"
        return
    end
    
    try; PeerCompute.stop_daemon(); catch e; @warn "Error stopping peer node" exception = e; end
    if provider.bootstrap_node
        try; PeerCompute.stop_bootstrap_node(); catch e; @warn "Error stopping bootstrap" exception = e; end
    end
    
    provider.node_running = false
    GLOBAL_PROVIDER[] = nothing
    @info "PeerCompute node stopped"
end

FlootyAbstract.provider_name(provider::PeerComputeProvider) = :peercompute

# ═══════════════════════════════════════════════════════════════════════
# Model Discovery
# ═══════════════════════════════════════════════════════════════════════

function FlootyAbstract.list_provider_models(::Val{:peercompute}, config::Dict{Symbol,Any})
    models = PeerComputeModel[]
    
    # Only models discovered via P2P from remote peers
    # Local Ollama models are listed by the :ollama provider, not here
    discovered = PeerCompute.get_discovered_nodes()
    for (peer_id, node_info) in discovered
        for model_name in get(node_info, "model_names", String[])
            push!(models, PeerComputeModel(name=model_name, peer_id=peer_id))
        end
    end
    
    return models
end

# ═══════════════════════════════════════════════════════════════════════
# Chat / Stream — Pure P2P forwarding
#
# FlootyApp NEVER calls Ollama directly.
# It discovers which peer has the model and sends the request
# through P2P. The peer (FlootyCore) handles it locally.
# ═══════════════════════════════════════════════════════════════════════

function FlootyAbstract.create_stream(provider::PeerComputeProvider, model::String, messages::Vector{<:AbstractMessage};
    stream::Bool=false,
    format::Union{Nothing, OrderedDict}=nothing,
    options::Union{Nothing, Dict{String,Any}}=nothing,
    tools::Union{Vector{<:AbstractTool}, Nothing}=nothing)
    
    # Auto-start if not running
    if !provider.node_running
        @info "PeerCompute node not running, attempting auto-start..."
        started = start_provider(provider)
        if !started
            error("Failed to start PeerCompute node. Call start_provider(provider) first.")
        end
    end
    
    prompt = build_prompt_from_messages(messages)
    our_id = try; PeerCompute.get_node_id(); catch; ""; end
    
    # ── Step 1: Find a remote peer that has the requested model ──
    discovered = PeerCompute.get_discovered_nodes()
    verified_peers = PeerCompute.get_verified_peers_by_topic(provider.service_topic)
    
    # Also try connected peers if no verified ones yet
    if isempty(verified_peers)
        verified_peers = PeerCompute.get_connected_peers()
    end
    
    # Select peer: prefer one that advertises the model, skip ourselves
    target_peer = nothing
    
    # First pass: find a verified remote peer that has the model
    for peer_id in verified_peers
        peer_id == our_id && continue  # never connect to ourselves
        if haskey(discovered, peer_id)
            peer_models = get(discovered[peer_id], "model_names", String[])
            if model in peer_models
                target_peer = peer_id
                break
            end
        end
    end
    
    # Second pass: any verified remote peer (model may not be discovered yet)
    if target_peer === nothing
        for peer_id in verified_peers
            peer_id == our_id && continue
            target_peer = peer_id
            break
        end
    end
    
    if target_peer === nothing
        error("No remote peers available for topic '$(provider.service_topic)'. " *
              "Ensure a FlootyCore node with Ollama is running and connected to the network.")
    end
    
    # ── Step 2: Forward inference request to the remote peer via P2P ──
    @info "Forwarding inference to peer" peer = target_peer[1:min(20, length(target_peer))] * "..." model = model
    
    result = PeerCompute.send_inference_request(target_peer, model, prompt)
    
    # Parse the P2P response
    # result can be: Dict("status"=>"success", "response"=>"text", ...)
    # or nested: Dict("status"=>"success", "response"=>Dict(...))
    
    if result isa Dict
        status_val = get(result, "status", "unknown")
        
        # Extract response text - handle flat or nested JSON
        raw_response = get(result, "response", result)
        if raw_response isa Dict
            response_text = string(get(raw_response, "response", raw_response))
        else
            response_text = string(raw_response)
        end
        
        if status_val == "error"
            error_msg = string(get(result, "message", result))
            error("P2P inference failed: $error_msg")
        end
        
        msg = PeerComputeMessage(role="assistant", content=response_text)
        return PeerComputeResponse(msg, model, target_peer, 0, status_val == "success")
    else
        msg = PeerComputeMessage(role="assistant", content=string(result))
        return PeerComputeResponse(msg, model, target_peer, 0, true)
    end
end

function FlootyAbstract.chat_stream(provider::PeerComputeProvider, model::String, messages::Vector{<:AbstractMessage};
    stream::Bool=false, format=nothing, options=nothing, tools=nothing)
    FlootyAbstract.create_stream(provider, model, messages; stream, format, options, tools)
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
    println(io, "Assistant: ")
    return String(take!(io))
end

# ═══════════════════════════════════════════════════════════════════════
# Tool Building / Embedder (not supported)
# ═══════════════════════════════════════════════════════════════════════

FlootyAbstract.build_tool(tool::FlootyAbstract.AbstractTool, provider::PeerComputeProvider) =
    error("PeerCompute does not support tool calling")

FlootyAbstract.create_embedder(provider::PeerComputeProvider, model::String; kwargs...) =
    error("PeerCompute does not support embeddings")