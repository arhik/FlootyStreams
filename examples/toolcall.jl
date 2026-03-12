using FlootyStreams
using FlootyStreams: OllamaError
using FlootyAbstract: create_message, create_provider_instance, create_stream, content, call_name, call_arguments
using JSON3
using OrderedCollections

# Setup
provider = create_provider_instance(Val(:ollama))

# Create tools
tools = [pwd_tool()]

# User asks something that should trigger tool call
msg = create_message(provider,
    "user", 
    "What directory am I in?"
)

# Chat with LLM
stream = false
format = nothing
options = nothing
response = try
    create_stream(provider, "nemotron-3-nano:30b-cloud", [msg], stream, format, options, tools)
catch e
    e
end

# Handle response
if !(response isa OllamaError) && response.message.tool_calls !== nothing
    for tc in response.message.tool_calls
        name = call_name(tc)
        args = call_arguments(tc)
        
        if name == "pwd"
            result = pwd()
            
            tool_msg = create_message(
                provider,
                "tool", 
                result
            )
            
            # Make follow-up request with tool result
            final_response = create_stream(
                provider, 
                "nemotron-3-nano:30b-cloud",
                [msg, response.message, tool_msg], 
                false,
                nothing,
                nothing,
                nothing
            )
            
            content(final_response.message)
        end
    end
else
    content(response.message)
end
