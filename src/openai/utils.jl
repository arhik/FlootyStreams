function ask(provider::OpenAIProvider, prompt::String; history=OpenAIMessage[], model="gpt-4", stream=true, kwargs...)
    push!(history, OpenAIMessage(role="user", content=prompt))
    res = chat(provider, history, model; stream=stream, kwargs...)
    io = IOBuffer()
    for chunk in res
        delta_content = get(chunk.choices[1].delta, "content", "")
        print(delta_content)
        write(io, delta_content)
    end
    seek(io, 0)
    push!(history, OpenAIMessage(role="assistant", content=String(read(io))))
    return nothing
end

function save_history(history::Vector{OpenAIMessage}, filename::String)
    open(filename, "w") do f
        for msg in history
            write(f, JSON3.write(msg) * "\n")
        end
    end
    return nothing
end

function load_history(filename::String)
    history = Vector{OpenAIMessage}()
    open(filename, "r") do f
        for line in eachline(f)
            isempty(line) && continue
            message = JSON3.read(line, OpenAIMessage)
            push!(history, message)
        end
    end
    return history
end

# Helper function to format messages for display
function format_message(msg::OpenAIMessage)
    role_label = uppercase(msg.role)
    if msg.content isa String
        return "[$role_label]: $(msg.content)"
    elseif msg.content isa Vector
        text_parts = String[]
        for item in msg.content
            if item isa OpenAITextContent
                push!(text_parts, item.text)
            elseif item isa OpenAIImageContent
                push!(text_parts, "[Image: $(item.image_url.url[1:min(50, length(item.image_url.url))])...]")
            end
        end
        return "[$role_label]: $(join(text_parts, " "))"
    else
        return "[$role_LABEL]: (no content)"
    end
end

# Helper to check if API key is set
function check_api_key(provider::OpenAIProvider)
    isempty(provider.apiKey) && throw(OpenAIError("API key not set. Please provide an API key.", 401, "authentication_error"))
    return true
end
