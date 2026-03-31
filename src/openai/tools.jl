using FlootyAbstract
using FlootyBase: ToolParameter
using OrderedCollections
using JSON3

# Build OpenAITool from AbstractTool using FlootySessions interface
function FlootyAbstract.build_tool(tool::AbstractTool, provider::OpenAIProvider)
    # Use FlootyAbstract interface to get tool info
    name = FlootyAbstract.tool_name(tool)
    desc = FlootyAbstract.tool_description(tool)
    params = FlootyAbstract.tool_parameters(tool)
    
    # params should be Vector{ToolParameter}
    parameters = openai_tool_parameters_to_dict(params)
    
    OpenAITool(
        "function",
        OpenAIFunction(name, desc, parameters)
    )
end

# Convert ToolParameter vector to OpenAI API format (OrderedDict)
function openai_tool_parameters_to_dict(params::Vector{ToolParameter})
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

# Also accept OrderedDict for OpenAI (which already stores params as OrderedDict)
function openai_tool_parameters_to_dict(params::OrderedDict{String,Any})
    params
end

# Custom serialization for OpenAIFunction to output OrderedDict format
# that OpenAI API expects
function StructTypes.lower(x::OpenAIFunction)
    OrderedDict{String,Any}(
        "name" => x.name,
        "description" => x.description,
        "parameters" => x.parameters
    )
end

function StructTypes.construct(::Type{OpenAIFunction}, x::OrderedDict{String,Any})
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
    
    parameters = OrderedDict{String,Any}(
        "type" => "object",
        "properties" => props,
        "required" => req_list
    )
    
    OpenAIFunction(
        get(x, "name", ""),
        get(x, "description", ""),
        parameters
    )
end
