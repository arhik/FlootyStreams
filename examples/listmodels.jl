using FlootyStreams
using FlootyAbstract: list_provider_models, model_name

models = list_provider_models(:ollama, Dict{Symbol,Any}())

for (i, model) in enumerate(models)
    println(i, ". ", model_name(model))
end
