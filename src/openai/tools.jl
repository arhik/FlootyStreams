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

function StructTypes.lower(x::OpenAIFunction)
    if x.arguments !== nothing
        OrderedDict{String,Any}(
            "name" => x.name,
            "arguments" => x.arguments
        )
    else
        OrderedDict{String,Any}(
            "name" => x.name,
            "description" => x.description,
            "parameters" => x.parameters
        )
    end
end

function StructTypes.construct(::Type{OpenAIFunction}, x::OrderedDict{String,Any})
    name = get(x, "name", "")
    if haskey(x, "arguments")
        args_str = x["arguments"]
        args_dict = try JSON3.read(args_str, OrderedDict{String,Any}) catch _ OrderedDict{String,Any}() end
        return OpenAIFunction(name, nothing, args_dict, args_str)
    else
        params_dict = get(x, "parameters", OrderedDict{String,Any}())
        props = get(params_dict, "properties", OrderedDict{String,Any}())
        req_list = get(params_dict, "required", String[])
        
        params = ToolParameter[]
        for (n, info) in props
            push!(params, ToolParameter(
                n,
                get(info, "type", "string"),
                get(info, "description", ""),
                required = n in req_list
            ))
        end
        
        parameters = OrderedDict{String,Any}(
            "type" => "object",
            "properties" => props,
            "required" => req_list
        )
        
        return OpenAIFunction(name, get(x, "description", nothing), parameters, nothing)
    end
end
