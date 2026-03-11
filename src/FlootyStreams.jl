module FlootyStreams

using FlootyAbstract

# Ollama
include("ollama/types.jl")
include("ollama/chat.jl")
include("ollama/utils.jl")
include("ollama/interface.jl")

export create_message, create_provider_instance, create_stream

end # module FlootyStreams
