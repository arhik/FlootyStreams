"""
    barelibp2p/interface.jl

High-level interface for BareLibP2P provider, mirroring PeerCompute API.
"""

using Sockets
using JSON
using Dates

using BareLibP2P
using BareLibP2P.DHT
using BareLibP2P.GossipSub
using BareLibP2P.Identity

using FlootyAbstract

# ═══════════════════════════════════════════════════════════════════════
# Provider Lifecycle
# ═══════════════════════════════════════════════════════════════════════

"""
    start_provider(provider::BareLibP2PProvider) -> Bool

Start the BareLibP2P P2P node with DHT and GossipSub.
"""
function start_provider(provider::BareLibP2PProvider)
    provider.node_running && return true  # Already running
    
    try
        # Generate identity
        priv, pub = generate_keypair()
        provider.identity = priv
        provider.peer_id = peer_id_from_public_key(pub).id
        @info "BareLibP2P identity created: $(provider.peer_id[1:20])..."
        
        # Set up local addresses
        push!(provider.local_addrs, BareLibP2P.MultiaddrStruct("/ip4/0.0.0.0/tcp/$(provider.p2p_port)"))
        
        # Create DHT
        dht_config = DHTConfig(
            protocol_prefix="/peercompute/kad/1.0.0",
            bucket_size=20,
            alpha=3
        )
        provider.dht = new_dht(dht_config, provider.peer_id, provider.local_addrs)
        @info "BareLibP2P DHT created on port $(provider.p2p_port)"
        
        # Create GossipSub
        gossip_config = GossipSubConfig(
            protocol_prefix="/meshsub/1.1.0",
            D=6, D_low=5, D_high=12,
            heartbeat_interval=1.0
        )
        provider.gossip = new_gossipsub(gossip_config, provider.peer_id, provider.local_addrs)
        @info "BareLibP2P GossipSub created"
        
        # Subscribe to service topic
        if provider.gossip !== nothing
            subscribe(provider.gossip, provider.service_topic)
            @info "Subscribed to topic: $(provider.service_topic)"
        end
        
        # Bootstrap if peers provided
        if !isempty(provider.bootstrap_peers)
            bootstrap_peers = parse_bootstrap_peers(provider.bootstrap_peers)
            if !isempty(bootstrap_peers) && provider.dht !== nothing
                bootstrap(provider.dht, bootstrap_peers)
                @info "Bootstrapped with $(length(bootstrap_peers)) peers"
            end
        end
        
        # Store as global
        GLOBAL_BARELIBP2P_PROVIDER[] = provider
        provider.node_running = true
        
        # Start announcement loop
        @async announcement_loop(provider)
        
        @info "BareLibP2P provider started successfully"
        return true
        
    catch e
        @error "Failed to start BareLibP2P provider" exception=e
        provider.node_running = false
        return false
    end
end

"""
    stop_provider(provider::BareLibP2PProvider) -> Bool

Stop the BareLibP2P P2P node.
"""
function FlootyStreams.stop_provider(provider::BareLibP2PProvider)
    !provider.node_running && return true
    
    provider.node_running = false
    provider.dht = nothing
    provider.gossip = nothing
    provider.identity = nothing
    GLOBAL_BARELIBP2P_PROVIDER[] = nothing
    
    @info "BareLibP2P provider stopped"
    return true
end

# ═══════════════════════════════════════════════════════════════════════
# Announcement Loop
# ═══════════════════════════════════════════════════════════════════════

function announcement_loop(provider::BareLibP2PProvider)
    while provider.node_running
        try
            sleep(30)  # Announce every 30 seconds
            provider.node_running || break
            
            # Announce service
            if provider.gossip !== nothing && !isempty(provider.announced_models)
                announcement = Dict(
                    "node_id" => provider.peer_id,
                    "models" => provider.announced_models,
                    "timestamp" => time(),
                    "p2p_port" => provider.p2p_port,
                    "api_port" => provider.api_port
                )
                publish(provider.gossip, provider.service_topic, JSON.json(announcement))
            end
        catch e
            @warn "Announcement loop error" exception=e
        end
    end
end

# ═══════════════════════════════════════════════════════════════════════
# Peer Discovery
# ═══════════════════════════════════════════════════════════════════════

"""
    discover_peers(provider::BareLibP2PProvider) -> Vector{BareLibP2PPeerInfo}

Discover peers from GossipSub messages.
"""
function discover_peers(provider::BareLibP2PProvider)
    provider.gossip === nothing && return BareLibP2PPeerInfo[]
    
    messages = GossipSub.get_messages(provider.gossip, provider.service_topic)
    peers = BareLibP2PPeerInfo[]
    
    for msg in messages
        try
            data = JSON.parse(msg)
            peer_id = get(data, "node_id", "")
            models = get(data, "models", String[])
            timestamp = get(data, "timestamp", 0.0)
            
            # Create peer info
            addrs = [BareLibP2P.MultiaddrStruct("/ip4/127.0.0.1/tcp/4001")]  # Would be parsed from data
            push!(peers, BareLibP2PPeerInfo(peer_id, addrs, models, timestamp))
        catch
            # Skip invalid messages
        end
    end
    
    return peers
end

"""
    get_peers(provider::BareLibP2PProvider) -> Vector{String}

Get list of discovered peer IDs.
"""
function get_peers(provider::BareLibP2PProvider)
    peers = discover_peers(provider)
    return [p.peer_id for p in peers]
end

"""
    get_peer_info(provider::BareLibP2PProvider, peer_id::String) -> Union{BareLibP2PPeerInfo, Nothing}

Get information about a specific peer.
"""
function get_peer_info(provider::BareLibP2PProvider, peer_id::String)
    peers = discover_peers(provider)
    for peer in peers
        if peer.peer_id == peer_id
            return peer
        end
    end
    return nothing
end

# ═══════════════════════════════════════════════════════════════════════
# Model Operations
# ═══════════════════════════════════════════════════════════════════════

"""
    register_models(provider::BareLibP2PProvider, models::Vector{String})

Register models for announcement.
"""
function register_models(provider::BareLibP2PProvider, models::Vector{String})
    provider.announced_models = models
    
    # Store in DHT
    if provider.dht !== nothing
        for model in models
            key = "model:$model:providers"
            value = Vector{UInt8}(provider.peer_id)
            put_value(provider.dht, key, value)
            provide(provider.dht, key)
        end
    end
    
    # Immediate announcement
    if provider.gossip !== nothing
        announcement = Dict(
            "node_id" => provider.peer_id,
            "models" => models,
            "timestamp" => time(),
            "p2p_port" => provider.p2p_port,
            "api_port" => provider.api_port
        )
        publish(provider.gossip, provider.service_topic, JSON.json(announcement))
    end
    
    @info "Registered models: $(join(models, ", "))"
end

"""
    get_registered_models(provider::BareLibP2PProvider) -> Vector{String}

Get list of registered models.
"""
function get_registered_models(provider::BareLibP2PProvider)
    return provider.announced_models
end

"""
    find_providers_for_model(provider::BareLibP2PProvider, model::String) -> Vector{String}

Find peers that provide a specific model.
"""
function find_providers_for_model(provider::BareLibP2PProvider, model::String)
    if provider.dht === nothing
        return String[]
    end
    
    key = "model:$model:providers"
    providers = find_providers(provider.dht, key)
    return [p.id for p in providers]
end

# ═══════════════════════════════════════════════════════════════════════
# Inference
# ═══════════════════════════════════════════════════════════════════════

"""
    inference_request(provider::BareLibP2PProvider, peer_id::String, model::String, prompt::String) -> BareLibP2PResponse

Send inference request to a peer.
"""
function inference_request(provider::BareLibP2PProvider, peer_id::String, model::String, prompt::String)
    start_time = time()
    
    try
        # Get peer info from DHT
        if provider.dht === nothing
            return BareLibP2PResponse(
                BareLibP2PMessage(role="assistant", content="DHT not available"),
                model, peer_id, Int((time() - start_time) * 1000), false
            )
        end
        
        peer_info = find_peer(provider.dht, peer_id)
        if peer_info === nothing
            # Try from gossip
            gossip_peer = get_peer_info(provider, peer_id)
            if gossip_peer === nothing
                return BareLibP2PResponse(
                    BareLibP2PMessage(role="assistant", content="Peer not found: $peer_id"),
                    model, peer_id, Int((time() - start_time) * 1000), false
                )
            end
            # Use gossip peer info
            host, port = BareLibP2P.Multiaddr.get_host_port(gossip_peer.addrs[1])
        else
            # Use DHT peer info
            host, port = BareLibP2P.Multiaddr.get_host_port(peer_info.addrs[1])
        end
        
        # Connect via TCP
        socket = connect(host, port)
        
        # Send request
        request = Dict("action" => "inference", "model" => model, "prompt" => prompt)
        write(socket, JSON.json(request) * "\n")
        
        # Read response
        response_line = readline(socket)
        close(socket)
        
        response_data = JSON.parse(response_line)
        latency_ms = Int((time() - start_time) * 1000)
        
        if get(response_data, "status", "error") == "success"
            content = get(response_data, "response", "")
            return BareLibP2PResponse(
                BareLibP2PMessage(role="assistant", content=content),
                model, peer_id, latency_ms, true
            )
        else
            error_msg = get(response_data, "response", "Unknown error")
            return BareLibP2PResponse(
                BareLibP2PMessage(role="assistant", content="Error: $error_msg"),
                model, peer_id, latency_ms, false
            )
        end
        
    catch e
        latency_ms = Int((time() - start_time) * 1000)
        return BareLibP2PResponse(
            BareLibP2PMessage(role="assistant", content="Error: $(string(e))"),
            model, peer_id, latency_ms, false
        )
    end
end

"""
    inference_stream(provider::BareLibP2PProvider, peer_id::String, model::String, prompt::String)

Send streaming inference request (returns an iterator).
"""
function inference_stream(provider::BareLibP2PProvider, peer_id::String, model::String, prompt::String)
    # For now, just call regular inference and wrap in iterator
    response = inference_request(provider, peer_id, model, prompt)
    return [response.message]
end

# ═══════════════════════════════════════════════════════════════════════
# Provider Chat Interface
# ═══════════════════════════════════════════════════════════════════════

function FlootyAbstract.chat(
    provider::BareLibP2PProvider,
    agent::AbstractAgent,
    messages::Vector{<:AbstractMessage};
    tools::Vector{<:AbstractTool}=AbstractTool[],
    stream::Bool=false
)
    # Ensure provider is running
    if !provider.node_running
        start_provider(provider)
    end
    
    # Find peers
    peers = discover_peers(provider)
    isempty(peers) && return BareLibP2PResponse(
        BareLibP2PMessage(role="assistant", content="No peers available"),
        nothing, nothing, 0, false
    )
    
    # Use first available peer
    target_peer = peers[1].peer_id
    model = "llama2"  # Would be selected based on availability
    
    # Convert messages to Ollama format
    ollama_messages = [
        Dict("role" => FlootyAbstract.role(m), "content" => something(FlootyAbstract.content(m), ""))
        for m in messages if FlootyAbstract.content(m) !== nothing
    ]
    
    # Build tools for Ollama
    ollama_tools = if !isempty(tools)
        [build_tool_for_ollama(t) for t in tools]
    else
        nothing
    end
    
    # Use protocol to send request
    response = chat_with_tools_p2p(
        provider, target_peer, model, ollama_messages;
        tools=ollama_tools
    )
    
    if response.error !== nothing
        return BareLibP2PResponse(
            BareLibP2PMessage(role="assistant", content="Error: $(response.error)"),
            model, target_peer, 0, false
        )
    end
    
    # Check for tool calls in response
    msg = response.message
    content = get(msg, "content", "")
    tool_calls = get(msg, "tool_calls", nothing)
    
    if tool_calls !== nothing && !isempty(tool_calls)
        # Execute tools locally
        tool_results = execute_tools_locally(tool_calls, tools)
        
        # Send results back for final response
        final_response = send_tool_results_p2p(
            provider, target_peer, model, ollama_messages, tool_results
        )
        
        final_msg = final_response.message
        content = get(final_msg, "content", "")
    end
    
    return BareLibP2PResponse(
        BareLibP2PMessage(role="assistant", content=content),
        model, target_peer, 0, true
    )
end

"""
    build_tool_for_ollama(tool::AbstractTool) -> Dict

Convert AbstractTool to Ollama tool format.
"""
function build_tool_for_ollama(tool::AbstractTool)
    params = FlootyAbstract.tool_parameters(tool)
    
    # Build parameters schema
    properties = Dict{String,Any}()
    required = String[]
    
    if params isa Dict && haskey(params, "properties")
        for (k, v) in params["properties"]
            properties[k] = v
        end
        if haskey(params, "required")
            required = params["required"]
        end
    elseif params isa Vector
        for p in params
            if p isa String
                properties[p] = Dict("type" => "string", "description" => "")
            elseif p isa Dict
                name = get(p, "name", "param")
                properties[name] = Dict(
                    "type" => get(p, "type", "string"),
                    "description" => get(p, "description", "")
                )
            end
        end
    end
    
    return Dict(
        "type" => "function",
        "function" => Dict(
            "name" => FlootyAbstract.tool_name(tool),
            "description" => FlootyAbstract.tool_description(tool),
            "parameters" => Dict(
                "type" => "object",
                "properties" => properties,
                "required" => required
            )
        )
    )
end

"""
    execute_tools_locally(tool_calls::Vector{Dict}, tools::Vector{<:AbstractTool}) -> Vector{Dict}

Execute tool calls locally and return results.
"""
function execute_tools_locally(tool_calls::Vector{Dict}, tools::Vector{<:AbstractTool})
    results = Dict{String,Any}[]
    
    # Build tool map
    tool_map = Dict{String,AbstractTool}()
    for t in tools
        tool_map[FlootyAbstract.tool_name(t)] = t
    end
    
    for tc in tool_calls
        func = get(tc, "function", Dict())
        name = get(func, "name", "")
        arguments = get(func, "arguments", Dict())
        
        tool = get(tool_map, name, nothing)
        if tool !== nothing
            try
                result = FlootyAbstract.execute_tool(tool, arguments)
                push!(results, Dict(
                    "name" => name,
                    "content" => string(result)
                ))
            catch e
                push!(results, Dict(
                    "name" => name,
                    "content" => "Error: $(string(e))"
                ))
            end
        else
            push!(results, Dict(
                "name" => name,
                "content" => "Error: Tool '$name' not found"
            ))
        end
    end
    
    return results
end

function chat_stream(
    provider::BareLibP2PProvider,
    agent::AbstractAgent,
    messages::Vector{<:AbstractMessage};
    tools::Vector{<:AbstractTool}=AbstractTool[]
)
    return FlootyAbstract.chat(provider, agent, messages; tools=tools, stream=true)
end

# ═══════════════════════════════════════════════════════════════════════
# Utilities
# ═══════════════════════════════════════════════════════════════════════

function parse_bootstrap_peers(addr_strings::Vector{String})
    peers = PeerInfo[]
    for addr_str in addr_strings
        try
            ma = BareLibP2P.MultiaddrStruct(addr_str)
            protocols = BareLibP2P.get_protocols(ma)
            
            # Extract host and port
            host, port = "", 0
            for (proto, val) in protocols
                if proto in ["ip4", "ip6", "dns"]
                    host = val
                elseif proto in ["tcp", "udp"]
                    port = val
                end
            end
            
            if host != "" && port != 0
                peer_id = "bootstrap-$host-$port"
                peer_addrs = [BareLibP2P.MultiaddrStruct("/ip4/$host/tcp/$port")]
                push!(peers, PeerInfo(peer_id, peer_addrs, time()))
            end
        catch e
            @warn "Failed to parse bootstrap address: $addr_str" exception=e
        end
    end
    return peers
end

"""
    ensure_node_running!(provider::BareLibP2PProvider) -> Bool

Ensure the provider is running, starting it if necessary.
"""
function ensure_node_running!(provider::BareLibP2PProvider)
    if !provider.node_running
        return start_provider(provider)
    end
    return true
end

"""
    select_peer_for_model(provider::BareLibP2PProvider, model::String) -> Union{String, Nothing}

Select the best peer for a given model based on availability.
"""
function select_peer_for_model(provider::BareLibP2PProvider, model::String)
    providers = find_providers_for_model(provider, model)
    isempty(providers) && return nothing
    return providers[1]  # Could implement better selection logic
end

# ═══════════════════════════════════════════════════════════════════════
# FlootyAbstract Integration - Provider Registration
# ═══════════════════════════════════════════════════════════════════════

"""
    FlootyAbstract.create_provider_instance(::Val{:barelibp2p}; config::Dict{Symbol,Any}) -> BareLibP2PProvider

Create a BareLibP2P provider instance for FlootyAbstract integration.

Usage:
    provider = create_provider_instance(:barelibp2p; config=Dict(:bootstrap_node => true))
"""
function FlootyAbstract.create_provider_instance(::Val{:barelibp2p}; config::Dict{Symbol, Any} = Dict{Symbol, Any}())
    # Check for existing global provider
    existing = GLOBAL_BARELIBP2P_PROVIDER[]
    if existing !== nothing && existing.node_running
        return existing
    end
    
    # Resolve config
    bootstrap_node = get(config, :bootstrap_node, false)
    p2p_port = get(config, :p2p_port, get(ENV, "BARELIBP2P_PORT", "4001"))
    api_port = get(config, :api_port, get(ENV, "BARELIBP2P_API_PORT", "5001"))
    
    # Parse bootstrap peers from config or ENV
    bootstrap_peers = String[]
    if haskey(config, :bootstrap_peers)
        bootstrap_peers = config[:bootstrap_peers]
    elseif haskey(ENV, "BARELIBP2P_BOOTSTRAP_PEERS")
        bootstrap_peers = split(ENV["BARELIBP2P_BOOTSTRAP_PEERS"], ",")
    end
    
    service_topic = get(config, :service_topic, "peercompute-nodes-v1")
    
    # Create and return provider (caller's responsibility to start)
    provider = BareLibP2PProvider(
        p2p_port = parse(Int, string(p2p_port)),
        api_port = parse(Int, string(api_port)),
        service_topic = service_topic,
        bootstrap_peers = bootstrap_peers,
        bootstrap_node = bootstrap_node
    )
    
    GLOBAL_BARELIBP2P_PROVIDER[] = provider
    return provider
end

"""
    list_provider_models(provider::BareLibP2PProvider) -> Vector{BareLibP2PModel}

List models available through BareLibP2P provider.
"""
function FlootyAbstract.list_provider_models(provider::BareLibP2PProvider)
    models = BareLibP2PModel[]
    
    # Add own models
    for model_name in provider.announced_models
        push!(models, BareLibP2PModel(
            name = model_name,
            peer_id = provider.peer_id,
            reputation = 1.0,
            latency_ms = 0
        ))
    end
    
    # Discover peers and their models
    peers = discover_peers(provider)
    for peer in peers
        for model_name in peer.models
            push!(models, BareLibP2PModel(
                name = model_name,
                peer_id = peer.peer_id,
                reputation = 1.0,
                latency_ms = 0
            ))
        end
    end
    
    return models
end
