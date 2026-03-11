using FlootyStreams
using FlootyStreams: OllamaMessage, chat, OllamaError, create_message
using FlootyStreams: create_provider_instance, create_stream

provider = create_provider_instance(Val(:ollama))

stream = false
response = try
    create_stream(provider, "qwen3.5:cloud", [create_message(provider, "user", "Hello, world!")])
catch e
    e
end

if !(response isa OllamaError)
    print(response.message.content)
end


stream = true

response = try
    create_stream(provider, "qwen3.5:cloud", [create_message(provider, "user", "Hello, world!")], stream)
catch e
    e
end

for i in response
    if !isnothing(i.message.thinking)
        print(i.message.thinking)
    elseif !isnothing(i.message.content)
        print(i.message.content)
    end
end
