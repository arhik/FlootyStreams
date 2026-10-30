module FlootyStreams

using FlootyAbstract
using FlootyBase
using StructTypes

# Provider lifecycle hooks (implemented per-provider)
function start_provider end
function stop_provider end

# Model cache utility (for all providers)
include("model_cache.jl")

# Ollama
include("ollama/types.jl")
include("ollama/tools.jl")
include("ollama/websearch.jl")
include("ollama/chat.jl")
include("ollama/decision.jl")
include("ollama/speech.jl")
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

# FlootyCompute P2P (Rust/iroh via libflootycompute)
include("flootycompute/types.jl")
include("flootycompute/interface.jl")

export create_stream
export OllamaMessage, OllamaError, OllamaTool, OllamaToolCall, ImageAttachment, ImageData, OllamaProvider, LlamaCppProvider
export OllamaModel
export OllamaSpeechResponse
export SystemOneRequest, SystemOneResponse, SystemOneUsage
export SystemOneQuestion, SystemOneChoiceQuestion, SystemOneNoulQuestion, SystemOneScoreQuestion
export SystemOneAnswer, SystemOneChoiceAnswer, SystemOneNoulAnswer, SystemOneScoreAnswer
export systemone, has_capability, is_decision_model, model_capabilities
export WebSearchResult, WebSearchResponse, WebFetchResponse, OllamaWebSearchProvider
export OpenAIMessage, OpenAIError, OpenAITool, OpenAIToolCall, OpenAIProvider
export OpenAIModel
export OpenAIFunction, OpenAITextContent, OpenAIImageContent, OpenAIImageUrl
export ChutesProvider
export FlootyComputeProvider, FlootyComputeModel, GLOBAL_FLOOTYCOMPUTE_PROVIDER, add_peer
export start_provider, stop_provider
export get_cached_models, cache_models, invalidate_model_cache, clear_model_cache, DEFAULT_CACHE_TTL
export GLOBAL_PROVIDER
export AbstractFlootyError, ToolError

function __init__()
    FlootyBase.register_message_subtype!(:OllamaMessage, OllamaMessage)
    FlootyBase.register_message_subtype!(:OpenAIMessage, OpenAIMessage)
    FlootyBase.register_model_subtype!(:OllamaModel, OllamaModel)
    FlootyBase.register_model_subtype!(:OpenAIModel, OpenAIModel)
    FlootyBase.register_model_subtype!(:FlootyComputeModel, FlootyComputeModel)
end


end # module FlootyStreams
