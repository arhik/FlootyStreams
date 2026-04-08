module FlootyStreams

using FlootyAbstract
using FlootyBase
using StructTypes

# Ollama
include("ollama/types.jl")
include("ollama/tools.jl")
include("ollama/websearch.jl")
include("ollama/chat.jl")
include("ollama/utils.jl")
include("ollama/interface.jl")

# OpenAI
include("openai/types.jl")
include("openai/tools.jl")
include("openai/chat.jl")
include("openai/utils.jl")
include("openai/interface.jl")

# Chutes (OpenAI-compatible)
include("openai/chutes.jl")

export create_stream
export OllamaMessage, OllamaError, OllamaTool, OllamaToolCall, ImageAttachment
export OllamaModel
export WebSearchResult, WebSearchResponse, WebFetchResponse, OllamaWebSearchProvider
export OpenAIMessage, OpenAIError, OpenAITool, OpenAIToolCall, OpenAIProvider
export OpenAIModel
export OpenAIFunction, OpenAITextContent, OpenAIImageContent, OpenAIImageUrl
export ChutesProvider
export AbstractFlootyError, ToolError

# ═══════════════════════════════════════════════════════════════════════
# Register message/model subtypes with FlootyBase for JSON deserialization
# ═══════════════════════════════════════════════════════════════════════
function __init__()
    FlootyBase.register_message_subtype!(:OllamaMessage, OllamaMessage)
    FlootyBase.register_message_subtype!(:OpenAIMessage, OpenAIMessage)
    FlootyBase.register_model_subtype!(:OllamaModel, OllamaModel)
    FlootyBase.register_model_subtype!(:OpenAIModel, OpenAIModel)
end

end # module FlootyStreams
