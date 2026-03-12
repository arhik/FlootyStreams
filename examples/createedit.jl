using FlootyStreams
using FlootyContextManager: ContextStore, add_message!, get_messages
using FlootyAbstract: create_message, create_provider_instance, create_stream, content, call_name, call_arguments, execute_tool, ToolError

# Configuration
const MAX_RETRIES = 3
const MAX_ITERATIONS = 10

test_file = "/tmp/project_plan.md"
provider = create_provider_instance(Val(:ollama))
tools = [pwd_tool(), ls_tool(), read_tool(), write_tool()]

function execute_with_retry(tool_name::String, args::Dict{String,Any}, max_retries::Int=MAX_RETRIES)
    for attempt in 1:max_retries
        result = execute_tool(tool_name, args)
        if result.success
            return result
        end
        @warn "Tool $tool_name failed (attempt $attempt/$max_retries): $(result.error)"
        if attempt == max_retries
            return result
        end
    end
end

function run_conversation_round!(ctx, initial_msg, tools; max_iterations=MAX_ITERATIONS)
    add_message!(ctx, initial_msg)
    current_resp = create_stream(provider, "nemotron-3-nano:30b-cloud", get_messages(ctx), false, nothing, nothing, tools)
    
    iteration = 0
    last_result = nothing
    
    while !(current_resp isa FlootyStreams.OllamaError) && 
          iteration < max_iterations
        
        if current_resp.message.tool_calls !== nothing
            add_message!(ctx, current_resp.message)
            println("LLM: ", content(current_resp.message))
            
            for tc in current_resp.message.tool_calls
                tool_name_str = call_name(tc)
                args = call_arguments(tc)
                println("Tool: $tool_name_str")
                
                last_result = execute_with_retry(tool_name_str, args)
                
                if !last_result.success
                    # Add error message, may trigger ToolError after retries
                    tool_msg = create_message(provider, "tool", 
                        "ERROR: $(last_result.error). Line numbers are 1-based (first line is 1).")
                else
                    tool_msg = create_message(provider, "tool", last_result.data)
                end
                add_message!(ctx, tool_msg)
                
                # Verify no duplicates after edit
                if tool_name_str == "write" && isfile(args["path"])
                    lines = readlines(args["path"])
                    # Simple duplicate section detection
                    counts = Dict{String,Int}()
                    for line in lines
                        if startswith(line, "#")
                            counts[line] = get(counts, line, 0) + 1
                        end
                    end
                    dupes = filter(p -> p.second > 1, counts)
                    if !isempty(dupes)
                        @warn "Duplicate headers detected: $(keys(dupes))"
                    end
                end
            end
        else
            add_message!(ctx, current_resp.message)
            println("LLM: ", content(current_resp.message))
            break
        end
        
        current_resp = create_stream(provider, "nemotron-3-nano:30b-cloud", get_messages(ctx), false, nothing, nothing, tools)
        iteration += 1
    end
    
    if current_resp isa FlootyStreams.OllamaError
        throw(ToolError("LLM communication failed", "create_stream"))
    end
    
    return get_messages(ctx)
end

# Run the demo
ctx = ContextStore()

println("="^60)
println("Step 1: Create project plan")
println("="^60)

try
    msg1 = create_message(provider, "user", 
        "Create $test_file with sections Overview and Timeline. Use write tool.")
    run_conversation_round!(ctx, msg1, tools)
    
    if !isfile(test_file)
        throw(ToolError("File was not created", "write"))
    end
    
    println("\n" * "="^60)
    println("Step 2: Edit Timeline section")
    println("="^60)
    
    msg2 = create_message(provider, "user",
        "Read $test_file. Find Timeline section START line (the ## Timeline header). " *
        "Then use write with start_line being the CONTENT line AFTER the header (not including header).")
    run_conversation_round!(ctx, msg2, tools)
    
    println("\n" * "="^60)
    println("Final content:")
    println("="^60)
    println(read(test_file, String))
    
catch e
    if e isa ToolError
        println("\nTool Error: ", error_message(e))
        exit(1)
    else
        rethrow(e)
    end
end

println("\nMessages: ", length(get_messages(ctx)))
