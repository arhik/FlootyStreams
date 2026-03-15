using OrderedCollections

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
    build_tool("pwd", "Get the current working directory path", params)
end

function read_tool()::AbstractTool
    params = OrderedDict{String,Any}(
        "type" => "object",
        "properties" => OrderedDict{String,Any}(
            "path" => OrderedDict{String,Any}(
                "type" => "string",
                "description" => "Path to the file to read"
            ),
            "start_line" => OrderedDict{String,Any}(
                "type" => "integer",
                "description" => "Starting line number (1-based indexing, inclusive). Line 1 is the first line of the file"
            ),
            "end_line" => OrderedDict{String,Any}(
                "type" => "integer",
                "description" => "Ending line number (1-based indexing, inclusive). Omit to read from start_line to end of file"
            )
        ),
        "required" => ["path"]
    )
    build_tool("read", "Read file contents. First line of file is line 1 (1-based indexing)", params)
end

function write_tool()::AbstractTool
    params = OrderedDict{String,Any}(
        "type" => "object",
        "properties" => OrderedDict{String,Any}(
            "path" => OrderedDict{String,Any}(
                "type" => "string",
                "description" => "Path to the file"
            ),
            "content" => OrderedDict{String,Any}(
                "type" => "string",
                "description" => "Content to write. When editing with line ranges, provide ONLY the replacement content"
            ),
            "start_line" => OrderedDict{String,Any}(
                "type" => "integer",
                "description" => "First line to replace (1-based indexing, inclusive). First line of file is line 1"
            ),
            "end_line" => OrderedDict{String,Any}(
                "type" => "integer",
                "description" => "Last line to replace (1-based indexing, inclusive). Omit to replace from start_line to end of file"
            )
        ),
        "required" => ["path", "content"]
    )
    build_tool("write", "Write file or replace line ranges. Line numbers are 1-based (first line is line 1). Hint: use READ first to find correct line numbers", params)
end

function ls_tool()::AbstractTool
    params = OrderedDict{String,Any}(
        "type" => "object",
        "properties" => OrderedDict{String,Any}(
            "path" => OrderedDict{String,Any}(
                "type" => "string",
                "description" => "Path to the directory to list (optional, defaults to current directory)"
            )
        ),
        "required" => String[]
    )
    build_tool("ls", "List files and directories", params)
end

function shell_tool()::AbstractTool
    params = OrderedDict{String,Any}(
        "type" => "object",
        "properties" => OrderedDict{String,Any}(
            "command" => OrderedDict{String,Any}(
                "type" => "string",
                "description" => "Shell command to execute: ls, pwd, cd, grep, cat, etc."
            ),
            "args" => OrderedDict{String,Any}(
                "type" => "array",
                "items" => OrderedDict{String,Any}("type" => "string"),
                "description" => "Command arguments (optional)"
            )
        ),
        "required" => ["command"]
    )
    build_tool("shell", "Execute shell command and return output", params)
end

# Tool Handlers Implementation with stdout capture

using IOCapture

function handle_pwd(args::Dict{String,Any}; context=nothing)
    c = IOCapture.capture() do
        println(pwd())
    end
    FlootyAbstract.ToolResult(c.output)
end

function handle_ls(args::Dict{String,Any}; context=nothing)
    path = get(args, "path", pwd())
    if !isdir(path)
        return FlootyAbstract.ToolResult(false, "", "Not a directory: $path")
    end
    
    c = IOCapture.capture() do
        # Use ls -l on Unix for detailed listing
        @static if Sys.isunix()
            run(`ls -l $path`)
        else
            # Fallback for Windows
            for file in readdir(path)
                println(file)
            end
        end
    end
    FlootyAbstract.ToolResult(c.output)
end

function handle_shell(args::Dict{String,Any}; context=nothing)
    command = args["command"]
    
    c = IOCapture.capture() do
        try
            run(`sh -c $command`)
        catch e
            println(stderr, "Error: $e")
        end
    end
    
    FlootyAbstract.ToolResult(c.output)
end

function handle_read(args::Dict{String,Any}; context=nothing)
    path = args["path"]
    if !isfile(path)
        return FlootyAbstract.ToolResult(false, "", "File not found: $path")
    end
    
    c = IOCapture.capture() do
        start_line = get(args, "start_line", nothing)
        end_line = get(args, "end_line", nothing)
        
        if start_line === nothing
            # Read entire file
            print(read(path, String))
        else
            # Read specific lines
            lines = readlines(path)
            start_idx = max(1, start_line)
            end_idx = end_line === nothing ? length(lines) : min(end_line, length(lines))
            for line in lines[start_idx:end_idx]
                println(line)
            end
        end
    end
    
    FlootyAbstract.ToolResult(c.output)
end

function handle_write(args::Dict{String,Any}; context=nothing)
    path = args["path"]
    content = args["content"]
    
    c = IOCapture.capture() do
        start_line = get(args, "start_line", nothing)
        end_line = get(args, "end_line", nothing)
        
        if start_line === nothing
            # Write entire file
            write(path, content)
            println("Written to $path")
        else
            # Replace specific lines
            if !isfile(path)
                println(stderr, "File not found for editing: $path")
                return
            end
            lines = readlines(path)
            start_idx = max(1, start_line)
            end_idx = end_line === nothing ? length(lines) : min(end_line, length(lines))
            new_content_lines = split(content, '\n')
            new_lines = vcat(lines[1:start_idx-1], new_content_lines, lines[end_idx+1:end])
            write(path, join(new_lines, "\n"))
            println("Updated $path")
        end
    end
    
    FlootyAbstract.ToolResult(c.output)
end

function __init__()
    FlootyAbstract.register_tool_handler!("pwd", handle_pwd)
    FlootyAbstract.register_tool_handler!("ls", handle_ls)
    FlootyAbstract.register_tool_handler!("read", handle_read)
    FlootyAbstract.register_tool_handler!("write", handle_write)
    FlootyAbstract.register_tool_handler!("shell", handle_shell)
end