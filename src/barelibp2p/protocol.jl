"""
    barelibp2p/protocol.jl

Extended P2P protocol for Ollama chat with tools support.
Replaces simple text prompts with structured JSON requests.
"""

using JSON
using HTTP
using Sockets

# ═══════════════════════════════════════════════════════════════════════
# Protocol Messages (BareLibP2P prefixed to avoid conflicts with Ollama)
# ═══════════════════════════════════════════════════════════════════════

"""Base protocol message"""
abstract type P2PMessage end

"""Chat request with tools"""
struct BareLibP2PChatRequest <: P2PMessage
    model::String
    messages::Vector{Dict{String,String}}
    tools::Union{Vector{Dict{String,Any}},Nothing}
    stream::Bool
    options::Dict{String,Any}
end

"""Chat response"""
struct BareLibP2PChatResponse <: P2PMessage
    message::Dict{String,Any}  # {role, content, tool_calls?}
    done::Bool
    model::String
    error::Union{String,Nothing}
end

"""Tool result submission"""
struct BareLibP2PToolResultMessage <: P2PMessage
    call_id::String
    name::String
    content::String
end

# ═══════════════════════════════════════════════════════════════════════
# Server-side Handler (runs on remote peer with Ollama)
# ═══════════════════════════════════════════════════════════════════════

"""
    start_ollama_handler(port::Int)

Start a TCP server that handles P2P chat requests and forwards to local Ollama.
This runs on the "server" peer that has Ollama installed.
"""
function start_ollama_handler(port::Int=11435)
    server = listen(port)
    @info "Ollama P2P handler listening on port $port"
    
    @async begin
        while true
            client = accept(server)
            @async handle_ollama_client(client)
        end
    end
    
    return server
end

"""
    handle_ollama_client(client::TCPSocket)

Handle a single P2P client connection.
"""
function handle_ollama_client(client::TCPSocket)
    try
        # Read request line
        line = readline(client)
        isempty(line) && return
        
        # Parse JSON request
        request = JSON.parse(line)
        action = get(request, "action", "")
        
        if action == "chat"
            response = handle_chat_request(request)
        elseif action == "chat_with_results"
            response = handle_chat_with_results(request)
        else
            response = Dict("error" => "Unknown action: $action")
        end
        
        # Send response
        write(client, JSON.json(response) * "\n")
        
    catch e
        @error "Handler error" exception=e
        try
            error_resp = Dict("error" => string(e))
            write(client, JSON.json(error_resp) * "\n")
        catch
        end
    finally
        close(client)
    end
end

"""
    handle_chat_request(request::Dict) -> Dict

Forward chat request to local Ollama /api/chat endpoint.
"""
function handle_chat_request(request::Dict)
    model = get(request, "model", "llama2")
    messages = get(request, "messages", Dict{String,String}[])
    tools = get(request, "tools", nothing)
    stream = get(request, "stream", false)
    options = get(request, "options", Dict())
    
    # Build Ollama request
    ollama_req = Dict(
        "model" => model,
        "messages" => messages,
        "stream" => stream
    )
    
    if tools !== nothing && !isempty(tools)
        ollama_req["tools"] = tools
    end
    
    if !isempty(options)
        ollama_req["options"] = options
    end
    
    # Call local Ollama
    try
        resp = HTTP.post(
            "http://localhost:11434/api/chat",
            ["Content-Type" => "application/json"],
            JSON.json(ollama_req)
        )
        
        if resp.status == 200
            # Parse streaming or non-streaming response
            body = String(resp.body)
            
            # Handle NDJSON (streaming) - get last message
            if stream
                lines = split(body, "\n")
                last_msg = nothing
                for line in lines
                    isempty(line) && continue
                    try
                        msg = JSON.parse(line)
                        if get(msg, "done", false)
                            last_msg = msg
                            break
                        end
                    catch
                    end
                end
                
                if last_msg !== nothing
                    return last_msg
                else
                    # Fallback: try parsing first line
                    return JSON.parse(first(lines))
                end
            else
                # Single JSON response
                return JSON.parse(body)
            end
        else
            return Dict("error" => "Ollama returned status $(resp.status)")
        end
        
    catch e
        return Dict("error" => "Ollama request failed: $(string(e))")
    end
end

"""
    handle_chat_with_results(request::Dict) -> Dict

Handle chat request that includes tool execution results.
"""
function handle_chat_with_results(request::Dict)
    model = get(request, "model", "llama2")
    messages = get(request, "messages", Dict{String,String}[])
    tool_results = get(request, "tool_results", Dict{String,String}[])
    
    # Add tool results as messages
    extended_messages = copy(messages)
    for tr in tool_results
        push!(extended_messages, Dict(
            "role" => "tool",
            "content" => get(tr, "content", ""),
            "name" => get(tr, "name", "unknown")
        ))
    end
    
    # Re-call Ollama with extended context
    ollama_req = Dict(
        "model" => model,
        "messages" => extended_messages,
        "stream" => false
    )
    
    try
        resp = HTTP.post(
            "http://localhost:11434/api/chat",
            ["Content-Type" => "application/json"],
            JSON.json(ollama_req)
        )
        
        if resp.status == 200
            return JSON.parse(String(resp.body))
        else
            return Dict("error" => "Ollama returned status $(resp.status)")
        end
        
    catch e
        return Dict("error" => "Ollama request failed: $(string(e))")
    end
end

# ═══════════════════════════════════════════════════════════════════════
# Client-side Functions (runs on "client" peer calling remote)
# ═══════════════════════════════════════════════════════════════════════

"""
    chat_with_tools_p2p(provider::BareLibP2PProvider, peer_id::String,
                       model::String, messages::Vector{Dict},
                       tools::Union{Vector,Nothing}=nothing) -> BareLibP2PChatResponse

Send a chat request with tools to a remote peer via P2P.
"""
function chat_with_tools_p2p(
    provider::BareLibP2PProvider,
    peer_id::String,
    model::String,
    messages::Vector{Dict{String,String}};
    tools::Union{Vector{Dict{String,Any}},Nothing}=nothing,
    options::Dict{String,Any}=Dict()
)
    # Look up peer
    peer_info = find_peer(provider.dht, peer_id)
    
    if peer_info === nothing
        # Try gossip
        gossip_peers = discover_peers(provider)
        for gp in gossip_peers
            if gp.peer_id == peer_id
                host_port = BareLibP2P.Multiaddr.get_host_port(gp.addrs[1])
                return _send_chat_request(host_port[1], host_port[2], model, messages, tools, options)
            end
        end
        error("Peer not found: $peer_id")
    end
    
    # Connect and send
    host_port = BareLibP2P.Multiaddr.get_host_port(peer_info.addrs[1])
    return _send_chat_request(host_port[1], host_port[2], model, messages, tools, options)
end

"""
    _send_chat_request(host, port, model, messages, tools, options) -> Dict

Internal: Send HTTP-style chat request over TCP.
"""
function _send_chat_request(
    host::String,
    port::Int,
    model::String,
    messages::Vector{Dict{String,String}},
    tools::Union{Vector,Nothing},
    options::Dict{String,Any}
)
    socket = connect(host, port)
    try
        # Build request
        request = Dict(
            "action" => "chat",
            "model" => model,
            "messages" => messages,
            "stream" => false
        )
        
        if tools !== nothing && !isempty(tools)
            request["tools"] = tools
        end
        
        if !isempty(options)
            request["options"] = options
        end
        
        # Send
        write(socket, JSON.json(request) * "\n")
        
        # Read response
        response_line = readline(socket)
        
        if isempty(response_line)
            return BareLibP2PChatResponse(
                Dict("role" => "assistant", "content" => "Empty response"),
                true, model, "Empty response"
            )
        end
        
        # Parse response
        resp = JSON.parse(response_line)
        
        if haskey(resp, "error")
            return BareLibP2PChatResponse(
                Dict("role" => "assistant", "content" => resp["error"]),
                true, model, resp["error"]
            )
        end
        
        message = get(resp, "message", Dict("role" => "assistant", "content" => ""))
        return BareLibP2PChatResponse(message, true, model, nothing)
        
    catch e
        return BareLibP2PChatResponse(
            Dict("role" => "assistant", "content" => "Error: $(string(e))"),
            true, model, string(e)
        )
    finally
        close(socket)
    end
end

"""
    send_tool_results_p2p(provider::BareLibP2PProvider, peer_id::String,
                         model::String, messages::Vector{Dict},
                         tool_results::Vector{Dict}) -> BareLibP2PChatResponse

Send tool results back to remote peer for final response.
"""
function send_tool_results_p2p(
    provider::BareLibP2PProvider,
    peer_id::String,
    model::String,
    messages::Vector{Dict{String,String}},
    tool_results::Vector{Dict{String,Any}}
)
    # Look up peer
    peer_info = find_peer(provider.dht, peer_id)
    
    if peer_info === nothing
        error("Peer not found: $peer_id")
    end
    
    host_port = BareLibP2P.Multiaddr.get_host_port(peer_info.addrs[1])
    host, port = host_port
    
    socket = connect(host, port)
    try
        request = Dict(
            "action" => "chat_with_results",
            "model" => model,
            "messages" => messages,
            "tool_results" => tool_results
        )
        
        write(socket, JSON.json(request) * "\n")
        
        response_line = readline(socket)
        resp = JSON.parse(response_line)
        
        if haskey(resp, "error")
            return BareLibP2PChatResponse(
                Dict("role" => "assistant", "content" => resp["error"]),
                true, model, resp["error"]
            )
        end
        
        message = get(resp, "message", Dict("role" => "assistant", "content" => ""))
        return BareLibP2PChatResponse(message, true, model, nothing)
        
    catch e
        return BareLibP2PChatResponse(
            Dict("role" => "assistant", "content" => "Error: $(string(e))"),
            true, model, string(e)
        )
    finally
        close(socket)
    end
end
