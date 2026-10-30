"""
    flootycompute/interface.jl

FlootyAbstract provider implementation backed by FlootyCompute (Rust/iroh).
"""

import FlootyCompute

# ─── Lifecycle ─────────────────────────────────────────────────────────

function FlootyStreams.start_provider(p::FlootyComputeProvider)
    p.nodeRunning && return true
    try
        FlootyCompute.initLibrary()
    catch e
        @warn "[FlootyCompute] native library unavailable" exception=e
        return false
    end

    models = _local_model_names(p)
    rc = try
        FlootyCompute.startDaemon(
            p.p2pPort;
            apiPort=p.apiPort,
            models=models,
            bootstrapPeers=p.bootstrap_peers,
            keyFile=p.keyFile,
            enableRelay=p.enableRelay,
            discoveryTopic=p.discoveryTopic,
            enableMdns=p.enableMdns,
        )
    catch e
        @warn "[FlootyCompute] startDaemon failed" exception=e
        return false
    end

    if rc != 0
        @warn "[FlootyCompute] startDaemon returned nonzero" rc
        return false
    end

    p.nodeRunning = true
    p.nodeId = try
        String(FlootyCompute.getNodeId())
    catch
        ""
    end
    # Start the local HTTP inference service so peers can reach our models.
    # handle_inference POSTs to apiUrl; without this the serving side is dead.
    if p.apiPort > 0
        try
            FlootyCompute.startApiService(p.apiPort; handler=FlootyCompute.ollamaHandler)
            p.apiUrl = "http://127.0.0.1:$(p.apiPort)/inference"
            FlootyCompute.setApiUrl(p.apiUrl)
            @info "[FlootyCompute] inference API up" url=p.apiUrl
        catch e
            @warn "[FlootyCompute] could not start inference API service" exception=e
        end
    end

    GLOBAL_FLOOTYCOMPUTE_PROVIDER[] = p
    @info "[FlootyCompute] node started" nodeId=p.nodeId p2pPort=p.p2pPort apiPort=p.apiPort
    return true
end

function FlootyStreams.stop_provider(p::FlootyComputeProvider)
    p.nodeRunning || return true
    ok = try
        FlootyCompute.stopDaemon() == 0
    catch e
        @warn "[FlootyCompute] stopDaemon failed" exception=e
        false
    end
    p.nodeRunning = false
    GLOBAL_FLOOTYCOMPUTE_PROVIDER[] === p && (GLOBAL_FLOOTYCOMPUTE_PROVIDER[] = nothing)
    return ok
end

function FlootyAbstract.provider_name(::FlootyComputeProvider)
    return :flootycompute
end

function FlootyAbstract.set_inference_api_url(p::FlootyComputeProvider, url::String)
    p.apiUrl = url
    p.nodeRunning || return 0
    try
        return FlootyCompute.setApiUrl(url)
    catch e
        @warn "[FlootyCompute] setApiUrl failed" exception=e
        return -1
    end
end

# ─── Discovery ─────────────────────────────────────────────────────────

function _json_or_empty(f)
    try
        return JSON3.read(f())
    catch e
        @warn "[FlootyCompute] discovery call failed" exception=e
        return nothing
    end
end

"""
    discover_peers(p) -> Vector{NamedTuple}

Returns discovered peers as `(peer_id, models)` named tuples.
"""
function discover_peers(p::FlootyComputeProvider)
    p.nodeRunning || return NamedTuple[]
    nodes = _json_or_empty(FlootyCompute.getDiscoveredNodes)
    nodes === nothing && return NamedTuple[]
    peers = NamedTuple[]
    for (peer_id, info) in pairs(nodes)
        models = try
            get(info, :model_names, String[])
        catch
            String[]
        end
        push!(peers, (peer_id=String(peer_id), models=String[String(m) for m in models]))
    end
    return peers
end

function find_peer_with_model(peers, model::String)
    for peer in peers
        model in peer.models && return peer
    end
    return nothing
end

# ─── Chat ──────────────────────────────────────────────────────────────

function FlootyAbstract.chat(
    p::FlootyComputeProvider,
    agent::FlootyAbstract.AbstractAgent,
    messages::Vector{<:FlootyAbstract.AbstractMessage};
    tools::Vector{<:FlootyAbstract.AbstractTool}=FlootyAbstract.AbstractTool[],
    stream::Bool=false,
)
    p.nodeRunning || FlootyStreams.start_provider(p)

    model = agent.model
    @info "[FlootyCompute] chat" model=model

    peers = discover_peers(p)
    if isempty(peers)
        return _kc_error("No FlootyCompute peers available")
    end

    # Prefer peers advertising the model, but fall back to any peer: a peer may
    # have pulled the model after we last refreshed its ServiceInfo.
    candidates = [q for q in peers if model in q.models]
    isempty(candidates) && (candidates = peers)

    prompt = _messages_to_prompt(messages)
    last_err = "no peers tried"
    for peer in candidates
        raw = try
            FlootyCompute.sendInferenceRequest(peer.peer_id, model, prompt)
        catch e
            last_err = string(e)
            @warn "[FlootyCompute] peer failed, trying next" peer=peer.peer_id error=last_err
            continue
        end
        resp = _parse_inference_response(raw)
        # A peer-side error is worth retrying elsewhere.
        if occursin("Error: ", string(FlootyAbstract.content(resp.message)))
            last_err = string(FlootyAbstract.content(resp.message))
            continue
        end
        return resp
    end

    return _kc_error("All peers failed for model $model: $last_err")
end

# ─── Helpers ───────────────────────────────────────────────────────────

function _kc_error(msg::String)
    return ChatResponse(
        OllamaMessage(role="assistant", content="Error: $msg"),
        nothing, nothing, true, nothing, nothing, nothing, nothing, nothing,
    )
end

function _messages_to_prompt(messages)
    parts = String[]
    for m in messages
        r = try
            FlootyAbstract.role(m)
        catch
            "user"
        end
        c = try
            FlootyAbstract.content(m)
        catch
            ""
        end
        push!(parts, "$r: $c")
    end
    return join(parts, "\n")
end

function _parse_inference_response(raw::AbstractString)
    startswith(raw, "Error: ") && return _kc_error(strip(raw[8:end]))
    data = try
        JSON3.read(raw)
    catch e
        return _kc_error("Could not parse FlootyCompute response: $e")
    end

    # Peer-side error payload: {"status":"error","message":"..."}
    status = get(data, :status, nothing)
    if status !== nothing && String(status) == "error"
        return _kc_error(String(get(data, :message, "unknown peer error")))
    end

    msg = get(data, :message, nothing)
    if msg isa AbstractDict
        return ChatResponse(
            OllamaMessage(role="assistant", content=String(get(msg, :content, ""))),
            get(data, :model, nothing),
            nothing, true, nothing, nothing, nothing, nothing, nothing,
        )
    end

    content = get(data, :content, nothing)
    content === nothing && (content = get(data, :response, raw))
    return ChatResponse(
        OllamaMessage(role="assistant", content=String(content)),
        nothing, nothing, true, nothing, nothing, nothing, nothing, nothing,
    )
end

# ─── Local models ──────────────────────────────────────────────────────

function _local_model_names(p::FlootyComputeProvider)
    # Prefer the wrapped provider when present (serving side).
    if p.wrapped !== nothing
        try
            return String[FlootyAbstract.model_name(m) for m in FlootyAbstract.list_provider_models(p.wrapped)]
        catch e
            @warn "[FlootyCompute] could not list wrapped models" exception=e
        end
    end
    # Otherwise advertise whatever the local Ollama has, so peers can route to us.
    try
        return FlootyCompute.getOllamaModels()
    catch e
        @warn "[FlootyCompute] could not query local Ollama" exception=e
        return String[]
    end
end

function FlootyAbstract.chat_stream(
    p::FlootyComputeProvider,
    model::String,
    messages::Vector{<:FlootyAbstract.AbstractMessage},
    stream::Bool=false,
    format=nothing,
    options=nothing,
    tools=nothing,
)
    p.nodeRunning || FlootyStreams.start_provider(p)

    peers = discover_peers(p)
    isempty(peers) && return _kc_error("No FlootyCompute peers available")

    peer = find_peer_with_model(peers, model)
    peer === nothing && return _kc_error("No peer found for model: $model")

    raw = try
        FlootyCompute.sendInferenceRequest(peer.peer_id, model, _messages_to_prompt(messages))
    catch e
        return _kc_error("FlootyCompute request failed: $e")
    end

    return _parse_inference_response(raw)
end

function FlootyAbstract.list_provider_models(p::FlootyComputeProvider)
    models = FlootyComputeModel[]
    seen = Set{String}()

    local_caps = try
        FlootyCompute.getOllamaModelCapabilities()
    catch
        Dict{String, Vector{Symbol}}()
    end

    prov = try
        p.wrapped === nothing ? "ollama" : string(FlootyAbstract.provider_name(p.wrapped))
    catch
        "ollama"
    end
    for name in _local_model_names(p)
        name in seen && continue
        push!(seen, name)
        push!(models, FlootyComputeModel(
            name = name,
            original_provider = prov,
            peer_id = p.nodeId,
            capabilities = get(local_caps, name, Symbol[]),
        ))
    end

    for peer in discover_peers(p)
        for name in peer.models
            name in seen && continue
            push!(seen, name)
            push!(models, FlootyComputeModel(
                name = name,
                original_provider = "remote",
                peer_id = peer.peer_id,
            ))
        end
    end

    return models
end

function FlootyAbstract.build_tool(tool::FlootyAbstract.AbstractTool, p::FlootyComputeProvider; model=nothing, kwargs...)
    p.wrapped === nothing && return tool
    return FlootyAbstract.build_tool(tool, p.wrapped; model=model, kwargs...)
end

function FlootyAbstract.create_provider_instance(::Val{:flootycompute}; config::Dict{Symbol,Any}=Dict{Symbol,Any}())
    existing = GLOBAL_FLOOTYCOMPUTE_PROVIDER[]
    (existing !== nothing && existing.nodeRunning) && return existing

    return FlootyComputeProvider(
        bootstrap_node = get(config, :bootstrap_node, false),
        bootstrap_peers = get(config, :bootstrap_peers, String[]),
        p2pPort = get(config, :p2pPort, get(config, :p2p_port, 0)),
        apiPort = get(config, :apiPort, get(config, :api_port, 0)),
        discoveryTopic = get(config, :discovery_topic, "flootycompute-nodes-v1"),
        enableRelay = get(config, :enable_relay, true),
        enableMdns = get(config, :enable_mdns, true),
        keyFile = get(config, :key_file, nothing),
        wrapped = get(config, :wrapped, get(config, :local_provider, nothing)),
    )
end

"""
    add_peer(p::FlootyComputeProvider, ticket::String) -> Bool

Add a peer at runtime from its endpoint ticket. This is the reliable
cross-machine path: mDNS is link-local multicast and is frequently blocked
between hosts, whereas a ticket dial works through relays.
"""
function add_peer(p::FlootyComputeProvider, ticket::String; attempts::Int=3)
    p.nodeRunning || FlootyStreams.start_provider(p)
    # The verify handshake can lose a race with the peer still coming online,
    # so retry a few times before reporting failure.
    for i in 1:attempts
        FlootyCompute.addPeer(ticket) == 0 && return true
        i < attempts && sleep(2)
    end
    return false
end
function _kc_stream_or_error(stream::Bool, msg::String)
    resp = _kc_error(msg)
    if stream
        return Channel{ChatResponse}(1) do ch
            put!(ch, resp)
        end
    end
    return resp
end
function FlootyStreams.chat(
    p::FlootyComputeProvider,
    messages::Vector{OllamaMessage},
    model::String,
    stream::Bool=false,
    format::Union{Nothing,String,OrderedDict}=nothing,
    options::Union{Nothing,Dict{String,Any}}=nothing,
    tools::Union{Vector{OllamaTool},Nothing}=nothing,
)
    p.nodeRunning || FlootyStreams.start_provider(p)

    peers = discover_peers(p)
    if isempty(peers)
        return _kc_stream_or_error(stream, "No FlootyCompute peers available")
    end

    candidates = [q for q in peers if model in q.models]
    isempty(candidates) && (candidates = peers)

    prompt = _messages_to_prompt(messages)
    last_err = "no peers tried"
    for peer in candidates
        raw = try
            FlootyCompute.sendInferenceRequest(peer.peer_id, model, prompt)
        catch e
            last_err = string(e)
            continue
        end
        resp = _parse_inference_response(raw)
        if occursin("Error: ", string(FlootyAbstract.content(resp.message)))
            last_err = string(FlootyAbstract.content(resp.message))
            continue
        end
        return resp
    end
    return _kc_stream_or_error(stream, "All peers failed for model $model: $last_err")
end
