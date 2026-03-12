# ═══════════════════════════════════════════════════════════════════════
# Flooty Chat TUI with Tool Support
#
# Type your message at the bottom and press Enter to send.
# Supports tool calls: pwd, ls, read, write with retry logic.
# Use Ctrl+C or Esc to quit.
# ═══════════════════════════════════════════════════════════════════════

using Tachikoma
using FlootyStreams
using FlootyContextManager
using FlootyAbstract: create_provider_instance, create_message, execute_tool, call_name, call_arguments, ToolError, AbstractFlootyError
using FlootyStreams: pwd_tool, ls_tool, read_tool, write_tool
using CommonMark
using Dates
using JSON3

@tachikoma_app

# Styles
const GREY_TEXT = Style(fg=Color256(245))
const GREY_DIM = Style(fg=Color256(239))
const USER_HANDLE = Style(fg=ColorRGB(60, 60, 60))
const USER_BG_COLOR = ColorRGB(80, 80, 80)
const ASSISTANT_HANDLE = Style(fg=ColorRGB(120, 120, 120))
const SYSTEM_HANDLE = Style(fg=ColorRGB(220, 150, 100))
const META_STYLE = Style(fg=Color256(242), italic=true)
const SEPARATOR = Style(fg=Color256(239))
const SCROLLBAR_TRACK = Style(fg=Color256(240))
const SCROLLBAR_THUMB = Style(fg=Color256(250))

const TOOL_HANDLE = Style(fg=ColorRGB(100, 200, 100))  # Green for tools
const TOOL_BG_COLOR = ColorRGB(40, 60, 40)

using FlootyAbstract: AbstractMessage, role, content, error_message

# Tool configuration
const MAX_TOOL_RETRIES = 3
const MAX_TOOL_ITERATIONS = 10
const TOOLS = [pwd_tool(), ls_tool(), read_tool(), write_tool()]

"""
Chat message widget with support for tool messages
"""
mutable struct ChatMessageWidget
    message::AbstractMessage
    timestamp::DateTime
    model::String
    width::Int
    md_pane::Union{MarkdownPane, Nothing}
    lines::Vector{String}
    total_height::Int
    is_tool_result::Bool

    function ChatMessageWidget(msg::AbstractMessage, model::String, width::Int, tick::Int=0; is_tool_result::Bool=false)
        ts = now()
        msg_content = content(msg)
        msg_role = role(msg)

        if is_tool_result
            # Tool results: plain text
            wrapped_lines = String[msg_content]
            total = 1 + length(wrapped_lines)
            new(msg, ts, model, width, nothing, wrapped_lines, total, true)
        elseif msg_role == "user"
            wrapped_lines = String[]
            for para in split(msg_content, '\n', keepempty=false)
                wrapped = _word_wrap(para, width-2)
                append!(wrapped_lines, wrapped)
                push!(wrapped_lines, "")
            end
            isempty(wrapped_lines) && (wrapped_lines = ["(empty)"])
            content_lines = min(10, length(wrapped_lines))
            total = 1 + content_lines
            new(msg, ts, model, width, nothing, wrapped_lines, total, false)
        else
            md_pane = MarkdownPane(msg_content; width=width-4, block=nothing, show_scrollbar=true)
            lines_count = count(c -> c == '\n', msg_content) + 1
            estimated_lines = max(1, div(length(msg_content), div(width-4, 6)) + lines_count)
            content_lines = min(10, estimated_lines)
            total = 1 + content_lines
            new(msg, ts, model, width, md_pane, String[], total, false)
        end
    end
end

function _word_wrap(text::AbstractString, width::Int)
    words = split(text, r"\s+", keepempty=false)
    lines = String[]
    current = ""
    for word in words
        if isempty(current)
            current = word
        elseif length(current) + 1 + length(word) <= width
            current *= " " * word
        else
            push!(lines, current)
            current = word
        end
    end
    !isempty(current) && push!(lines, current)
    isempty(lines) && push!(lines, "")
    return lines
end

@kwdef mutable struct ChatModel <: Model
    quit::Bool = false
    tick::Int = 0
    provider = create_provider_instance(:ollama)
    store::ContextStore = ContextStore()
    input::TextInput = TextInput(text="", focused=true, tick=0)
    task_queue::TaskQueue = TaskQueue()
    model_name::String = "nemotron-3-nano:30b-cloud"
    is_streaming::Bool = false
    message_widgets::Vector{ChatMessageWidget} = ChatMessageWidget[]
    scroll_offset::Int = 0
    focus::Int = 2
    auto_scroll::Bool = true
    tool_iteration::Int = 0
end

should_quit(m::ChatModel) = m.quit
task_queue(m::ChatModel) = m.task_queue

function update!(m::ChatModel, evt::Event)
    if evt isa KeyEvent
        _handle_key!(m, evt)
    elseif evt isa TaskEvent
        _handle_task_event!(m, evt)
    end
end

function _handle_key!(m::ChatModel, evt::KeyEvent)
    if (evt.key == :char && evt.char == '\x03') || evt.key == :escape
        m.quit = true
        return
    end

    if evt.key == :tab
        m.focus = m.focus == 1 ? 2 : 1
        m.input.focused = (m.focus == 2)
        return
    end

    if evt.key == :page_up
        m.scroll_offset = max(0, m.scroll_offset - 5)
        return
    elseif evt.key == :page_down
        m.scroll_offset += 5
        return
    end

    if m.focus == 1
        if evt.key == :up
            m.scroll_offset = max(0, m.scroll_offset - 1)
            return
        elseif evt.key == :down
            m.scroll_offset += 1
            return
        end
    end

    if m.focus == 2
        handled = handle_key!(m.input, evt)
        if !handled && (String(m.input.buffer) |> strip |> !isempty) &&
           (evt.key == :enter || (evt.key == :char && evt.char == '\n'))
            _send_message!(m)
        end
    end

    if evt.key == :char && isprint(evt.char) && m.focus == 1
        m.focus = 2
        m.input.focused = true
        handle_key!(m.input, evt)
    end
end

function _execute_tool_with_retry(tool_name_str::String, args::Dict; max_retries::Int=MAX_TOOL_RETRIES)
    for attempt in 1:max_retries
        result = execute_tool(tool_name_str, args)
        if result.success
            return result
        end
        @warn "Tool $tool_name_str failed (attempt $attempt/$max_retries): $(result.error)"
        if attempt == max_retries
            return result
        end
    end
    return execute_tool(tool_name_str, args)  # Final attempt
end

function _handle_tool_calls!(m::ChatModel, tool_calls)
    for tc in tool_calls
        tool_name_str = call_name(tc)
        args = call_arguments(tc)
        
        # Add tool call message
        tool_call_msg = create_message(m.provider, "assistant", 
            "🔧 Calling tool: $tool_name_str with args: $(JSON3.write(args))")
        add_message!(m.store, tool_call_msg)
        _update_widgets!(m)
        
        # Execute tool with retry
        result = _execute_tool_with_retry(tool_name_str, args)
        
        if !result.success
            tool_result_content = "Tool failed after $MAX_TOOL_RETRIES retries: $(result.error)"
        else
            tool_result_content = result.data
        end
        
        # Add tool result as tool role message
        tool_msg = create_message(m.provider, "tool", tool_result_content)
        add_message!(m.store, tool_msg)
        _update_widgets!(m)
    end
    
    # Continue conversation with tools
    m.tool_iteration += 1
    if m.tool_iteration >= MAX_TOOL_ITERATIONS
        throw(ToolError("Max tool iterations reached", "conversation"))
    end
    
    context = get_messages(m.store)
    spawn_task!(m.task_queue, :chat) do
        FlootyStreams.chat(m.provider, context, m.model_name, 
            false, nothing, nothing, TOOLS)
    end
end

function _handle_task_event!(m::ChatModel, evt::TaskEvent)
    if evt.id == :chat
        try
            if evt.value isa Exception
                throw(evt.value)
            end
            
            response = evt.value
            
            if response isa FlootyStreams.OllamaError
                throw(ToolError(error_message(response), "ollama"))
            end
            
            if hasproperty(response, :message)
                # Add assistant response
                add_message!(m.store, response.message)
                _update_widgets!(m)
                
                # Handle tool calls if present
                if response.message.tool_calls !== nothing && !isempty(response.message.tool_calls)
                    _handle_tool_calls!(m, response.message.tool_calls)
                    return  # Continue in tool mode
                end
            else
                add_message!(m.store, create_message(m.provider, "system", "Unexpected response: $response"))
            end
            
            m.is_streaming = false
            m.tool_iteration = 0
            _update_widgets!(m)
            
        catch e
            if e isa ToolError
                add_message!(m.store, create_message(m.provider, "system", 
                    "❌ $(error_message(e))"))
            else
                add_message!(m.store, create_message(m.provider, "system", 
                    "Error: $e"))
            end
            m.is_streaming = false
            m.tool_iteration = 0
            _update_widgets!(m)
        end
    end
end

function _send_message!(m::ChatModel)
    text = String(strip(String(m.input.buffer)))
    isempty(text) && return

    add_message!(m.store, create_message(m.provider, "user", text))
    empty!(m.input.buffer)
    m.input.cursor = 0
    _update_widgets!(m)

    m.is_streaming = true
    m.tool_iteration = 0
    context = get_messages(m.store)
    
    spawn_task!(m.task_queue, :chat) do
        FlootyStreams.chat(m.provider, context, m.model_name, 
            false, nothing, nothing, TOOLS)
    end
end

function _update_widgets!(m::ChatModel)
    m.message_widgets = ChatMessageWidget[]
    
    for msg in get_messages(m.store)
        # Check if this is a tool result by checking role
        is_tool = role(msg) == "tool"
        widget = ChatMessageWidget(msg, m.model_name, 80, m.tick; is_tool_result=is_tool)
        push!(m.message_widgets, widget)
    end
    
    m.auto_scroll = true
end

function render_message!(buf::Buffer, widget::ChatMessageWidget, area::Rect, y_offset::Int, tick::Int)
    handle = if widget.is_tool_result
        TOOL_HANDLE
    elseif role(widget.message) == "system"
        SYSTEM_HANDLE
    elseif role(widget.message) == "user"
        USER_HANDLE
    else
        ASSISTANT_HANDLE
    end

    ts_str = Dates.format(widget.timestamp, "HH:MM")
    prefix = widget.is_tool_result ? "[TOOL] " : ""
    meta = prefix * (role(widget.message) == "assistant" ? "$(ts_str) · $(widget.model)" : ts_str)

    meta_y = area.y + y_offset
    if meta_y <= bottom(area) && meta_y >= area.y
        set_char!(buf, area.x, meta_y, '▌', handle)
        set_string!(buf, area.x + 2, meta_y, meta, GREY_DIM; max_x=right(area) - 2)
    end

    content_y = meta_y + 1
    has_content = widget.is_tool_result ? !isempty(widget.lines) : (widget.md_pane !== nothing)

    if has_content && content_y <= bottom(area)
        content_area = Rect(area.x + 2, content_y, area.width - 3, widget.total_height - 1)

        if widget.is_tool_result
            # Tool results with green background
            tool_style = Style(fg=ColorRGB(150, 255, 150), bg=TOOL_BG_COLOR)
            for (i, line) in enumerate(widget.lines)
                y = content_y + i - 1
                y > bottom(area) && break
                if y >= area.y
                    for x in area.x + 2:right(area)
                        set_char!(buf, x, y, ' ', Style(bg=TOOL_BG_COLOR))
                    end
                    set_string!(buf, area.x + 2, y, line, tool_style; max_x=right(area))
                end
            end
        elseif role(widget.message) == "user"
            user_bg = Style(bg=USER_BG_COLOR)
            user_text = Style(fg=ColorRGB(255, 255, 255), bg=USER_BG_COLOR)
            for (i, line) in enumerate(widget.lines)
                y = content_y + i - 1
                y > bottom(area) && break
                if y >= area.y
                    for x in area.x + 2:right(area)
                        set_char!(buf, x, y, ' ', user_bg)
                    end
                    set_string!(buf, area.x + 2, y, line, user_text; max_x=right(area))
                end
            end
        elseif widget.md_pane !== nothing
            for y in content_y:min(bottom(area), content_y + widget.total_height - 2)
                if y >= area.y
                    set_char!(buf, area.x, y, '▌', handle)
                end
            end
            render(widget.md_pane, content_area, buf)
        end
    end

    return widget.total_height
end

# Forward declarations for view function
_view_layout(m::ChatModel, f::Frame) = begin
    input_height = 3
    separator_height = 1
    chat_height = max(0, f.area.height - input_height - separator_height)
    
    chat_area = Rect(f.area.x, f.area.y, f.area.width, chat_height)
    separator_y = chat_area.y + chat_height
    input_area = Rect(f.area.x, separator_y + separator_height, f.area.width, input_height)
    
    return (chat_area, separator_y, input_area)
end

function view(m::ChatModel, f::Frame)
    m.tick += 1
    m.input.tick = m.tick
    buf = f.buffer

    chat_area, separator_y, input_area = _view_layout(m, f)

    # Update widget widths
    total_height = 0
    for widget in m.message_widgets
        widget.width = chat_area.width
        if widget.is_tool_result
            widget.total_height = 1 + length(widget.lines)
        elseif role(widget.message) == "user"
            widget.lines = String[]
            for para in split(content(widget.message), '\n', keepempty=false)
                wrapped = _word_wrap(para, widget.width-2)
                append!(widget.lines, wrapped)
                push!(widget.lines, "")
            end
            isempty(widget.lines) && (widget.lines = ["(empty)"])
            widget.total_height = 1 + min(10, length(widget.lines))
        elseif widget.md_pane !== nothing
            msg_content = content(widget.message)
            widget.md_pane = MarkdownPane(msg_content; width=widget.width-4, block=nothing, show_scrollbar=true)
            lines_count = count(c -> c == '\n', msg_content) + 1
            estimated = max(1, div(length(msg_content), div(widget.width-4, 6)) + lines_count)
            widget.total_height = 1 + min(10, estimated)
        end
        total_height += widget.total_height
    end

    # Auto-scroll
    if m.auto_scroll
        visible_height = chat_area.height
        m.scroll_offset = total_height > visible_height ? total_height - visible_height : 0
        m.auto_scroll = false
    end

    # Render chat
    _render_chat_messages!(m, buf, chat_area)

    # Focus handle
    focus_handle = Style(fg=ColorRGB(200, 200, 200))
    focus_area = m.focus == 1 ? chat_area : input_area
    for y in focus_area.y:bottom(focus_area)
        set_char!(buf, focus_area.x, y, '▌', focus_handle)
    end

    # Separator
    for x in f.area.x:(f.area.x + f.area.width - 1)
        set_char!(buf, x, separator_y, '─', SEPARATOR)
    end

    # Input area
    _render_input_area!(m, buf, input_area)

    # Status bar
    status_text = m.is_streaming ? "Streaming..." : "$(m.model_name) | Tools: pwd, ls, read, write | Ctrl+C to quit"
    focus_hint = m.focus == 1 ? " [Tab: input] " : " [Tab: chat] "
    status_text *= focus_hint
    status_x = input_area.x + max(0, (input_area.width - length(status_text)) ÷ 2)
    set_string!(buf, status_x, input_area.y + input_area.height - 1, status_text, GREY_TEXT)
end

function _render_chat_messages!(m::ChatModel, buf::Buffer, area::Rect)
    scrollbar_width = 1
    content_area = Rect(area.x, area.y, area.width - scrollbar_width, area.height)

    total_height = sum(w.total_height for w in m.message_widgets; init=0)
    visible_height = content_area.height
    scrollable = max(0, total_height - visible_height)
    m.scroll_offset = clamp(m.scroll_offset, 0, scrollable)

    current_y = content_area.y - m.scroll_offset

    for widget in m.message_widgets
        widget_bottom = current_y + widget.total_height
        widget_top = current_y

        widget_bottom < content_area.y && (current_y = widget_bottom; continue)
        widget_top > bottom(content_area) && break

        render_message!(buf, widget, content_area, current_y - content_area.y, m.tick)
        current_y = widget_bottom
    end

    # Scrollbar
    if total_height > visible_height
        thumb_ratio = visible_height / total_height
        thumb_height = max(1, round(Int, visible_height * thumb_ratio))
        scroll_progress = m.scroll_offset / scrollable
        thumb_pos = round(Int, scroll_progress * (visible_height - thumb_height))
        
        track_x = right(area)
        for y in area.y:bottom(area)
            set_char!(buf, track_x, y, '│', SCROLLBAR_TRACK)
        end
        for i in 0:(thumb_height-1)
            thumb_y = area.y + thumb_pos + i
            if thumb_y <= bottom(area)
                set_char!(buf, track_x, thumb_y, '█', SCROLLBAR_THUMB)
            end
        end
    end
end

function _render_input_area!(m::ChatModel, buf::Buffer, area::Rect)
    input_h = area.height - 1
    input_h > 0 || return

    prompt = "› "
    set_string!(buf, area.x, area.y, prompt, GREY_DIM)

    input_area_inner = Rect(area.x + 2, area.y, area.width - 2, input_h)
    m.input.focused = true
    m.input.tick = m.tick
    render(m.input, input_area_inner, buf)
end

function flooty_chat(; model_name::String="nemotron-3-nano:30b-cloud", theme_name=nothing)
    theme_name !== nothing && set_theme!(theme_name)
    model = ChatModel(model_name=model_name)
    add_message!(model.store, create_message(model.provider, "system", 
        "You are a helpful assistant with file tools. Use pwd, ls, read, write with 1-based line numbers."))
    _update_widgets!(model)
    app(model; fps=30)
end

# Run with: flooty_chat()
