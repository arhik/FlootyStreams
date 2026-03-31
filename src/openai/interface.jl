FlootyAbstract.role(msg::OpenAIMessage) = msg.role
FlootyAbstract.content(msg::OpenAIMessage) = msg.content isa String ? msg.content : nothing

FlootyAbstract.create_message(provider::OpenAIProvider, role::String, content::String; kwargs...) =
    OpenAIMessage(role=role, content=content)

FlootyAbstract.create_message(provider::OpenAIProvider, role::String, content::String, images::Vector{<:AbstractProviderObject}; kwargs...) =
    OpenAIMessage(role=role, content=content)

# New interface: create message with attachments (ImageAttachment, etc.)
# OpenAI uses vision models with base64 encoded images
function FlootyAbstract.create_message(provider::OpenAIProvider, role::String, content::String, attachments::Vector{<:AbstractAttachment}; kwargs...)
    content_items = AbstractProviderObject[]
    
    # Add text content first
    push!(content_items, OpenAITextContent(content))
    
    # Add image attachments
    for att in attachments
        if attachment_type(att) == :image
            # Read image and encode as base64 data URL
            img_data = read(attachment_path(att))
            base64_str = Base64.base64encode(img_data)
            mime = attachment_mime(att)
            data_url = "data:$mime;base64,$base64_str"
            push!(content_items, OpenAIImageContent(data_url))
        end
    end
    
    OpenAIMessage(role=role, content=content_items)
end

FlootyAbstract.create_image_data(provider::OpenAIProvider, data::Union{String, Vector{UInt8}}) =
    OpenAIImageContent(data isa String ? data : Base64.base64encode(data))

FlootyAbstract.images(msg::OpenAIMessage) = nothing  # OpenAI uses content array, not separate images field
FlootyAbstract.tool_calls(msg::OpenAIMessage) = msg.tool_calls

# Create attachments from file paths
function FlootyAbstract.create_attachments(provider::OpenAIProvider, paths::Vector{String}, mime_types::Vector{String})
    # Return as a special attachment type that can be processed
    # We'll need a simple attachment struct here
    attachments = []
    for (path, mime) in zip(paths, mime_types)
        push!(attachments, OpenAIAttachment(path, mime))
    end
    return attachments
end

# Simple attachment struct for OpenAI
struct OpenAIAttachment <: AbstractAttachment
    path::String
    mime::String
end

FlootyAbstract.attachment_path(att::OpenAIAttachment) = att.path
FlootyAbstract.attachment_type(att::OpenAIAttachment) = :image
FlootyAbstract.attachment_mime(att::OpenAIAttachment) = att.mime

FlootyAbstract.create_provider_instance(::Val{:openai}; config::Dict{Symbol, Any} = Dict{Symbol, Any}()) = 
    OpenAIProvider(
        baseURL = get(config, :baseURL, "https://api.openai.com/v1"),
        apiKey = get(config, :apiKey, ""),
        timeout = get(config, :timeout, 120)
    )

FlootyAbstract.provider_name(provider::OpenAIProvider) = :openai

function FlootyAbstract.list_provider_models(::Val{:openai}, config::Dict{Symbol,Any})
    baseURL = get(config, :baseURL, "https://api.openai.com/v1")
    apiKey = get(config, :apiKey, "")
    timeout = get(config, :timeout, 120)
    provider = OpenAIProvider(; baseURL=baseURL, apiKey=apiKey, timeout=timeout)
    models = list(provider)
    return models
end

FlootyAbstract.create_embedder(provider::OpenAIProvider, model::String; kwargs...) =
    OpenAIEmbedder(provider, model)

function FlootyAbstract.create_stream(provider::OpenAIProvider, model::String, messages::Vector{<:AbstractMessage},
    stream::Bool=false;
    temperature::Union{Float64, Nothing}=nothing,
    tools::Union{Vector{<:AbstractTool}, Nothing}=nothing,
    tool_choice::Union{String, Nothing}=nothing,
    kwargs...
)
    # Convert AbstractMessage to OpenAIMessage
    openai_messages = OpenAIMessage[]
    for m in messages
        if m isa OpenAIMessage
            push!(openai_messages, m)
        else
            content_val = FlootyAbstract.content(m)
            push!(openai_messages, OpenAIMessage(role=role(m), content=content_val))
        end
    end
    
    # Convert tools to OpenAITool
    openai_tools = if tools === nothing
        nothing
    else
        map(t -> FlootyAbstract.build_tool(t, provider), tools)
    end
    
    chat(provider, openai_messages, model, stream; 
         temperature=temperature, tools=openai_tools, tool_choice=tool_choice, kwargs...)
end

function FlootyAbstract.chat_stream(provider::OpenAIProvider, model::String, messages::Vector{<:AbstractMessage},
    stream::Bool=false;
    temperature::Union{Float64, Nothing}=nothing,
    tools::Union{Vector{<:AbstractTool}, Nothing}=nothing,
    tool_choice::Union{String, Nothing}=nothing,
    kwargs...
)
    # Convert AbstractMessage to OpenAIMessage
    openai_messages = OpenAIMessage[]
    for m in messages
        if m isa OpenAIMessage
            push!(openai_messages, m)
        else
            content_val = FlootyAbstract.content(m)
            push!(openai_messages, OpenAIMessage(role=role(m), content=content_val))
        end
    end
    
    # Convert tools to OpenAITool using build_tool
    openai_tools = if tools === nothing
        nothing
    else
        map(t -> FlootyAbstract.build_tool(t, provider), tools)
    end
    
    chat(provider, openai_messages, model, stream; 
         temperature=temperature, tools=openai_tools, tool_choice=tool_choice, kwargs...)
end

# Additional helper function to create a vision-capable message with images
function create_vision_message(provider::OpenAIProvider, text::String, image_urls::Vector{String})
    content_items = AbstractProviderObject[]
    push!(content_items, OpenAITextContent(text))
    for url in image_urls
        push!(content_items, OpenAIImageContent(url))
    end
    OpenAIMessage(role="user", content=content_items)
end

# Helper to create a tool response message
function create_tool_response_message(provider::OpenAIProvider, tool_call_id::String, content::String)
    OpenAIMessage(
        role="tool",
        content=content,
        tool_call_id=tool_call_id
    )
end
