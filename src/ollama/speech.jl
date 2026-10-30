# ollama/speech.jl — Ollama text-to-speech (OpenAI-compatible /v1/audio/speech)

"""
    OllamaSpeechResponse <: AbstractSpeechResponse

Audio returned by Ollama speech models (e.g. `phonon`).
"""
struct OllamaSpeechResponse <: AbstractSpeechResponse
    audio::Vector{UInt8}
    format::Symbol
    mime::String
    model::String
    voice::String
end

FlootyAbstract.speech_audio(r::OllamaSpeechResponse) = r.audio
FlootyAbstract.speech_format(r::OllamaSpeechResponse) = r.format
FlootyAbstract.speech_mime(r::OllamaSpeechResponse) = r.mime
FlootyAbstract.speech_model(r::OllamaSpeechResponse) = r.model

const OLLAMA_SPEECH_PATH = "/v1/audio/speech"

"""
    speech(provider::OllamaProvider, text; model, voice, format, timeout)

Synthesize `text` with an Ollama speech model via the OpenAI-compatible
`POST /v1/audio/speech` endpoint. Returns an `OllamaSpeechResponse`.

`format` is `:wav` (default) or `:pcm`. `voice` defaults to `"default"`.
"""
function FlootyAbstract.speech(
    provider::OllamaProvider,
    text::String;
    model::String="phonon",
    voice::String="default",
    format::Symbol=:wav,
    timeout::Int=provider.timeout,
)
    isempty(text) && throw(ArgumentError("speech input must not be empty"))
    length(text) > 4096 && throw(ArgumentError("speech input exceeds Ollama limit of 4096 characters"))
    fmt = format in (:wav, :pcm) ? format : throw(ArgumentError("unsupported speech format: $format (use :wav or :pcm)"))

    body = JSON3.write(Dict(
        "model" => model,
        "input" => text,
        "voice" => voice,
        "response_format" => String(fmt),
    ))

    url = provider.baseURL * OLLAMA_SPEECH_PATH
    resp = HTTP.post(
        url,
        ["Content-Type" => "application/json"],
        body;
        timeout = timeout,
        status_exception = false,
    )

    if resp.status != 200
        msg = String(resp.body)
        throw(OllamaError("speech request failed (HTTP $(resp.status)): $msg", resp.status))
    end

    mime = fmt === :wav ? "audio/wav" : "audio/pcm"
    return OllamaSpeechResponse(Vector{UInt8}(resp.body), fmt, mime, model, voice)
end

const OLLAMA_SPEECH_PROBE_VOICE = "__flooty_probe__"

"""
    supports_speech(provider::OllamaProvider, model) -> Bool

True when the model advertises the `speech` capability.
"""
function FlootyAbstract.supports_speech(provider::OllamaProvider, model::String)
    try
        return :speech in model_capabilities(provider, model)
    catch
        return false
    end
end

"""
    speech_voices(provider::OllamaProvider, model) -> Vector{String}

Voices a speech model supports.

Ollama exposes no voice-list endpoint, but it rejects an unknown voice with
an error naming the valid ones (`available voices: default`). We probe with a
sentinel voice and parse that hint, falling back to `["default"]`.
"""
function FlootyAbstract.speech_voices(provider::OllamaProvider, model::String)
    supports_speech(provider, model) || return String[]
    body = JSON3.write(Dict(
        "model" => model,
        "input" => "x",
        "voice" => OLLAMA_SPEECH_PROBE_VOICE,
        "response_format" => "wav",
    ))
    try
        resp = HTTP.post(
            provider.baseURL * OLLAMA_SPEECH_PATH,
            ["Content-Type" => "application/json"],
            body;
            timeout = 10,
            status_exception = false,
        )
        m = match(r"available voices:\s*([^\"}]+)", String(resp.body))
        if m !== nothing
            return [String(strip(v)) for v in split(m.captures[1], ",") if !isempty(strip(v))]
        end
    catch
    end
    return ["default"]
end
