module FlootyStreams

using FlootyAbstract
using FlootyBase
using StructTypes
using PeerCompute
using BareLibP2P

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

# PeerCompute P2P (libp2p-go)
include("peercompute/types.jl")
include("peercompute/interface.jl")

# BareLibP2P P2P (pure Julia)
include("barelibp2p/types.jl")
include("barelibp2p/interface.jl")
include("barelibp2p/protocol.jl")

export create_stream
export OllamaMessage, OllamaError, OllamaTool, OllamaToolCall, ImageAttachment
export OllamaModel
export WebSearchResult, WebSearchResponse, WebFetchResponse, OllamaWebSearchProvider
export OpenAIMessage, OpenAIError, OpenAITool, OpenAIToolCall, OpenAIProvider
export OpenAIModel
export OpenAIFunction, OpenAITextContent, OpenAIImageContent, OpenAIImageUrl
export ChutesProvider
export PeerComputeProvider, PeerComputeMessage, PeerComputeModel, PeerComputeResponse
export BareLibP2PProvider, BareLibP2PMessage, BareLibP2PModel, BareLibP2PResponse, BareLibP2PInferenceResponse
export start_provider, stop_provider
export GLOBAL_PROVIDER, GLOBAL_BARELIBP2P_PROVIDER
export AbstractFlootyError, ToolError

# ═══════════════════════════════════════════════════════════════════════
# Register message/model subtypes with FlootyBase for JSON deserialization
# ═══════════════════════════════════════════════════════════════════════
function __init__()
    FlootyBase.register_message_subtype!(:OllamaMessage, OllamaMessage)
    FlootyBase.register_message_subtype!(:OpenAIMessage, OpenAIMessage)
    FlootyBase.register_message_subtype!(:PeerComputeMessage, PeerComputeMessage)
    FlootyBase.register_message_subtype!(:BareLibP2PMessage, BareLibP2PMessage)
    FlootyBase.register_model_subtype!(:OllamaModel, OllamaModel)
    FlootyBase.register_model_subtype!(:OpenAIModel, OpenAIModel)
    FlootyBase.register_model_subtype!(:PeerComputeModel, PeerComputeModel)
    FlootyBase.register_model_subtype!(:BareLibP2PModel, BareLibP2PModel)
end

end # module FlootyStreams
