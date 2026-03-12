using Test
using FlootyStreams
using FlootyAbstract: AbstractTool, tool_name, tool_description, tool_parameters, call_name, call_arguments
using JSON3
using OrderedCollections

# Create test directory and file
test_dir = mktempdir()
test_file = joinpath(test_dir, "sample.md")

sample_content = """
# Sample Markdown File

This is a test file for tool operations.

## Section 1
Line 1 of section 1
Line 2 of section 1

## Section 2
Line 1 of section 2
Line 2 of section 2

## Conclusion
Final line
"""

write(test_file, sample_content)

@testset "Tool Definitions" begin
    @testset "pwd_tool" begin
        tool = pwd_tool()
        @test tool isa AbstractTool
        @test tool_name(tool) == "pwd"

        json = JSON3.write(tool)
        parsed = JSON3.read(json)
        @test parsed.type == "function"
        @test parsed.function.name == "pwd"
        @test parsed.function.parameters.required == []
    end

    @testset "ls_tool" begin
        tool = ls_tool()
        @test tool_name(tool) == "ls"

        params = tool_parameters(tool)
        @test params["type"] == "object"
        @test "path" in keys(params["properties"])
        @test params["required"] == []
    end

    @testset "read_tool" begin
        tool = read_tool()
        @test tool_name(tool) == "read"

        params = tool_parameters(tool)
        props = params["properties"]
        @test "path" in keys(props)
        @test "start_line" in keys(props)
        @test "end_line" in keys(props)
        @test params["required"] == ["path"]
    end

    @testset "write_tool" begin
        tool = write_tool()
        @test tool_name(tool) == "write"

        params = tool_parameters(tool)
        props = params["properties"]
        @test "path" in keys(props)
        @test "content" in keys(props)
        @test "start_line" in keys(props)
        @test "end_line" in keys(props)
        @test params["required"] == ["path", "content"]
    end
end

@testset "Tool JSON Serialization" begin
    tools = [pwd_tool(), ls_tool(), read_tool(), write_tool()]

    for tool in tools
        json = JSON3.write(tool)
        @test json isa String
        @test occursin("\"type\":\"function\"", json)
        @test occursin("\"function\":{", json)
    end
end

@testset "Simulated Tool Call Parsing" begin
    @testset "pwd call" begin
        call_json = """{"function": {"name": "pwd", "arguments": {}}}"""
        call = JSON3.read(call_json, FlootyStreams.OllamaToolCall)
        @test call_name(call) == "pwd"
        @test isempty(call_arguments(call))
    end

    @testset "read call with line range" begin
        call_json = """{"function": {"name": "read", "arguments": {"path": "$(test_file)", "start_line": 3, "end_line": 5}}}"""
        call = JSON3.read(call_json, FlootyStreams.OllamaToolCall)
        @test call_name(call) == "read"
        @test call_arguments(call)["path"] == test_file
        @test call_arguments(call)["start_line"] == 3
        @test call_arguments(call)["end_line"] == 5
    end

    @testset "write call with line range" begin
        call_json = """{"function": {"name": "write", "arguments": {"path": "file.txt", "content": "new content", "start_line": 10, "end_line": 15}}}"""
        call = JSON3.read(call_json, FlootyStreams.OllamaToolCall)
        @test call_name(call) == "write"
        args = call_arguments(call)
        @test args["path"] == "file.txt"
        @test args["content"] == "new content"
        @test args["start_line"] == 10
        @test args["end_line"] == 15
    end

    @testset "ls call" begin
        call_json = """{"function": {"name": "ls", "arguments": {"path": "/home/user"}}}"""
        call = JSON3.read(call_json, FlootyStreams.OllamaToolCall)
        @test call_name(call) == "ls"
        @test call_arguments(call)["path"] == "/home/user"
    end
end

@testset "ChatRequest with Tools" begin
    msg = FlootyStreams.OllamaMessage(role="user", content="Check what files are here")
    tools = [pwd_tool(), ls_tool(), read_tool()]

    request = FlootyStreams.ChatRequest(
        model="nemotron-3-nano:30b-cloud",
        messages=[msg],
        stream=false,
        tools=tools
    )

    json = JSON3.write(request)
    @test occursin("\"tools\":[", json)
    @test occursin("\"type\":\"function\"", json)
end

# Cleanup
rm(test_dir, recursive=true)
