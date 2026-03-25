using FlootyAbstract
using OrderedCollections

# Build OllamaTool from AbstractTool using FlootySessions interface
function FlootyAbstract.build_tool(tool::AbstractTool, provider::OllamaProvider)
    properties = OrderedDict{String,Any}()
    required = String[]
    
    # Use FlootyAbstract interface to get tool info
    # These dispatch to FlootySessions.Tool implementations
    name = FlootyAbstract.tool_name(tool)
    desc = FlootyAbstract.tool_description(tool)
    params = FlootyAbstract.tool_parameters(tool)
    
    for param in params
        properties[param.name] = OrderedDict{String,Any}(
            "type" => param.param_type,
            "description" => param.description
        )
        if param.required
            push!(required, param.name)
        end
    end
    
    params_dict = OrderedDict{String,Any}(
        "type" => "object",
        "properties" => properties,
        "required" => required
    )
    
    OllamaTool(
        "function",
        OllamaFunction(name, desc, params_dict)
    )
end
