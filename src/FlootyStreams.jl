module FlootyStreams

using FlootyAbstract
using FlootyBase
using StructTypes

# Ollama
include("ollama/types.jl")
include("ollama/tools.jl")
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

# StructTypes configuration for AbstractMessage
StructTypes.StructType(::Type{AbstractMessage}) = StructTypes.AbstractType()
StructTypes.subtypekey(::Type{AbstractMessage}) = :_type
StructTypes.subtypes(::Type{AbstractMessage}) = (
    OllamaMessage=OllamaMessage,
    OpenAIMessage=OpenAIMessage,
)

# StructTypes configuration for AbstractModel
StructTypes.StructType(::Type{AbstractModel}) = StructTypes.AbstractType()
StructTypes.subtypekey(::Type{AbstractModel}) = :_type
StructTypes.subtypes(::Type{AbstractModel}) = (
    OllamaModel=OllamaModel,
    OpenAIModel=OpenAIModel,
)

export create_stream
export OllamaMessage, OllamaError, OllamaTool, OllamaToolCall, ImageAttachment
export OllamaModel
export OpenAIMessage, OpenAIError, OpenAITool, OpenAIToolCall, OpenAIProvider
export OpenAIModel
export OpenAIFunction, OpenAITextContent, OpenAIImageContent, OpenAIImageUrl
export ChutesProvider
export AbstractFlootyError, ToolError

end # module FlootyStreams
