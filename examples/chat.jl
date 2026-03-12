using FlootyStreams
using FlootyStreams: OllamaMessage, chat, OllamaError, OllamaProvider

provider = OllamaProvider()

response = try
    chat(provider,  [OllamaMessage(role="user", content="Hello, world!")], "nemotron-3-nano:30b-cloud")
catch e
    e
end

if !(response isa OllamaError)
    print(response.message.content)
end
