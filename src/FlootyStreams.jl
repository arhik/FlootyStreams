module FlootyStreams

using FlootyAbstract

# Ollama
include("ollama/types.jl")
include("ollama/tools.jl")
include("ollama/chat.jl")
include("ollama/utils.jl")
include("ollama/interface.jl")

export create_stream
export build_tool, pwd_tool, read_tool, write_tool, ls_tool
export OllamaMessage, OllamaError, OllamaTool, OllamaToolCall
export AbstractFlootyError, ToolError

end # module FlootyStreams
