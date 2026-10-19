# ═══════════════════════════════════════════════════════════════════════
# System One / decision models
#
# POST /v1/systemone classifies a shared state with choice, noul (yes/no)
# and score questions. Decision models (Laya, Nimble, Tev1, Clef, ...) do
# not support /api/chat or /api/generate; this is their only endpoint.
# ═══════════════════════════════════════════════════════════════════════

abstract type SystemOneQuestion <: OllamaObject end
abstract type SystemOneAnswer <: OllamaObject end

function _systemone_choice_criteria(criteria)
    criteria isa AbstractDict ||
        throw(ArgumentError("choice criteria must be a dictionary of option => description"))
    result = OrderedDict{String,Union{String,Nothing}}()
    for (key, value) in criteria
        name = string(key)
        isempty(strip(name)) && throw(ArgumentError("choice option names must not be blank"))
        result[name] = value === nothing ? nothing : string(value)
    end
    result
end

function _systemone_noul_criteria(criteria)
    criteria === nothing && return nothing
    criteria isa AbstractDict ||
        throw(ArgumentError("noul criteria must be a dictionary with \"false\" and \"true\" entries"))
    result = OrderedDict{String,String}()
    for (key, value) in criteria
        result[string(key)] = string(value)
    end
    result
end

function _systemone_score_criteria(criteria)
    criteria isa AbstractVector ||
        throw(ArgumentError("score criteria must be a vector ordered from lowest to highest"))
    String[string(level) for level in criteria]
end

struct SystemOneChoiceQuestion <: SystemOneQuestion
    type::String
    instructions::Any
    criteria::OrderedDict{String,Union{String,Nothing}}

    function SystemOneChoiceQuestion(instructions, criteria)
        new("choice", instructions, _systemone_choice_criteria(criteria))
    end
end

SystemOneChoiceQuestion(instructions; criteria) =
    SystemOneChoiceQuestion(instructions, criteria)

struct SystemOneNoulQuestion <: SystemOneQuestion
    type::String
    instructions::Any
    criteria::Union{OrderedDict{String,String},Nothing}

    function SystemOneNoulQuestion(instructions, criteria)
        new("noul", instructions, _systemone_noul_criteria(criteria))
    end
end

SystemOneNoulQuestion(instructions; criteria=nothing) =
    SystemOneNoulQuestion(instructions, criteria)

struct SystemOneScoreQuestion <: SystemOneQuestion
    type::String
    instructions::Any
    criteria::Vector{String}

    function SystemOneScoreQuestion(instructions, criteria)
        new("score", instructions, _systemone_score_criteria(criteria))
    end
end

SystemOneScoreQuestion(instructions; criteria) =
    SystemOneScoreQuestion(instructions, criteria)

StructTypes.StructType(::Type{SystemOneChoiceQuestion}) = StructTypes.Struct()
StructTypes.StructType(::Type{SystemOneNoulQuestion}) = StructTypes.Struct()
StructTypes.omitempties(::Type{SystemOneNoulQuestion}) = (:criteria,)
StructTypes.StructType(::Type{SystemOneScoreQuestion}) = StructTypes.Struct()

struct SystemOneRequest <: OllamaRequest
    model::String
    state::Any
    questions::OrderedDict{String,Any}
    images::Union{Vector{ImageData},Nothing}
    keep_alive::Union{String,Int,Nothing}
end

StructTypes.StructType(::Type{SystemOneRequest}) = StructTypes.Struct()
StructTypes.omitempties(::Type{SystemOneRequest}) = (:images, :keep_alive)

@kwdef struct SystemOneUsage <: OllamaObject
    input_tokens::Int
    output_tokens::Int
end

StructTypes.StructType(::Type{SystemOneUsage}) = StructTypes.Struct()

struct SystemOneChoiceAnswer <: SystemOneAnswer
    type::String
    choice::String
    probabilities::Dict{String,Float64}
    confidence::Float64
end

StructTypes.StructType(::Type{SystemOneChoiceAnswer}) = StructTypes.Struct()

struct SystemOneNoulAnswer <: SystemOneAnswer
    type::String
    noul::Float64
end

StructTypes.StructType(::Type{SystemOneNoulAnswer}) = StructTypes.Struct()

struct SystemOneScoreAnswer <: SystemOneAnswer
    type::String
    score::Float64
    legend::Dict{String,String}
    probabilities::Dict{String,Float64}
    confidence::Float64
end

StructTypes.StructType(::Type{SystemOneScoreAnswer}) = StructTypes.Struct()

struct SystemOneResponse <: OllamaObject
    model::String
    answers::OrderedDict{String,SystemOneAnswer}
    usage::SystemOneUsage
end

StructTypes.StructType(::Type{SystemOneResponse}) = StructTypes.Struct()

function Base.show(io::IO, response::SystemOneResponse)
    print(io, "SystemOneResponse(", response.model, ", ",
          length(response.answers), " answer", length(response.answers) == 1 ? "" : "s", ")")
end

function _parse_systemone_answer(raw)
    question_type = String(raw["type"])
    if question_type == "choice"
        probabilities = Dict{String,Float64}(
            string(k) => Float64(v) for (k, v) in pairs(raw["probabilities"]))
        return SystemOneChoiceAnswer(
            "choice", String(raw["choice"]), probabilities, Float64(raw["confidence"]))
    elseif question_type == "noul"
        return SystemOneNoulAnswer("noul", Float64(raw["noul"]))
    elseif question_type == "score"
        probabilities = Dict{String,Float64}(
            string(k) => Float64(v) for (k, v) in pairs(raw["probabilities"]))
        legend = Dict{String,String}(
            string(k) => String(v) for (k, v) in pairs(raw["legend"]))
        return SystemOneScoreAnswer(
            "score", Float64(raw["score"]), legend, probabilities, Float64(raw["confidence"]))
    end
    throw(ArgumentError("unknown System One answer type: $(repr(question_type))"))
end

function _parse_systemone_response(data)
    answers = OrderedDict{String,SystemOneAnswer}()
    for (name, raw) in pairs(data["answers"])
        answers[string(name)] = _parse_systemone_answer(raw)
    end
    usage = data["usage"]
    return SystemOneResponse(
        String(data["model"]),
        answers,
        SystemOneUsage(Int(usage["input_tokens"]), Int(usage["output_tokens"])),
    )
end

function _normalize_questions(questions::AbstractDict)
    isempty(questions) && throw(ArgumentError("at least one question is required"))
    result = OrderedDict{String,Any}()
    for (name, question) in questions
        key = string(name)
        isempty(strip(key)) && throw(ArgumentError("question names must not be blank"))
        question isa SystemOneQuestion ||
            throw(ArgumentError("question $(repr(key)) must be a SystemOneQuestion"))
        result[key] = question
    end
    result
end

_normalize_questions(questions::AbstractVector{<:Pair}) = _normalize_questions(OrderedDict(questions))

function _normalize_systemone_images(images)
    images === nothing && return nothing
    images isa AbstractVector{<:AbstractString} && return ImageData.(images)
    images isa AbstractVector{<:ImageData} && return Vector{ImageData}(images)
    throw(ArgumentError("images must be file paths or ImageData values"))
end

# Normalize dictionaries/pairs and image paths in the public keyword constructor.
function SystemOneRequest(; model::String, state, questions, images=nothing,
                          keep_alive::Union{String,Int,Nothing}=nothing)
    SystemOneRequest(model, state, _normalize_questions(questions),
                     _normalize_systemone_images(images), keep_alive)
end

"""
    systemone(provider::OllamaProvider, request::SystemOneRequest) -> SystemOneResponse

Send a typed decision request to Ollama's `POST /v1/systemone` endpoint.
Requires a decision model (capability `decision`), such as `laya`, `nimble`,
`tev1`, or `clef`.
"""
function systemone(provider::OllamaProvider, request::SystemOneRequest)
    data = _request(provider, "POST", "/v1/systemone", request)
    return _parse_systemone_response(data)
end

"""
    systemone(provider, model, state, questions; images=nothing, keep_alive=nothing)

Ask named choice, yes/no and score questions about `state`.

`questions` is a dictionary (or vector of pairs) mapping a question name to a
`SystemOneChoiceQuestion`, `SystemOneNoulQuestion`, or `SystemOneScoreQuestion`.
`images` accepts file paths or `ImageData` values and is shared by all questions.
"""
function systemone(provider::OllamaProvider, model::String, state, questions;
                   images=nothing, keep_alive::Union{String,Int,Nothing}=nothing)
    request = SystemOneRequest(;
        model=model,
        state=state,
        questions=questions,
        images=images,
        keep_alive=keep_alive,
    )
    return systemone(provider, request)
end

# ═══════════════════════════════════════════════════════════════════════
# Decision model capabilities
# ═══════════════════════════════════════════════════════════════════════

model_capabilities(model::OllamaModel) =
    model.capabilities === nothing ? Symbol[] : model.capabilities

has_capability(model::OllamaModel, capability::Symbol) =
    capability in model_capabilities(model)

is_decision_model(model::OllamaModel) = has_capability(model, :decision)

"""
    model_capabilities(provider::OllamaProvider, model::String) -> Vector{Symbol}

Fetch the capabilities advertised by `POST /api/show`, e.g. `[:decision]`
for a decision model or `[:completion, :tools]` for a chat model.
"""
function model_capabilities(provider::OllamaProvider, model::String)
    info = show(provider, model)
    haskey(info, :capabilities) || return Symbol[]
    return Symbol.(info[:capabilities])
end

is_decision_model(provider::OllamaProvider, model::String) =
    :decision in model_capabilities(provider, model)
