"""
    peercompute/interface.jl

Interface implementations for FlootyAbstract.

Local Peer Discovery (Layer 1):
    Same machine:  ~/.flooty/bootstrap_info.json (written by bootstrap, read by peers)
    Default port:  4002 (bootstrap), 4012 (peer)
    Static key:    ~/.flooty/bootstrap.key → deterministic peer ID
    → Zero config on same machine. Just works.

Future layers:
    LAN:      mDNS auto-discovery
    Internet: Public bootstrap nodes, DNS, relay
"""

using PeerCompute
using JSON
using Sockets
# ════════════════════════════════════════════════════════════════════
# Local Discovery Constants
# ════════════════════════════════════════════════════════════════════

"""Default directory for PeerCompute state (keys, bootstrap info, etc.)"""
const FLOOTY_DIR = joinpath(homedir(), ".flooty")

"""Default bootstrap P2P port"""
const DEFAULT_BOOTSTRAP_P2P_PORT = 9002
const DEFAULT_BOOTSTRAP_API_PORT = 9003

"""Default peer P2P port (offset from bootstrap)"""
const DEFAULT_PEER_P2P_PORT = 9012
const DEFAULT_PEER_API_PORT = 9013

"""Path to bootstrap info file (written by bootstrap node, read by peers)"""
const BOOTSTRAP_INFO_FILE = joinpath(FLOOTY_DIR, "bootstrap_info.json")

"""Path to the default bootstrap key"""
const DEFAULT_BOOTSTRAP_KEY = joinpath(FLOOTY_DIR, "bootstrap.key")

"""Path to the default peer key"""
const DEFAULT_PEER_KEY = joinpath(FLOOTY_DIR, "peer.key")

# ═══════════════════════════════════════════════════════════════════════
# Local Discovery Helpers
# ═══════════════════════════════════════════════════════════════════════

"""
    write_bootstrap_info(node_id, p2p_port, api_port, multiaddresses)

Write bootstrap info to `~/.flooty/bootstrap_info.json` so local peers
can find this bootstrap node without being told the address.
"""
function write_bootstrap_info(node_id::String, p2p_port::Int, api_port::Int, multiaddresses)
    mkpath(FLOOTY_DIR)
    # Ensure multiaddresses is Vector{String}
    addr_strings = [String(a) for a in multiaddresses]
    info = Dict{String, Any}(
        "node_id" => node_id,
        "p2p_port" => p2p_port,
        "api_port" => api_port,
        "multiaddresses" => multiaddresses,
        "updated_at" => string(Dates.now()),
    )
    # Build full peer addresses
    peer_addrs = String[]
    for addr in multiaddresses
        if contains(addr, "/p2p/")
            push!(peer_addrs, addr)
        else
            push!(peer_addrs, "$addr/p2p/$node_id")
        end
    end
    info["peer_addresses"] = peer_addrs
    
    open(BOOTSTRAP_INFO_FILE, "w") do f
        JSON.print(f, info, 2)
    end
    @info "Wrote bootstrap info to $BOOTSTRAP_INFO_FILE"
    return info
end

"""
    read_bootstrap_info() -> Union{Dict, Nothing}

Read bootstrap info from `~/.flooty/bootstrap_info.json`.
Returns nothing if file doesn't exist or is invalid.
"""
function read_bootstrap_info()
    if !isfile(BOOTSTRAP_INFO_FILE)
        return nothing
    end
    try
        info = JSON.parsefile(BOOTSTRAP_INFO_FILE)
        # Validate it has what we need
        if haskey(info, "peer_addresses") && !isempty(info["peer_addresses"])
            return info
        end
        # Fallback: reconstruct from node_id + multiaddresses
        if haskey(info, "node_id") && haskey(info, "multiaddresses")
            addrs = String[]
            for addr in info["multiaddresses"]
                if contains(addr, "/p2p/")
                    push!(addrs, addr)
                else
                    push!(addrs, "$addr/p2p/$(info["node_id"])")
                end
            end
            info["peer_addresses"] = addrs
            return info
        end
        return nothing
    catch e
        @debug "Could not read bootstrap info" error=e
        return nothing
    end
end

"""
    discover_local_bootstrap() -> Vector{String}

Find bootstrap peer addresses through local discovery:
1. Check ENV (PEERCOMPUTE_BOOTSTRAP_ADDR) — explicit override
2. Check ~/.flooty/bootstrap_info.json — written by local bootstrap
Returns a list of full multiaddresses (e.g. ["/ip4/127.0.0.1/tcp/4002/p2p/12D3KooW..."])
"""
function discover_local_bootstrap()
    # Layer 0: ENV override (highest priority)
    env_addr = get(ENV, "PEERCOMPUTE_BOOTSTRAP_ADDR", "")
    if !isempty(env_addr)
        addrs = [String(strip(a)) for a in split(env_addr, ",") if !isempty(strip(a))]
        if !isempty(addrs)
            @info "Found bootstrap from ENV" addrs=addrs
            return addrs
        end
    end
    
    # Layer 1: Local bootstrap info file
    info = read_bootstrap_info()
    if info !== nothing
        raw_addrs = get(info, "peer_addresses", [])
        addrs = [String(a) for a in raw_addrs]
        if !isempty(addrs)
            @info "Found bootstrap from local info file" addrs=addrs
            return addrs
        end
    end
    
    return String[]
end

# ═══════════════════════════════════════════════════════════════════════
# Message Interface
# ═══════════════════════════════════════════════════════════════════════

# Guard: PeerCompute requires a wrapped provider for all message/tool operations.
_require_wrapped(provider::PeerComputeProvider) =
    provider.wrapped === nothing && error("PeerCompute requires a wrapped provider (e.g. OllamaProvider). Set the :wrapped config key when creating the provider.")


# Lock to serialize PeerCompute auto-start (avoids concurrent start_daemon races)
const start_lock = ReentrantLock()
# PeerCompute does NOT define its own message type — it always delegates
# to the wrapped provider (typically OllamaProvider).
# Delegate message creation to wrapped provider when available
function FlootyAbstract.create_message(provider::PeerComputeProvider, role::String, content::String; tool_name::Union{String,Nothing}=nothing)
    _require_wrapped(provider)
    return FlootyAbstract.create_message(provider.wrapped, role, content; tool_name=tool_name)
end

function FlootyAbstract.create_message(provider::PeerComputeProvider, role::String, content::String, images::Vector{<:AbstractProviderObject})
    _require_wrapped(provider)
    return FlootyAbstract.create_message(provider.wrapped, role, content, images)
end

function FlootyAbstract.create_message(provider::PeerComputeProvider, role::String, content::String, attachments::Vector{<:AbstractAttachment})
    _require_wrapped(provider)
    return FlootyAbstract.create_message(provider.wrapped, role, content, attachments)
end

# No PeerCompute-specific message interface methods — the wrapped provider's
# message type (e.g. OllamaMessage) is used directly throughout.

# ═══════════════════════════════════════════════════════════════════════
# Image Attachments (delegated to wrapped provider)
# ═══════════════════════════════════════════════════════════════════════

function FlootyAbstract.create_attachments(provider::PeerComputeProvider, paths::Vector{String}, mime_types::Vector{String})
    _require_wrapped(provider)
    return FlootyAbstract.create_attachments(provider.wrapped, paths, mime_types)
end

function FlootyAbstract.create_image_data(provider::PeerComputeProvider, path::String)
    _require_wrapped(provider)
    return FlootyAbstract.create_image_data(provider.wrapped, path)
end

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
    
    # ── Resolve config: explicit config > ENV > defaults ──
    bootstrap_node = get(config, :bootstrap_node, get(ENV, "PEERCOMPUTE_BOOTSTRAP", "") == "true")
    
    # Bootstrap peers: explicit config > ENV > local discovery
    bootstrap_peers = get(config, :bootstrap_peers, String[])
    if isempty(bootstrap_peers)
        bootstrap_peers = discover_local_bootstrap()
    end
    
    # Ports: explicit config > ENV > defaults (offset from bootstrap if bootstrap_node)
    if bootstrap_node
        p2p_port = get(config, :p2p_port, parse(Int, get(ENV, "PEERCOMPUTE_P2P_PORT", string(DEFAULT_BOOTSTRAP_P2P_PORT))))
        api_port = get(config, :api_port, parse(Int, get(ENV, "PEERCOMPUTE_API_PORT", string(DEFAULT_BOOTSTRAP_API_PORT))))
    else
        p2p_port = get(config, :p2p_port, parse(Int, get(ENV, "PEERCOMPUTE_P2P_PORT", string(DEFAULT_PEER_P2P_PORT))))
        api_port = get(config, :api_port, parse(Int, get(ENV, "PEERCOMPUTE_API_PORT", string(DEFAULT_PEER_API_PORT))))
    end
    
    # Get wrapped provider to delegate to (e.g., OllamaProvider)
    wrapped = get(config, :wrapped, nothing)
    
    # If a provider exists but isn't running, update its config
    if existing !== nothing
        existing.bootstrap_peers = bootstrap_peers
        existing.service_topic = get(config, :service_topic, "peercompute-nodes-v1")
        existing.p2p_port = p2p_port
        existing.api_port = api_port
        existing.bootstrap_node = bootstrap_node
        if wrapped !== nothing
            existing.wrapped = wrapped
        end
        return existing
    end
    
    provider = PeerComputeProvider{Any}(
        bootstrap_peers=bootstrap_peers,
        service_topic=get(config, :service_topic, "peercompute-nodes-v1"),
        p2p_port=p2p_port,
        api_port=api_port,
        bootstrap_node=bootstrap_node,
        wrapped=wrapped
    )
    GLOBAL_PROVIDER[] = provider
    return provider
end

"""
    start_provider(provider::PeerComputeProvider; config=Dict())

Start the PeerCompute P2P node.

- If `bootstrap_node=true`, starts a bootstrap node first, then a peer node.
  Writes bootstrap info to `~/.flooty/bootstrap_info.json` for local discovery.
- If `bootstrap_peers` is already set (from config or local discovery),
  starts a peer node that connects to them.
- If neither, tries local discovery first, then starts standalone.
"""
function start_provider(provider::PeerComputeProvider; config::Dict{Symbol,Any}=Dict{Symbol,Any}())
    lock(start_lock) do
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
                bootstrap_key = get(config, :bootstrap_key, DEFAULT_BOOTSTRAP_KEY)
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
                @info "Bootstrap node started" bootstrap_id=bootstrap_id

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

                provider.bootstrap_peers = full_bootstrap_addrs
                provider.p2p_port = peer_p2p_port
                provider.api_port = peer_api_port

                # Write bootstrap info for local discovery
                write_bootstrap_info(bootstrap_id, provider.p2p_port - 10, provider.api_port - 10, full_bootstrap_addrs)

                # Also set ENV so in-process providers can find it
                ENV["PEERCOMPUTE_BOOTSTRAP_ADDR"] = join(full_bootstrap_addrs, ",")
            else
                # Not a bootstrap node — make sure we have bootstrap peers
                if isempty(provider.bootstrap_peers)
                    @info "No custom bootstrap peers configured, will use IPFS bootstrap nodes for DHT discovery"
                end
            end

            # ── Peer node ──
            peer_key = get(config, :peer_key, DEFAULT_PEER_KEY)
            mkpath(dirname(peer_key))

            if !isfile(peer_key)
                result = PeerCompute.generate_static_key(peer_key)
                result != 0 && (@error "Failed to generate peer key"; return false)
                @info "Generated peer key: $peer_key"
            end

            models = get(config, :models, String[])
            # Auto-detect local Ollama models for bootstrap nodes (providers)
            if isempty(models) && provider.bootstrap_node
                try
                    models = PeerCompute.get_ollama_models()
                    @info "Auto-detected $(length(models)) local Ollama models"
                catch
                    @warn "Could not detect Ollama models"
                end
            end
            enable_mdns = get(config, :enable_mdns, true)
            enable_nat = get(config, :enable_nat, true)
            enable_relay = get(config, :enable_relay, true)
            enable_hole_punching = get(config, :enable_hole_punching, true)

            settings = PeerCompute.PeerComputeSettings(
                p2p_port=provider.p2p_port,
                api_port=provider.api_port,
                service_topic=provider.service_topic,
                enable_mdns=enable_mdns,
                enable_nat=enable_nat,
                enable_relay=enable_relay,
                enable_hole_punching=enable_hole_punching,
                static_key_file=peer_key,
                bootstrap_peers=provider.bootstrap_peers
            )

            @info "Starting PeerCompute peer node on port $(provider.p2p_port)..." bootstrap_count=length(provider.bootstrap_peers)
            PeerCompute.start_daemon(settings)
            sleep(6)  # Give DHT time to bootstrap and run initial peer search

            # Start Julia HTTP inference endpoint (handles Ollama /api/chat calls)
            start_inference_server(provider.api_port)


            if !isempty(models)
                PeerCompute.announce_models(models)
                @info "Announced $(length(models)) models"
            end

            provider.node_running = true
            @info "PeerCompute node started" peer_id=PeerCompute.get_node_id()

            # Debug: check peer discovery
            sleep(5)  # Give DHT rendezvous time to find peers
            connected = PeerCompute.get_connected_peers()
            @info "PeerCompute connected peers" count=length(connected) peers=connected
            verified = PeerCompute.get_verified_peers_by_topic(provider.service_topic)
            @info "PeerCompute verified peers for topic" topic=provider.service_topic count=length(verified) peers=verified
            return true

        catch e
            @error "Failed to start PeerCompute node" exception=(e, catch_backtrace())
            return false
        end
    end
end

"""
    stop_provider(provider::PeerComputeProvider)

Stop the PeerCompute P2P node. Cleans up the bootstrap info file.
"""
function stop_provider(provider::PeerComputeProvider)
    if !provider.node_running
        @warn "PeerCompute node is not running"
        return
    end

    # Stop inference HTTP server first
    stop_inference_server()

    try; PeerCompute.stop_daemon(); catch e; @warn "Error stopping peer node" exception=e; end
    if provider.bootstrap_node
        try; PeerCompute.stop_bootstrap_node(); catch e; @warn "Error stopping bootstrap" exception=e; end
        # Clean up local bootstrap info
        try; isfile(BOOTSTRAP_INFO_FILE) && rm(BOOTSTRAP_INFO_FILE); catch; end
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
    
    # Get verified peers (the reliable discovery mechanism)
    topic = if GLOBAL_PROVIDER[] !== nothing
        GLOBAL_PROVIDER[].service_topic
    else
        get(config, :service_topic, "peercompute-nodes-v1")
    end
    verified = try PeerCompute.get_verified_peers_by_topic(topic); catch; String[]; end
    our_id = try PeerCompute.get_node_id(); catch; ""; end
    
    for peer_id in verified
        peer_id == our_id && continue  # skip ourselves
        
        # Query each verified peer for its model list
        peer_models = try
            result = PeerCompute.get_peer_models(peer_id)
            get(result, "model_names", String[])
        catch
            String[]
        end
        
        for model_name in peer_models
            push!(models, PeerComputeModel(name=model_name, peer_id=peer_id))
        end
    end
    
    return models
end

# ═══════════════════════════════════════════════════════════════════════
# Chat / Stream — Pure P2P forwarding
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
    
    our_id = try; PeerCompute.get_node_id(); catch; ""; end
    
    # ── Step 1: Find a remote peer that has the requested model ──
    verified_peers = try; PeerCompute.get_verified_peers_by_topic(provider.service_topic); catch; String[]; end
    
    # Also try connected peers if no verified ones yet
    if isempty(verified_peers)
        verified_peers = try; PeerCompute.get_connected_peers(); catch; String[]; end
    end
    
    # Select peer: prefer one that has the model
    target_peer = nothing

    # First pass: find a verified peer that has the model
    for peer_id in verified_peers
        peer_id == our_id && continue  # skip ourselves by default
        peer_models = try
            result = PeerCompute.get_peer_models(peer_id)
            get(result, "model_names", String[])
        catch
            String[]
        end
        if !isempty(peer_models) && model in peer_models
            target_peer = peer_id
            break
        end
    end

    # Second pass: allow ourselves if no other peer has the model (local testing)
    if target_peer === nothing
        for peer_id in verified_peers
            peer_models = try
                result = PeerCompute.get_peer_models(peer_id)
                get(result, "model_names", String[])
            catch
                String[]
            end
            if !isempty(peer_models) && model in peer_models
                target_peer = peer_id
                break
            end
        end
    end

    # Third pass: any verified peer
    if target_peer === nothing
        for peer_id in verified_peers
            peer_id == our_id && continue
            target_peer = peer_id
            break
        end
    end

    # Fourth pass: any peer including ourselves (local testing fallback)
    if target_peer === nothing && !isempty(verified_peers)
        target_peer = verified_peers[1]
    end
    
    if target_peer === nothing
        error("No remote peers available for topic '$(provider.service_topic)'. " *
              "Ensure a FlootyCore node with Ollama is running and connected to the network.")
    end

    # If targeting ourselves, skip P2P and call wrapped provider directly
    if target_peer == our_id
        @info "Local inference (self-target), calling wrapped provider directly"
        _require_wrapped(provider)
        wrapped = provider.wrapped
        ollama_messages = [m isa OllamaMessage ? m : OllamaMessage(role=role(m), content=content(m)) for m in messages]
        ollama_tools = tools === nothing ? nothing : map(t -> FlootyAbstract.build_tool(t, wrapped), tools)
        chat_response = chat(wrapped, ollama_messages, model, stream, format, options, ollama_tools)
        msg = response_message(chat_response)
        return PeerComputeResponse(msg, model, target_peer)
    end
    
    @info "Forwarding inference to peer" peer=target_peer[1:min(20, length(target_peer))] * "..." model=model has_tools=(tools !== nothing && !isempty(tools))
    
    # ── Step 2: Build request using wrapped provider's types ──
    # Delegate to the wrapped provider (Ollama) for message/tool conversion,
    # then serialize the ChatRequest to JSON for P2P transport.
    _require_wrapped(provider)
    wrapped = provider.wrapped

    # Convert messages to wrapped provider's type (same as Ollama's create_stream)
    ollama_messages = [m isa OllamaMessage ? m : OllamaMessage(role=role(m), content=content(m)) for m in messages]

    # Convert tools using build_tool (same as Ollama's chat_stream)
    ollama_tools = if tools === nothing
        nothing
    else
        map(t -> FlootyAbstract.build_tool(t, wrapped), tools)
    end

    # Build ChatRequest using wrapped provider's native type
    chat_request = ChatRequest(
        model=model,
        messages=ollama_messages,
        stream=stream,
        format=format,
        options=options,
        tools=ollama_tools
    )

    # Serialize to JSON using JSON3 (Ollama's native serializer)
    request_json = JSON3.write(chat_request)

    # ── Step 3: Send via P2P ──
    result = PeerCompute.send_inference_request(target_peer, model, request_json)

    if result.status == "error"
        error("P2P inference failed: $(result.message)")
    end

    # ── Step 4: Parse response using wrapped provider's types ──
    # The remote peer wraps the ChatResponse in a PeerComputeInferenceResponse
    # (see _handle_inference_request). We unwrap it here with StructTypes.
    pc_response = JSON3.read(result.message, PeerComputeInferenceResponse)

    msg = pc_response.message
    return PeerComputeResponse(msg, model, target_peer)
end

function FlootyAbstract.chat_stream(provider::PeerComputeProvider, model::String, messages::Vector{<:AbstractMessage},
    stream::Bool, format, options, tools)
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
# Tool Support
# ═══════════════════════════════════════════════════════════════════════

"""
    FlootyAbstract.build_tool(tool::AbstractTool, provider::PeerComputeProvider)

Delegate to the wrapped provider's build_tool, then extract its JSON schema
into the Dict{String,Any} form that PeerCompute forwards over the wire.
"""
function FlootyAbstract.build_tool(tool::AbstractTool, provider::PeerComputeProvider)
    _require_wrapped(provider)
    # Delegate directly to the wrapped provider (e.g. Ollama).
    # The wrapped provider returns its native tool type (e.g. OllamaTool),
    # which is serialized via JSON3.write(ChatRequest) for P2P transport.
    return FlootyAbstract.build_tool(tool, provider.wrapped)
end

# ═══════════════════════════════════════════════════════════════════════
# Tool Building / Embedder
# ═══════════════════════════════════════════════════════════════════════

FlootyAbstract.create_embedder(provider::PeerComputeProvider, model::String; kwargs...) =
    error("PeerCompute does not support embeddings")

# ═══════════════════════════════════════════════════════════════════════
# HTTP Inference Endpoint — called by Go inferenceStreamHandler
# ═══════════════════════════════════════════════════════════════════════

const _inference_server = Ref{Any}(nothing)

function start_inference_server(port::Int)
    if _inference_server[] !== nothing
        return  # already running
    end

    # Check if port is available first
    # Note: Windows uses different error messages (e.g. WSAEADDRINUSE) vs POSIX (EADDRINUSE)
    try
        test_sock = Sockets.listen(Sockets.IPv4(127,0,0,1), port)
        close(test_sock)
    catch e
        if e isa Base.IOError
            err_str = string(e)
            if occursin("EADDRINUSE", err_str) || occursin("WSAEADDRINUSE", err_str) || occursin("address already in use", err_str) || occursin("address in use", err_str)
                @warn "Inference port $port in use, skipping (another instance is handling it)"
                return
            end
        end
        # Re-throw if it's not an address-in-use error
        rethrow()
    end

    # Use listen! (non-blocking) so we can store the server and close it later
    server = try
        HTTP.listen!("127.0.0.1", port; reuseaddr=true) do http::HTTP.Stream
            req = http.message
            if req.method == "POST" && req.target == "/inference"
                _handle_inference_request(http)
            else
                HTTP.setstatus(http, 404)
                HTTP.startwrite(http)
                write(http, "Not found")
            end
        end
    catch e
        @warn "Failed to start inference HTTP server on port $port: $e"
        return
    end

    _inference_server[] = server
    @info "Inference HTTP server started on port $port"
    sleep(0.5)  # give it a moment to start
end


function _handle_inference_request(http::HTTP.Stream)
    try
        body = String(read(http))

        # Proxy the raw ChatRequest JSON directly to Ollama's /api/chat endpoint.
        # This is a pass-through — no type conversion needed. The wrapped provider's
        # chat() function would do the same: JSON3.write(ChatRequest) → HTTP POST.
        # We skip the struct round-trip entirely.
        provider = GLOBAL_PROVIDER[]
        base_url = if provider !== nothing && provider.wrapped !== nothing
            getfield(provider.wrapped, :baseURL)
        else
            "http://localhost:11434"
        end
        ollama_url = string(base_url, "/api/chat")

        response = HTTP.post(ollama_url, ["Content-Type" => "application/json"], body; timeout=120)

        if response.status != 200
            HTTP.setstatus(http, 500)
            HTTP.startwrite(http)
            write(http, JSON3.write(Dict("status" => "error", "message" => "Ollama returned $(response.status): $(String(response.body))")))
            return
        end

        # Parse the Ollama ChatResponse and wrap it in a PeerComputeInferenceResponse
        # so the receiving create_stream can unwrap it with StructTypes instead of
        # trying to deserialize the raw ChatResponse JSON (which can fail due to
        # field type mismatches).
        chat_response = JSON3.read(String(response.body), ChatResponse)
        pc_response = PeerComputeInferenceResponse(
            "success",
            response_message(chat_response),
            chat_response.model
        )

        HTTP.setstatus(http, 200)
        HTTP.setheader(http, "Content-Type" => "application/json")
        HTTP.startwrite(http)
        write(http, JSON3.write(pc_response))

    catch e
        @error "Inference request failed" error=e
        HTTP.setstatus(http, 500)
        HTTP.startwrite(http)
        write(http, JSON3.write(Dict("status" => "error", "message" => string(e))))
    end
end

function stop_inference_server()
    server = _inference_server[]
    if server !== nothing
        try
            close(server)
        catch e
            @warn "Error closing inference server" error=e
        end
        _inference_server[] = nothing
        @info "Inference HTTP server stopped"
    end
end
