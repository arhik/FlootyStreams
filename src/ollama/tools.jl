using FlootyAbstract
using FlootyBase: ToolParameter
using OrderedCollections
using JSON3

# Build OllamaTool from AbstractTool using FlootySessions interface
function FlootyAbstract.build_tool(tool::AbstractTool, provider::OllamaProvider)
    # Use FlootyAbstract interface to get tool info
    # These dispatch to FlootySessions.Tool implementations
    name = FlootyAbstract.tool_name(tool)
    desc = FlootyAbstract.tool_description(tool)
    params = FlootyAbstract.tool_parameters(tool)
    
    # params should be Vector{ToolParameter}
    OllamaTool(
        "function",
        OllamaFunction(name, desc, params)
    )
end

# Convert ToolParameter vector to Ollama API format (OrderedDict)
# This is used during JSON serialization
function tool_parameters_to_dict(params::Vector{ToolParameter})
    properties = OrderedDict{String,Any}()
    required = String[]
    
    for param in params
        properties[param.name] = OrderedDict{String,Any}(
            "type" => param.param_type,
            "description" => param.description
        )
        if param.required
            push!(required, param.name)
        end
    end
    
    OrderedDict{String,Any}(
        "type" => "object",
        "properties" => properties,
        "required" => required
    )
end

# Custom serialization for OllamaFunction to output OrderedDict format
# that Ollama API expects
# Note: StructType is already defined in types.jl as StructTypes.Struct()
# We override lower/construct for custom serialization

function StructTypes.lower(x::OllamaFunction)
    OrderedDict{String,Any}(
        "name" => x.name,
        "description" => x.description,
        "parameters" => tool_parameters_to_dict(x.parameters)
    )
end

function StructTypes.construct(::Type{OllamaFunction}, x::OrderedDict{String,Any})
    # Extract ToolParameter vector from the dict format
    params_dict = get(x, "parameters", OrderedDict{String,Any}())
    props = get(params_dict, "properties", OrderedDict{String,Any}())
    req_list = get(params_dict, "required", String[])
    
    params = ToolParameter[]
    for (name, info) in props
        push!(params, ToolParameter(
            name,
            get(info, "type", "string"),
            get(info, "description", ""),
            required = name in req_list
        ))
    end
    
    OllamaFunction(
        get(x, "name", ""),
        get(x, "description", ""),
        params
    )
end