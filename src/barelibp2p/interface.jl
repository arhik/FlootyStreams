"""
    barelibp2p/interface.jl

BareLibP2P routes chat calls via P2P.
Server uses local_provider for execution.
Client discovers models via gossip and routes to peers.
"""

using JSON3
using Sockets
using BareLibP2P

# ═══════════════════════════════════════════════════════════════════════
# Provider Lifecycle
# ═══════════════════════════════════════════════════════════════════════

function FlootyStreams.start_provider(p::BareLibP2PProvider)
    p.node_running && return true
    
    priv, pub = BareLibP2P.Identity.generate_keypair()
    p.identity = priv
    p.peer_id = BareLibP2P.Identity.peer_id_from_public_key(pub).id
    
    push!(p.local_addrs, BareLibP2P.MultiaddrStruct("/ip4/0.0.0.0/tcp/$(p.p2p_port)"))
    
    dht_config = BareLibP2P.DHT.DHTConfig(bucket_size=20, alpha=3)
    p.dht = BareLibP2P.DHT.new_dht(dht_config, p.peer_id, p.local_addrs)
    
    gossip_config = BareLibP2P.GossipSub.GossipSubConfig(
        protocol_prefix="/meshsub/1.1.0", D=6, D_low=5, D_high=12, heartbeat_interval=1.0
    )
    p.gossip = BareLibP2P.GossipSub.new_gossipsub(gossip_config, p.peer_id, p.local_addrs)
    
    p.gossip !== nothing && BareLibP2P.GossipSub.subscribe(p.gossip, p.service_topic)
    
    GLOBAL_BARELIBP2P_PROVIDER[] = p
    p.node_running = true
    
    # Server mode: announce local models immediately and periodically
    @async begin
        if p.local_provider !== nothing
            announce_local_models(p)
        end
        announcement_loop(p)
    end
    
    @info "[BareLibP2P] Started" peer_id=p.peer_id[1:16] server_mode=(p.local_provider!==nothing)
    return true
end

function FlootyStreams.stop_provider(p::BareLibP2PProvider)
    p.node_running = false
    p.dht = nothing
    p.gossip = nothing
    GLOBAL_BARELIBP2P_PROVIDER[] = nothing
    true
end

# ═══════════════════════════════════════════════════════════════════════
# Chat - CLIENT MODE: Route via P2P
# ═══════════════════════════════════════════════════════════════════════

function FlootyAbstract.chat(
    p::BareLibP2PProvider,
    agent::FlootyAbstract.AbstractAgent,
    messages::Vector{<:FlootyAbstract.AbstractMessage};
    tools::Vector{<:FlootyAbstract.AbstractTool}=FlootyAbstract.AbstractTool[],
    stream::Bool=false
)
    !p.node_running && FlootyStreams.start_provider(p)
    
    model = agent.model
    @info "[BareLibP2P] chat" model=model
    
    # Discover peers and find one with this model
    peers = discover_peers(p)
    isempty(peers) && return _error("No P2P peers available")
    
    peer = find_peer_with_model(peers, model)
    peer === nothing && return _error("No peer found for model: $model")
    
    # Get original provider type from peer's announcement
    orig_provider = get(peer.models, model, "ollama")
    @info "[BareLibP2P] Routing" peer=peer.peer_id[1:16] provider=orig_provider
    
    req = BareLibP2PChatRequest(
        original_provider = orig_provider,
        model = model,
        messages = messages,
        tools = tools,
        stream = stream
    )
    
    return send_p2p_request(p, peer, req)
end

function FlootyAbstract.chat_stream(
    p::BareLibP2PProvider,
    model::String,
    messages::Vector{<:FlootyAbstract.AbstractMessage},
    stream::Bool=false,
    format=nothing,
    options=nothing,
    tools=nothing
)
    !p.node_running && FlootyStreams.start_provider(p)
    
    peers = discover_peers(p)
    isempty(peers) && return _error("No P2P peers available")
    
    peer = find_peer_with_model(peers, model)
    peer === nothing && return _error("No peer for model: $model")
    
    orig_provider = get(peer.models, model, "ollama")
    
    req = BareLibP2PChatRequest(
        original_provider = orig_provider,
        model = model,
        messages = messages,
        tools = tools === nothing ? FlootyAbstract.AbstractTool[] : tools,
        stream = stream
    )
    
    response = send_p2p_request(p, peer, req)
    
    stream ? Channel(Inf) do ch; put!(ch, response); put!(ch, nothing); end : response
end

# ═══════════════════════════════════════════════════════════════════════
# P2P Transport
# ═══════════════════════════════════════════════════════════════════════

function send_p2p_request(p::BareLibP2PProvider, peer::BareLibP2PPeerInfo, req::BareLibP2PChatRequest)
    host, port = _get_peer_addr(peer)
    
    socket = connect(host, port)
    try
        JSON3.write(socket, req)
        write(socket, "\n")
        
        resp = JSON3.read(readline(socket), BareLibP2PChatResponse)
        
        !resp.success && return _error(resp.error === nothing ? "Unknown peer error" : resp.error)
        
        # Deserialize based on original provider type
        if req.original_provider == "ollama"
            return JSON3.read(resp.response_json, ChatResponse)
        elseif req.original_provider == "openai"
            return JSON3.read(resp.response_json, OpenAIResponse)
        else
            return JSON3.read(resp.response_json)
        end
    catch e
        return _error("P2P failed: $e")
    finally
        close(socket)
    end
end

function _get_peer_addr(peer::BareLibP2PPeerInfo)
    isempty(peer.addrs) && return ("localhost", 11435)
    parts = split(peer.addrs[1].addr, "/")
    ip = length(parts) >= 3 ? parts[3] : "localhost"
    port = length(parts) >= 5 ? parse(Int, parts[5]) : 11435
    (ip, port)
end

_error(msg::String) = ChatResponse(
    OllamaMessage(role="assistant", content="Error: $msg"),
    nothing, nothing, true, nothing, nothing, nothing, nothing
)

# ═══════════════════════════════════════════════════════════════════════
# Remote Server - Receives P2P requests, executes via local_provider
# ═══════════════════════════════════════════════════════════════════════

function start_remote_server(port::Int=11435)
    server = listen(port)
    @info "[BareLibP2P] Server listening" port=port
    
    @async while true
        try
            client = accept(server)
            @async handle_remote_client(client)
        catch e
            @error "[BareLibP2P] Accept failed" exception=e
        end
    end
    
    server
end

function handle_remote_client(client::Sockets.TCPSocket)
    try
        req = JSON3.read(readline(client), BareLibP2PChatRequest)
        resp = process_remote_request(req)
        JSON3.write(client, resp)
        write(client, "\n")
    catch e
        JSON3.write(client, BareLibP2PChatResponse(success=false, error=string(e), response_json=""))
        write(client, "\n")
    finally
        close(client)
    end
end

function process_remote_request(req::BareLibP2PChatRequest)
    # Create actual provider instance based on original_provider type
    provider = FlootyAbstract.create_provider_instance(Symbol(req.original_provider))
    
    # Create agent
    agent = FlootyAbstract.create_agent("Remote", req.original_provider)
    agent.model = req.model
    
    # Execute chat with actual provider
    result = FlootyAbstract.chat(provider, agent, req.messages; tools=req.tools, stream=req.stream)
    
    # Serialize response back to JSON
    response_json = JSON3.write(result)
    
    BareLibP2PChatResponse(success=true, response_json=response_json, error=nothing)
end

# ═══════════════════════════════════════════════════════════════════════
# Peer Discovery
# ═══════════════════════════════════════════════════════════════════════

function discover_peers(p::BareLibP2PProvider)
    peers = BareLibP2PPeerInfo[]
    
    if p.gossip !== nothing
        for msg in BareLibP2P.GossipSub.get_messages(p.gossip, p.service_topic)
            try
                data = JSON3.read(msg.data)
                push!(peers, BareLibP2PPeerInfo(
                    data["peer_id"],
                    [BareLibP2P.MultiaddrStruct(a) for a in get(data, "addrs", String[])],
                    Dict{String,String}(get(data, "models", Dict{String,String}())),
                    time()
                ))
            catch
            end
        end
    end
    
    @debug "[BareLibP2P] Discovered peers" count=length(peers)
    peers
end

function find_peer_with_model(peers::Vector{BareLibP2PPeerInfo}, model::String)
    for peer in peers
        if haskey(peer.models, model)
            return peer
        end
    end
    nothing
end

# ═══════════════════════════════════════════════════════════════════════
# Model Announcement - SERVER MODE only
# ═══════════════════════════════════════════════════════════════════════

function announcement_loop(p::BareLibP2PProvider)
    while p.node_running
        try
            if p.gossip !== nothing && p.local_provider !== nothing
                # Get current models from local provider
                models = _get_local_models(p)
                
                if !isempty(models)
                    announcement = Dict(
                        "peer_id" => p.peer_id,
                        "addrs" => [a.addr for a in p.local_addrs],
                        "models" => models
                    )
                    BareLibP2P.GossipSub.publish(p.gossip, p.service_topic, JSON3.write(announcement))
                    @debug "[BareLibP2P] Announced" count=length(models)
                end
            end
        catch e
            @debug "[BareLibP2P] Announce error" error=e
        end
        sleep(30)
    end
end

function announce_local_models(p::BareLibP2PProvider)
    # Immediate announcement on startup
    if p.gossip !== nothing && p.local_provider !== nothing
        try
            models = _get_local_models(p)
            if !isempty(models)
                announcement = Dict(
                    "peer_id" => p.peer_id,
                    "addrs" => [a.addr for a in p.local_addrs],
                    "models" => models
                )
                BareLibP2P.GossipSub.publish(p.gossip, p.service_topic, JSON3.write(announcement))
                @info "[BareLibP2P] Announced local models" count=length(models)
            end
        catch e
            @warn "[BareLibP2P] Announce failed" error=e
        end
    end
end

function _get_local_models(p::BareLibP2PProvider)
    models = Dict{String,String}()
    try
        if p.local_provider !== nothing
            # Determine provider type and get models via Val dispatch
            prov_name = FlootyAbstract.provider_name(p.local_provider)
            if prov_name === :ollama
                config = Dict{Symbol,Any}(:baseURL => "http://localhost:11434")
                local_models = FlootyAbstract.list_provider_models(Val(:ollama), config)
                for m in local_models
                    models[FlootyAbstract.model_name(m)] = "ollama"
                end
            elseif prov_name === :openai
                api_key = get(ENV, "OPENAI_API_KEY", "")
                config = Dict{Symbol,Any}(:baseURL => "https://api.openai.com/v1", :apiKey => api_key)
                local_models = FlootyAbstract.list_provider_models(Val(:openai), config)
                for m in local_models
                    models[FlootyAbstract.model_name(m)] = "openai"
                end
            end
        end
    catch e
        @warn "[BareLibP2P] Could not list local models" error=e
    end
    models
end

# ═══════════════════════════════════════════════════════════════════════
# Provider Instance & Model Listing
# ═══════════════════════════════════════════════════════════════════════

function FlootyAbstract.create_provider_instance(::Val{:barelibp2p}; config::Dict{Symbol,Any}=Dict{Symbol,Any}())
    existing = GLOBAL_BARELIBP2P_PROVIDER[]
    (existing !== nothing && existing.node_running) && return existing
    
    BareLibP2PProvider(
        p2p_port = get(config, :p2p_port, 4001),
        api_port = get(config, :api_port, 5001),
        bootstrap_node = get(config, :bootstrap_node, false),
        local_provider = get(config, :local_provider, nothing)
    )
end

function FlootyAbstract.list_provider_models(p::BareLibP2PProvider)
    # Query local provider if available (server/bootstrap mode)
    models = BareLibP2PModel[]
    
    if p.local_provider !== nothing
        try
            prov_name = FlootyAbstract.provider_name(p.local_provider)
            local_models = if prov_name === :ollama
                FlootyAbstract.list_provider_models(Val(:ollama), 
                    Dict{Symbol,Any}(:baseURL => "http://localhost:11434"))
            elseif prov_name === :openai
                FlootyAbstract.list_provider_models(Val(:openai),
                    Dict{Symbol,Any}(:baseURL => "https://api.openai.com/v1", 
                                   :apiKey => get(ENV, "OPENAI_API_KEY", "")))
            else
                FlootyAbstract.AbstractModel[]
            end
            
            # Wrap as barelibp2p models (clients connect via P2P)
            for m in local_models
                push!(models, BareLibP2PModel(
                    name = FlootyAbstract.model_name(m),
                    original_provider = string(prov_name),  # "ollama" for routing
                    peer_id = p.peer_id
                ))
            end
        catch e
            @warn "[BareLibP2P] Could not list local models" error=e
        end
    end
    
    # Also discover models from other peers
    if p.node_running
        for peer in discover_peers(p)
            for (model_name, orig_provider) in peer.models
                push!(models, BareLibP2PModel(
                    name = model_name,
                    original_provider = orig_provider,
                    peer_id = peer.peer_id
                ))
            end
        end
    end
    
    @info "[BareLibP2P] Listed models" count=length(models) islocal=(p.local_provider!==nothing)
    models
end

FlootyAbstract.list_provider_models(::Val{:barelibp2p}, config::Dict{Symbol,Any}=Dict{Symbol,Any}()) =
    FlootyAbstract.list_provider_models(FlootyAbstract.create_provider_instance(:barelibp2p; config=config))

# ═══════════════════════════════════════════════════════════════════════
# Tools
# ═══════════════════════════════════════════════════════════════════════

function FlootyAbstract.build_tool(tool::FlootyAbstract.AbstractTool, p::BareLibP2PProvider; model=nothing, kwargs...)
    Dict(
        "type" => "function",
        "function" => Dict(
            "name" => FlootyAbstract.tool_name(tool),
            "description" => FlootyAbstract.tool_description(tool),
            "parameters" => _tool_params(FlootyAbstract.tool_parameters(tool))
        )
    )
end

function _tool_params(params)
    if params isa Dict && haskey(params, "properties")
        return params
    elseif params isa Vector
        props = Dict{String,Any}()
        for p in params
            if p isa String
                props[p] = Dict("type" => "string")
            elseif p isa Dict
                props[get(p, "name", "param")] = Dict("type" => get(p, "type", "string"))
            end
        end
        return Dict("type" => "object", "properties" => props)
    end
    Dict("type" => "object", "properties" => Dict())
end

FlootyAbstract.create_message(p::BareLibP2PProvider, role::String, content::String; tool_name::Union{String,Nothing}=nothing, kwargs...) =
    OllamaMessage(role=role, content=content, tool_name=tool_name)

FlootyAbstract.create_embedder(p::BareLibP2PProvider, model::String; kwargs...) =
    error("BareLibP2P does not support embeddings")
