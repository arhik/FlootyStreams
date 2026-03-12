using FlootyStreams
using FlootyStreams: OllamaMessage, ChatRequest, OllamaProvider
using FlootyAbstract: create_message, execute_tool, ToolResult

# Setup
provider = OllamaProvider()

# Create initial document at known location
test_file = "/tmp/project_plan.md"
initial_content = """# Project Plan

## Overview
This is the initial overview section.

## Requirements
- Feature A
- Feature B

## Timeline
Week 1: Setup
Week 2: Development
"""

# Execute write tool to create file
write_result = execute_tool("write", Dict{String,Any}("path" => test_file, "content" => initial_content))
@assert write_result.success "Failed to create initial file"

# Verify file was created with read tool
read_result = execute_tool("read", Dict{String,Any}("path" => test_file))
@assert read_result.success
@assert contains(read_result.data, "Week 1: Setup")

# Edit the Timeline section (lines 11-12) using write with line range
new_timeline = """## Timeline
Week 1: Planning and Setup
Week 2: Core Development
Week 3: Testing"""

edit_result = execute_tool("write", Dict{String,Any}(
    "path" => test_file,
    "content" => new_timeline,
    "start_line" => 11,
    "end_line" => 12
))
@assert edit_result.success "Failed to edit file"

# Read back to verify changes
final_result = execute_tool("read", Dict{String,Any}("path" => test_file))
@assert final_result.success

# Verify the Timeline section was updated
@assert contains(final_result.data, "Week 1: Planning and Setup")
@assert contains(final_result.data, "Week 2: Core Development")
@assert contains(final_result.data, "Week 3: Testing")

# Also test pwd and ls tools
pwd_result = execute_tool("pwd", Dict{String,Any}())
@assert pwd_result.success

ls_result = execute_tool("ls", Dict{String,Any}("path" => "/tmp"))
@assert ls_result.success
@assert contains(ls_result.data, "project_plan.md")

# Read specific line range
section_result = execute_tool("read", Dict{String,Any}(
    "path" => test_file,
    "start_line" => 1,
    "end_line" => 3
))
@assert section_result.success
@assert startswith(section_result.data, "# Project Plan")
