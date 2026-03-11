using FlootyStreams
using FlootyStreams: OllamaMessage, chat, OllamaError

provider = OllamaProvider()

response = try
    chat(provider,  [OllamaMessage(role="user", content="Hello, world!")], "qwen3.5:cloud")
catch e
    e
end

if !(response isa OllamaError)
    print(response.message.content)
end
