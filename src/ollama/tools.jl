
function build_tool(name::String, description::String, parameters::OrderedDict)::AbstractTool
    OllamaTool(
        "function",
        OllamaFunction(name, description, parameters)
    )
end

function pwd_tool()::AbstractTool
    params = OrderedDict{String,Any}(
        "type" => "object",
        "properties" => OrderedDict{String,Any}(),
        "required" => String[]
    )

    build_tool(
        "pwd",
        "Get the current working directory path",
        params
    )
end
