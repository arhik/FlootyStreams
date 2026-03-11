function ask(provider::OllamaProvider, prompt::String; history=OllamaMessage[], schema_dict = OrderedDict(), stream=true)
    push!(history, OllamaMessage(role=:user, content=prompt))
    res = chat(provider, history; model="llama3.2", format=schema_dict, stream=stream)
    io = IOBuffer()
    for i in res
        print(i.message.content)
        write(io, i.message.content)
    end
    seek(io, 0)
    push!(history, OllamaMessage(role=:assistant, content=String(read(io))))
    return nothing
end


function save_history(provider::OllamaProvider, history::Vector{OllamaMessage}, filename::String)
    f = open(filename, "w")
    for i in history
        write(f, JSON3.write(i) * "\n")
    end
    close(f)
    return nothing
end

function load_history(provider::OllamaProvider, filename::String)
    f = open(filename, "r")
    history = Vector{OllamaMessage}()
    for line in eachline(f)
        message = JSON3.read(line, OllamaMessage)
        push!(history, message)
    end
    close(f)
    return history
end
