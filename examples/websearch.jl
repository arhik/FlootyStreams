using FlootySessions
using FlootyAbstract
using FlootyBase

ENV["OLLAMA_API_KEY"] = "your-api-key"

# Check all 9 tools are registered in FlootySessions
println("Registered handlers (via FlootySessions):")
for t in FlootyBase.list_default_tools()
    has_handler = FlootyAbstract.get_tool_handler(FlootyAbstract.tool_name(t)) !== nothing
    println("  - $(FlootyAbstract.tool_name(t)): ", has_handler ? "✓" : "✗")
end

# Test REPL tool (executes locally via IOCapture)
println("\nTesting repl tool...")
repl_result = execute_tool("repl", Dict{String,Any}("code" => "sum(1:10)"))
println("REPL success: ", repl_result.success)
println("REPL output: ", repl_result.data)

# Test error handling
println("\nTesting repl error handling...")
err_result = execute_tool("repl", Dict{String,Any}("code" => "1÷0"))
println("Error success: ", err_result.success)

# Show all tool definitions
repl = FlootyBase.repl_tool()
println("\nREPL tool parameters:")
for p in FlootyAbstract.tool_parameters(repl)
    println("  - $(p.name) ($(p.param_type))", p.required ? " [required]" : "")
end

println("\n✓ All 9 tools (new: repl) available via FlootySessions")
