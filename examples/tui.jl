# ═══════════════════════════════════════════════════════════════════════
# Flooty Chat TUI ── Clean terminal UI for FlootyStreams chat
#
# Type your message at the bottom and press Enter to send.
# Messages appear in the scrollable chat area above.
# Use Ctrl+C or Esc to quit.
# ═══════════════════════════════════════════════════════════════════════

using Tachikoma
using FlootyStreams
using FlootyContextManager
using FlootyAbstract: create_provider_instance, create_message
using CommonMark
using FlootyStreams: OllamaMessage, OllamaProvider, chat, OllamaError

using Dates

@tachikoma_app

# Color definitions - handles use foreground colors, no backgrounds
const GREY_TEXT = Style(fg=Color256(245))
const GREY_DIM = Style(fg=Color256(239))

# Handle colors (left side indicators) - foreground only for transparency
const USER_HANDLE = Style(fg=ColorRGB(60, 60, 60))           # Dark grey
const USER_BG_COLOR = ColorRGB(80, 80, 80)                   # Slightly lighter for background
const ASSISTANT_HANDLE = Style(fg=ColorRGB(120, 120, 120))   # Light grey (no background)
const SYSTEM_HANDLE = Style(fg=ColorRGB(220, 150, 100))      # Orange

const META_STYLE = Style(fg=Color256(242), italic=true)
const SEPARATOR = Style(fg=Color256(239))

# Scrollbar styles
const SCROLLBAR_TRACK = Style(fg=Color256(240))
const SCROLLBAR_THUMB = Style(fg=Color256(250))

# Import FlootyAbstract interface functions for message access
using FlootyAbstract: AbstractMessage, role, content

"""
Chat message widget with markdown rendering via MarkdownPane
"""
mutable struct ChatMessageWidget
    message::AbstractMessage
    timestamp::DateTime
    model::String
    width::Int
    md_pane::Union{MarkdownPane, Nothing}  # Markdown rendering pane (assistant/system only)
    lines::Vector{String}                   # Plain text lines (user only)
    total_height::Int

    function ChatMessageWidget(msg::AbstractMessage, model::String, width::Int, tick::Int=0)
        ts = now()
        msg_content = content(msg)
        msg_role = role(msg)

        if msg_role == "user"
            # User messages: plain text with word wrapping - compute actual lines first
            wrapped_lines = String[]
            for para in split(msg_content, '\n', keepempty=false)
                wrapped = _word_wrap(para, width-2)
                append!(wrapped_lines, wrapped)
                push!(wrapped_lines, "")  # Paragraph break
            end
            if isempty(wrapped_lines)
                wrapped_lines = ["(empty)"]
            end
            # Height = 1 for metadata + actual wrapped lines (capped at 10)
            content_lines = min(10, length(wrapped_lines))
            total = 1 + content_lines
            new(msg, ts, model, width, nothing, wrapped_lines, total)
        else
            # Assistant/system: MarkdownPane for rich rendering
            md_pane = MarkdownPane(msg_content; width=width-4, block=nothing, show_scrollbar=true)
            # Estimate content lines (MarkdownPane manages its own rendering)
            lines_count = count(c -> c == '\n', msg_content) + 1
            content_lines = min(10, lines_count)
            # Height = 1 for metadata + estimated content lines
            total = 1 + content_lines
            new(msg, ts, model, width, md_pane, String[], total)
        end
    end
end



"""
Simple word wrapping for user messages
"""
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
    
    if !isempty(current)
        push!(lines, current)
    end
    
    isempty(lines) && push!(lines, "")
    return lines
end

"""
Get style for message based on role
"""
function _message_style(msg::OllamaMessage)
    if msg.role == "system"
        return ORANGE_BG
    elseif msg.role == "user"
        return USER_BG
    elseif msg.role == "assistant"
        return VIOLET_BG
    else
        return GREY_BG
    end
end

"""
Render a chat message widget
"""
function render_message!(buf::Buffer, widget::ChatMessageWidget, area::Rect, y_offset::Int, tick::Int)
    # Set tick on the markdown pane for proper rendering
    # Get handle style based on role
    handle = if role(widget.message) == "system"
        SYSTEM_HANDLE
    elseif role(widget.message) == "user"
        USER_HANDLE
    else
        ASSISTANT_HANDLE
    end

    # Calculate metadata - just timestamp and model (no role label)
    ts_str = Dates.format(widget.timestamp, "HH:MM")
    meta = role(widget.message) == "assistant" ? "$(ts_str) · $(widget.model)" : ts_str

    # Calculate message bounds
    meta_y = area.y + y_offset
    message_bottom = meta_y + widget.total_height - 1

    # Draw handle and metadata for all messages (aligned)
    if meta_y <= bottom(area) && meta_y >= area.y
        # Draw handle on left side for all messages
        set_char!(buf, area.x, meta_y, '▌', handle)
        # Draw metadata with consistent padding (x + 2)
        set_string!(buf, area.x + 2, meta_y, meta, GREY_DIM;
                   max_x=right(area) - 2)
    end

    # Render message content
    content_y = meta_y + 1
    has_content = if role(widget.message) == "user"
        !isempty(widget.lines)
    else
        widget.md_pane !== nothing
    end

    if has_content && content_y <= bottom(area)
        # Calculate available height for this message (max 10 lines)
        available_height = bottom(area) - content_y + 1
        available_height = min(10, max(1, available_height))  # Limit to 10 lines, ensure at least 1

        # Calculate actual content height based on widget's content
        actual_content_height = if role(widget.message) == "user"
            min(length(widget.lines), available_height)
        else
            # For assistant/system, estimate based on content length
            lines_count = count(c -> c == '\n', content(widget.message)) + 1
            words = length(split(content(widget.message)))
            avg_chars_per_line = div(area.width-4, 6)
            estimated_lines = max(1, div(length(content(widget.message)), avg_chars_per_line) + lines_count)
            min(estimated_lines, available_height)
        end
        content_bottom = min(bottom(area), content_y + actual_content_height - 1)

        # Draw handle and background for content lines (only where there's actual content)
        # All messages get a handle on the left side for visual consistency
        if role(widget.message) == "user"
            # User message - handle + background with padding
            user_bg = Style(bg=USER_BG_COLOR)
            lines_to_render = min(length(widget.lines), available_height)
            for i in 1:lines_to_render
                y = content_y + i - 1
                if y >= area.y && y <= bottom(area)
                    # Draw handle
                    set_char!(buf, area.x, y, '▌', handle)
                    # Fill background with padding (indented past handle)
                    for x in area.x + 2:right(area)
                        set_char!(buf, x, y, ' ', user_bg)
                    end
                end
            end
        else
            # Assistant/system - just draw handle where content exists, no background
            for y in content_y:content_bottom
                if y >= area.y
                    set_char!(buf, area.x, y, '▌', handle)
                end
            end
        end

        # Create inner area for content with consistent padding (indented past handle)
        content_area = Rect(area.x + 2, content_y, area.width - 3, actual_content_height)


        if role(widget.message) == "user"
            # User message: render plain text with grey background and padding
            user_bg = Style(bg=USER_BG_COLOR)
            user_text_style = Style(fg=ColorRGB(255, 255, 255), bg=USER_BG_COLOR)

            lines_to_render = min(length(widget.lines), available_height)
            for i in 1:lines_to_render
                line = widget.lines[i]
                line_y = content_y + i - 1
                line_y > bottom(area) && break

                if line_y >= area.y
                    # Draw text with padding (indented past handle)
                    set_string!(buf, area.x + 2, line_y, line, user_text_style;
                               max_x=right(area))
                end
            end
        elseif widget.md_pane !== nothing
            # Assistant/system: render markdown pane
            render(widget.md_pane, content_area, buf)
        end
    end

    # Return actual rendered height (metadata + actual content), not widget.total_height
    # This prevents empty gaps between messages
    rendered_height = if widget.md_pane !== nothing
        1 + actual_content_height
    else
        widget.total_height  # For user messages, use calculated total
    end
    return rendered_height


end

@kwdef mutable struct ChatModel <: Model
    quit::Bool = false
    tick::Int = 0
    provider = create_provider_instance(:ollama)
    store::ContextStore = ContextStore()
    input::TextInput = TextInput(text="", focused=true, tick=0)
    task_queue::TaskQueue = TaskQueue()
    model_name::String = "qwen2.5:0.5b"
    is_streaming::Bool = false

    # Chat display state
    message_widgets::Vector{ChatMessageWidget} = ChatMessageWidget[]
    scroll_offset::Int = 0
    focus::Int = 2  # 1 = chat focused, 2 = input focused
    auto_scroll::Bool = true  # scroll to bottom on new messages
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
    # Ctrl+C or Esc to quit
    if (evt.key == :char && evt.char == '\x03') || evt.key == :escape
        m.quit = true
        return
    end

    # Tab to switch focus between chat and input
    if evt.key == :tab
        m.focus = m.focus == 1 ? 2 : 1
        m.input.focused = (m.focus == 2)
        return
    end

    # Page Up/Down scrolls chat in any mode
    if evt.key == :page_up
        m.scroll_offset = max(0, m.scroll_offset - 5)
        return
    elseif evt.key == :page_down
        m.scroll_offset += 5
        return
    end

    # Arrow keys scroll only when chat is focused
    if m.focus == 1
        if evt.key == :up
            m.scroll_offset = max(0, m.scroll_offset - 1)
            return
        elseif evt.key == :down
            m.scroll_offset += 1
            return
        end
    end

    # Handle input only when input is focused
    if m.focus == 2
        handled = handle_key!(m.input, evt)

        # Send message on Enter
        if !handled && (String(m.input.buffer) |> strip |> !isempty) &&
           (evt.key == :enter || (evt.key == :char && evt.char == '\n'))
            _send_message!(m)
        end
    end

    # Auto-focus input when user starts typing
    if evt.key == :char && isprint(evt.char) && m.focus == 1
        m.focus = 2
        m.input.focused = true
        # Pass the character to input
        handle_key!(m.input, evt)
    end
end

function _handle_task_event!(m::ChatModel, evt::TaskEvent)
    if evt.id == :chat
        if evt.value isa Exception
            add_message!(m.store, create_message(m.provider, "system", "Error: $(evt.value)"))
        elseif hasproperty(evt.value, :message)
            add_message!(m.store, evt.value.message)
        else
            add_message!(m.store, create_message(m.provider, "system", "Unknown response: $(evt.value)"))
        end
        m.is_streaming = false
        _update_widgets!(m)
    end
end

function _send_message!(m::ChatModel)
    text = String(strip(String(m.input.buffer)))
    isempty(text) && return

    # Add user message to context store
    add_message!(m.store, create_message(m.provider, "user", text))
    empty!(m.input.buffer)
    m.input.cursor = 0
    _update_widgets!(m)

    # Get context and send to FlootyStreams
    m.is_streaming = true
    context = get_context(m.store, SimpleStack(max_messages=20))
    spawn_task!(m.task_queue, :chat) do
        chat(m.provider, context, m.model_name)
    end
end

function _update_widgets!(m::ChatModel)
    # Recreate widgets with current width and tick
    m.message_widgets = ChatMessageWidget[]

    for msg in get_messages(m.store)
        # Width will be set properly in view, use placeholder for now
        widget = ChatMessageWidget(msg, m.model_name, 80, m.tick)
        push!(m.message_widgets, widget)
    end

    # Auto-scroll flag - will be calculated in view when we know the visible height
    m.auto_scroll = true
end

function view(m::ChatModel, f::Frame)
    m.tick += 1
    m.input.tick = m.tick
    buf = f.buffer

    # Layout calculation
    input_height = 3
    separator_height = 1
    chat_height = max(0, f.area.height - input_height - separator_height)

    chat_area = Rect(f.area.x, f.area.y, f.area.width, chat_height)
    separator_y = chat_area.y + chat_height
    input_area = Rect(f.area.x, separator_y + separator_height, f.area.width, input_height)

    # Update widget widths based on actual area
    total_height = 0
    for widget in m.message_widgets
        widget.width = chat_area.width

        msg_role = role(widget.message)
        msg_content = content(widget.message)
        if msg_role == "user"
            # Recreate plain text lines with new width
            widget.lines = String[]
            for para in split(msg_content, '\n', keepempty=false)
                wrapped = _word_wrap(para, widget.width-2)
                append!(widget.lines, wrapped)
                push!(widget.lines, "")
            end
            if isempty(widget.lines)
                widget.lines = ["(empty)"]
            end
            # Update total height for user messages based on actual wrapped lines
            content_lines = min(10, length(widget.lines))
            widget.total_height = 1 + content_lines
        elseif widget.md_pane !== nothing
            # Recreate MarkdownPane with new width
            widget.md_pane = MarkdownPane(msg_content; width=widget.width-4, block=nothing, show_scrollbar=true)
            # Update total height for assistant messages based on content
            lines_count = count(c -> c == '\n', msg_content) + 1
            words = length(split(msg_content))
            avg_chars_per_line = div(widget.width-4, 6)
            estimated_lines = max(1, div(length(msg_content), avg_chars_per_line) + lines_count)
            widget.total_height = 1 + min(10, estimated_lines)
        end
        
        total_height += widget.total_height
    end

    # Auto-scroll to bottom if needed
    if m.auto_scroll
        visible_height = chat_area.height
        if total_height > visible_height
            m.scroll_offset = total_height - visible_height
        else
            m.scroll_offset = 0
        end
        m.auto_scroll = false
    end

    # Render chat messages (with visual focus indicator)
    _render_chat_messages!(m, buf, chat_area)

    # Draw focus handle on left side of focused area
    focus_handle = Style(fg=ColorRGB(200, 200, 200))
    if m.focus == 1
        # Chat focused - draw handle on left edge of chat area
        for y in chat_area.y:bottom(chat_area)
            set_char!(buf, chat_area.x, y, '▌', focus_handle)
        end
    else
        # Input focused - draw handle on left edge of input area
        for y in input_area.y:bottom(input_area)
            set_char!(buf, input_area.x, y, '▌', focus_handle)
        end
    end

    # Draw separator line
    for x in f.area.x:(f.area.x + f.area.width - 1)
        set_char!(buf, x, separator_y, '─', SEPARATOR)
    end

    # Render input area
    _render_input_area!(m, buf, input_area)

    # Status bar
    status_text = if m.is_streaming
        "Streaming..."
    else
        "$(m.model_name) | Ctrl+C to quit"
    end
    # Show focus hint in status
    focus_hint = m.focus == 1 ? " [Tab: input] " : " [Tab: chat] "
    status_text *= focus_hint

    status_x = input_area.x + max(0, (input_area.width - length(status_text)) ÷ 2)
    set_string!(buf, status_x, input_area.y + input_area.height - 1, status_text,
                GREY_TEXT)
end

# Scrollbar styles
const SCROLLBAR_TRACK = Style(fg=Color256(240))
const SCROLLBAR_THUMB = Style(fg=Color256(250))

function _draw_focus_handle!(buf::Buffer, area::Rect, style::Style)
    # Draw vertical handle on left side of focused area
    for y in area.y:bottom(area)
        set_char!(buf, area.x, y, '▌', style)
    end
end



function _render_scrollbar!(buf::Buffer, area::Rect, total_height::Int, visible_height::Int, scroll_offset::Int)
    # Only show scrollbar if content exceeds visible area
    total_height <= visible_height && return

    # Calculate scrollbar metrics
    scrollbar_height = visible_height
    thumb_ratio = visible_height / total_height
    thumb_height = max(1, round(Int, scrollbar_height * thumb_ratio))

    # Calculate thumb position based on scroll
    scrollable_height = total_height - visible_height
    scroll_progress = scroll_offset / scrollable_height
    thumb_pos = round(Int, scroll_progress * (scrollbar_height - thumb_height))

    # Draw scrollbar track on right edge
    track_x = right(area)
    for y in area.y:bottom(area)
        set_char!(buf, track_x, y, '│', SCROLLBAR_TRACK)
    end

    # Draw thumb
    for i in 0:(thumb_height-1)
        thumb_y = area.y + thumb_pos + i
        if thumb_y <= bottom(area)
            set_char!(buf, track_x, thumb_y, '█', SCROLLBAR_THUMB)
        end
    end
end

function _render_chat_messages!(m::ChatModel, buf::Buffer, area::Rect)
    # Reserve space for scrollbar on right edge
    scrollbar_width = 1
    content_area = Rect(area.x, area.y, area.width - scrollbar_width, area.height)

    total_height = sum(w.total_height for w in m.message_widgets; init=0)
    visible_height = content_area.height
    scrollable_height = max(0, total_height - visible_height)

    # Clamp scroll_offset to valid range
    m.scroll_offset = clamp(m.scroll_offset, 0, scrollable_height)

    # Calculate starting Y based on scroll
    current_y = content_area.y - m.scroll_offset

    # Set tick on all message widgets and update focus
    for widget in m.message_widgets
        if widget.md_pane !== nothing
            widget.md_pane.pane.tick = m.tick
            # Chat messages are not individually focusable, but we could add per-message focus later
        end
    end

    # Render visible messages
    for widget in m.message_widgets
        widget_bottom = current_y + widget.total_height
        widget_top = current_y

        # Skip if widget is completely above visible area
        widget_bottom < content_area.y && (current_y = widget_bottom; continue)
        # Skip if widget is completely below visible area
        widget_top > bottom(content_area) && break

        # Render widget (partially or fully visible)
        render_message!(buf, widget, content_area, current_y - content_area.y, m.tick)
        current_y = widget_bottom
    end

    # Render scrollbar
    _render_scrollbar!(buf, area, total_height, visible_height, m.scroll_offset)
end

function _render_input_area!(m::ChatModel, buf::Buffer, area::Rect)
    # Draw input prompt indicator
    input_h = area.height - 1
    input_h > 0 || return

    # Draw prompt symbol
    prompt = "› "
    set_string!(buf, area.x, area.y, prompt, GREY_DIM)

    # Render TextInput next to prompt
    input_area_inner = Rect(area.x + 2, area.y, area.width - 2, input_h)
    m.input.focused = true
    m.input.tick = m.tick
    render(m.input, input_area_inner, buf)
end

function flooty_chat(; model_name::String="qwen2.5:0.5b", theme_name=nothing)
    theme_name !== nothing && set_theme!(theme_name)
    model = ChatModel(model_name=model_name)
    # Add system message
    add_message!(model.store, create_message(model.provider, "system", "You are a helpful assistant."))
    _update_widgets!(model)
    app(model; fps=30)
end
