module FlootyStreams

using FlootyAbstract
using FlootyBase
using StructTypes

# Model cache utility (for all providers)
include("model_cache.jl")

# Ollama
include("ollama/types.jl")
include("ollama/tools.jl")
include("ollama/websearch.jl")
include("ollama/chat.jl")
include("ollama/decision.jl")
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

# BareLibP2P P2P (pure Julia) — temporarily excluded for independent development
# using BareLibP2P
# include("barelibp2p/types.jl")
# include("barelibp2p/interface.jl")

# Fallback: always define GLOBAL_BARELIBP2P_PROVIDER so FlootyCore can reference it
# even when barelibp2p is excluded. Points to nothing until barelibp2p is re-enabled.
const GLOBAL_BARELIBP2P_PROVIDER = Ref{Union{Nothing, Any}}(nothing)

export create_stream
export OllamaMessage, OllamaError, OllamaTool, OllamaToolCall, ImageAttachment, ImageData, OllamaProvider
export OllamaModel
export SystemOneRequest, SystemOneResponse, SystemOneUsage
export SystemOneQuestion, SystemOneChoiceQuestion, SystemOneNoulQuestion, SystemOneScoreQuestion
export SystemOneAnswer, SystemOneChoiceAnswer, SystemOneNoulAnswer, SystemOneScoreAnswer
export systemone, has_capability, is_decision_model, model_capabilities
export WebSearchResult, WebSearchResponse, WebFetchResponse, OllamaWebSearchProvider
export OpenAIMessage, OpenAIError, OpenAITool, OpenAIToolCall, OpenAIProvider
export OpenAIModel
export OpenAIFunction, OpenAITextContent, OpenAIImageContent, OpenAIImageUrl
export ChutesProvider
# export BareLibP2PProvider, BareLibP2PModel, BareLibP2PInferenceResponse
export start_provider, stop_provider
export get_cached_models, cache_models, invalidate_model_cache, clear_model_cache, DEFAULT_CACHE_TTL
export GLOBAL_PROVIDER, GLOBAL_BARELIBP2P_PROVIDER
# export GLOBAL_BARELIBP2P_PROVIDER
export AbstractFlootyError, ToolError

# ═══════════════════════════════════════════════════════════════════════
# Register message/model subtypes with FlootyBase for JSON deserialization
# ═══════════════════════════════════════════════════════════════════════
function __init__()
    FlootyBase.register_message_subtype!(:OllamaMessage, OllamaMessage)
    FlootyBase.register_message_subtype!(:OpenAIMessage, OpenAIMessage)
    # BareLibP2P uses OllamaMessage directly, no separate registration needed
    FlootyBase.register_model_subtype!(:OllamaModel, OllamaModel)
    FlootyBase.register_model_subtype!(:OpenAIModel, OpenAIModel)
    # FlootyBase.register_model_subtype!(:BareLibP2PModel, BareLibP2PModel)
end

end # module FlootyStreams
