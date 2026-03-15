module FlootyStreams

using FlootyAbstract
using StructTypes

# Ollama
include("ollama/types.jl")
include("ollama/tools.jl")
include("ollama/chat.jl")
include("ollama/utils.jl")
include("ollama/interface.jl")

# StructTypes configuration for AbstractMessage
StructTypes.StructType(::Type{AbstractMessage}) = StructTypes.AbstractType()
StructTypes.subtypekey(::Type{AbstractMessage}) = :_type
StructTypes.subtypes(::Type{AbstractMessage}) = (
    OllamaMessage=OllamaMessage,
)

export create_stream
export build_tool, pwd_tool, read_tool, write_tool, ls_tool
export OllamaMessage, OllamaError, OllamaTool, OllamaToolCall
export AbstractFlootyError, ToolError

end # module FlootyStreams
