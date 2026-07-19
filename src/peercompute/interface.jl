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

FlootyAbstract.role(msg::PeerComputeMessage) = msg.role
FlootyAbstract.content(msg::PeerComputeMessage) = msg.content

FlootyAbstract.create_message(provider::PeerComputeProvider, role::String, content::String; tool_name::Union{String,Nothing}=nothing) =
    PeerComputeMessage(role=role, content=content)

FlootyAbstract.create_message(provider::PeerComputeProvider, role::String, content::String, images::Vector{<:AbstractProviderObject}) =
    error("PeerCompute does not support image attachments")

FlootyAbstract.create_message(provider::PeerComputeProvider, role::String, content::String, attachments::Vector{<:AbstractAttachment}) =
    error("PeerCompute does not support attachments")

FlootyAbstract.tool_calls(msg::PeerComputeMessage) = msg.tool_calls

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
    
    # If a provider exists but isn't running, update its config
    if existing !== nothing
        existing.bootstrap_peers = bootstrap_peers
        existing.service_topic = get(config, :service_topic, "peercompute-nodes-v1")
        existing.p2p_port = p2p_port
        existing.api_port = api_port
        existing.bootstrap_node = bootstrap_node
        return existing
    end
    
    provider = PeerComputeProvider(
        bootstrap_peers=bootstrap_peers,
        service_topic=get(config, :service_topic, "peercompute-nodes-v1"),
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
  Writes bootstrap info to `~/.flooty/bootstrap_info.json` for local discovery.
- If `bootstrap_peers` is already set (from config or local discovery),
  starts a peer node that connects to them.
- If neither, tries local discovery first, then starts standalone.
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

        settings = PeerCompute.PeerComputeSettings(
            p2p_port=provider.p2p_port,
            api_port=provider.api_port,
            service_topic=provider.service_topic,
            enable_mdns=enable_mdns,
            enable_nat=enable_nat,
            static_key_file=peer_key,
            bootstrap_peers=provider.bootstrap_peers
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
        
        # Debug: check peer discovery
        sleep(2)
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

"""
    stop_provider(provider::PeerComputeProvider)

Stop the PeerCompute P2P node. Cleans up the bootstrap info file.
"""
function stop_provider(provider::PeerComputeProvider)
    if !provider.node_running
        @warn "PeerCompute node is not running"
        return
    end
    
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
    verified = try PeerCompute.get_verified_peers_by_topic("peercompute-nodes-v1"); catch; String[]; end
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
    
    # Select peer: prefer one that has the model, skip ourselves
    target_peer = nothing
    
    # First pass: find a verified remote peer that has the model
    for peer_id in verified_peers
        peer_id == our_id && continue  # never connect to ourselves
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
    
    @info "Forwarding inference to peer" peer=target_peer[1:min(20, length(target_peer))] * "..." model=model has_tools=(tools !== nothing && !isempty(tools))
    
    # ── Step 2: Build Ollama-compatible request ──
    # Convert messages to Ollama format
    ollama_messages = [
        Dict("role" => FlootyAbstract.role(m), "content" => something(FlootyAbstract.content(m), ""))
        for m in messages if FlootyAbstract.content(m) !== nothing
    ]
    
    # Build request
    request = Dict{String,Any}(
        "model" => model,
        "messages" => ollama_messages,
        "stream" => stream
    )
    
    # Add tools if provided
    if tools !== nothing && !isempty(tools)
        ollama_tools = [FlootyAbstract.build_tool(t, provider).function_ for t in tools]
        request["tools"] = ollama_tools
    end
    
    # Add options if provided
    if options !== nothing
        request["options"] = options
    end
    
    # Add format if provided
    if format !== nothing
        request["format"] = format
    end
    
    # ── Step 3: Send via P2P ──
    # Serialize to JSON
    request_json = JSON.json(request)
    
    # Send via P2P remote peer's Ollama API
    # Pass the actual model name, not "ollama"
    result = PeerCompute.send_inference_request(target_peer, model, request_json)
    
    if result.status == "error"
        error("P2P inference failed: $(result.response)")
    end
    
    # Parse Ollama response
    response = try
        JSON.parse(result.response)
    catch
        Dict("message" => Dict("content" => result.response))
    end
    
    message = get(response, "message", Dict())
    content = get(message, "content", "")
    
    # Parse tool calls from Ollama response
    tool_calls = nothing
    if haskey(message, "tool_calls")
        raw_calls = message["tool_calls"]
        if isa(raw_calls, Vector) && !isempty(raw_calls)
            calls = PeerComputeToolCall[]
            for tc in raw_calls
                push!(calls, PeerComputeToolCall(tc))
            end
            tool_calls = calls
        end
    end
    
    msg = PeerComputeMessage(role="assistant", content=content, tool_calls=tool_calls)
    return PeerComputeResponse(msg, model, target_peer, 0, result.status == "success")
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
    FlootyAbstract.build_tool(tool::AbstractTool, provider::PeerComputeProvider) -> PeerComputeTool

Convert an AbstractTool to Ollama-compatible PeerComputeTool format.
"""
function FlootyAbstract.build_tool(tool::AbstractTool, provider::PeerComputeProvider)
    # Convert parameters to Ollama format
    params = FlootyAbstract.tool_parameters(tool)
    
    # Build parameters schema
    properties = Dict{String,Any}()
    required = String[]
    
    if params isa Dict && haskey(params, "properties")
        # Already in schema format
        for (k, v) in params["properties"]
            properties[k] = v
        end
        if haskey(params, "required")
            required = params["required"]
        end
    elseif params isa Vector
        # Convert from simple vector
        for p in params
            if p isa String
                properties[p] = Dict("type" => "string", "description" => "")
            elseif p isa Dict
                name = get(p, "name", "param")
                properties[name] = Dict(
                    "type" => get(p, "type", "string"),
                    "description" => get(p, "description", "")
                )
                if get(p, "required", false)
                    push!(required, name)
                end
            end
        end
    end
    
    function_def = Dict(
        "name" => FlootyAbstract.tool_name(tool),
        "description" => FlootyAbstract.tool_description(tool),
        "parameters" => Dict(
            "type" => "object",
            "properties" => properties,
            "required" => required
        )
    )
    
    return PeerComputeTool("function", function_def)
end

# ═══════════════════════════════════════════════════════════════════════
# Tool Building / Embedder
# ═══════════════════════════════════════════════════════════════════════

FlootyAbstract.create_embedder(provider::PeerComputeProvider, model::String; kwargs...) =
    error("PeerCompute does not support embeddings")
