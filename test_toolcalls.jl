#!/usr/bin/env julia
# Debug script for BareLibP2P tool calls

using FlootyStreams
using FlootyAbstract
using JSON
using StructTypes

println("="^60)
println("BareLibP2P Tool Call Debug")
println("="^60)

# Test 1: Create OllamaMessage with tool_calls
println("\n[Test 1] Creating OllamaMessage with tool_calls...")

msg_with_tools = FlootyStreams.OllamaMessage(
    role = "assistant",
    content = "I'll calculate that",
    tool_calls = [
        FlootyStreams.OllamaToolCall(
            FlootyStreams.OllamaToolCallFunction(
                name = "calculator",
                arguments = Dict("expression" => "2+2")
            )
        )
    ]
)

println("  ✓ Created message")
println("  role: ", FlootyAbstract.role(msg_with_tools))
println("  content: ", FlootyAbstract.content(msg_with_tools))
println("  has tool_calls: ", FlootyAbstract.tool_calls(msg_with_tools) !== nothing)

# Test 2: Serialize using StructTypes
println("\n[Test 2] Serializing with StructTypes.lower...")
msg_dict = StructTypes.lower(msg_with_tools)
msg_json = JSON.json(msg_dict)
println("  ✓ Serialized")
println("  JSON: ", msg_json[1:min(100, length(msg_json))], "...")

# Check if tool_calls is in the JSON
if occursin("tool_calls", msg_json)
    println("  ✓ tool_calls PRESENT in JSON")
else
    println("  ✗ tool_calls MISSING from JSON!")
end

# Test 3: Deserialize
println("\n[Test 3] Deserializing with StructTypes.constructfrom...")
parsed = JSON.parse(msg_json)
msg_back = StructTypes.constructfrom(FlootyStreams.OllamaMessage, parsed)
println("  ✓ Deserialized")
println("  has tool_calls: ", FlootyAbstract.tool_calls(msg_back) !== nothing)

# Test 4: Test wrap_for_ollama function
println("\n[Test 4] Testing wrap_for_ollama...")
messages = [msg_with_tools]

# Import the wrap function
include("$(homedir())/.julia/dev/FlootyStreams/src/barelibp2p/interface.jl")

try
    # Call wrap_for_ollama (it's defined in interface.jl)
    wrapped = FlootyStreams.wrap_for_ollama(messages)
    println("  ✓ Wrapped messages")
    println("  Output: ", wrapped[1:min(200, length(wrapped))], "...")
    
    if occursin("tool_calls", wrapped)
        println("  ✓ tool_calls PRESENT in wrapped output")
    else
        println("  ✗ tool_calls MISSING from wrapped output!")
    end
catch e
    println("  ✗ Error: ", e)
end

# Test 5: Check OllamaResponse wrapping
println("\n[Test 5] Testing OllamaResponse wrapping...")

resp = FlootyStreams.OllamaResponse(
    message = msg_with_tools,
    model = "llama3:8b",
    done = true
)

# Check response_has_tool_calls (from FlootyAbstract)
has_tools = FlootyAbstract.response_has_tool_calls(resp)
println("  response_has_tool_calls: ", has_tools)

if has_tools
    msg_from_resp = FlootyAbstract.response_message(resp)
    tcs = FlootyAbstract.tool_calls(msg_from_resp)
    if tcs !== nothing && !isempty(tcs)
        println("  ✓ Tool calls accessible from response")
        for tc in tcs
            println("    - ", FlootyAbstract.call_name(tc))
        end
    end
end

println("\n" * "="^60)
println("Debug complete")
println("="^60)
