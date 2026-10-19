using Test
using FlootyStreams
using JSON3
using OrderedCollections
using HTTP
using Base64

@testset "Ollama decision (System One)" begin
    @testset "Question constructors" begin
        choice = SystemOneChoiceQuestion(
            "Which label fits this ticket?",
            OrderedDict("billing" => "Payments and refunds", "bug" => nothing))
        @test choice.type == "choice"
        @test choice.criteria["billing"] == "Payments and refunds"
        @test choice.criteria["bug"] === nothing
        @test_throws ArgumentError SystemOneChoiceQuestion("bad", ["billing", "bug"])

        noul = SystemOneNoulQuestion("Is a refund requested?")
        @test noul.type == "noul"
        @test noul.criteria === nothing

        noul_described = SystemOneNoulQuestion(
            "Is a refund requested?",
            Dict("false" => "No refund", "true" => "Refund requested"))
        @test noul_described.criteria["true"] == "Refund requested"

        score = SystemOneScoreQuestion(
            "How urgent is this?", ["Routine", "Soon", "Immediate"])
        @test score.type == "score"
        @test score.criteria == ["Routine", "Soon", "Immediate"]

        @test_throws ArgumentError SystemOneScoreQuestion("bad", "not a vector")
    end

    @testset "Request serialization" begin
        dir = mktempdir()
        image_path = joinpath(dir, "image.png")
        image_bytes = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        write(image_path, image_bytes)

        questions = OrderedDict(
            "label" => SystemOneChoiceQuestion(
                "Which label fits this ticket?",
                OrderedDict("billing" => "Payments and refunds", "bug" => "Software errors")),
            "refund" => SystemOneNoulQuestion("Is a refund requested?"),
            "urgency" => SystemOneScoreQuestion(
                "How urgent is this?", ["Routine", "Soon", "Immediate"]),
        )

        request = SystemOneRequest(
            model="laya",
            state=Dict("ticket" => "I was charged twice."),
            questions=FlootyStreams._normalize_questions(questions),
            images=[FlootyStreams.ImageData(image_path)],
            keep_alive="5m",
        )
        json = JSON3.read(JSON3.write(request))

        @test json.model == "laya"
        @test json.state.ticket == "I was charged twice."
        @test json.questions.label.type == "choice"
        @test json.questions.label.criteria.bug == "Software errors"
        @test json.questions.refund.type == "noul"
        @test !haskey(json.questions.refund, :criteria)
        @test json.questions.urgency.criteria == ["Routine", "Soon", "Immediate"]
        @test json.images == [Base64.base64encode(image_bytes)]
        @test json.keep_alive == "5m"

        minimal = JSON3.read(JSON3.write(SystemOneRequest(
            model="nimble",
            state="checkout is down",
            questions=FlootyStreams._normalize_questions(
                OrderedDict("urgent" => SystemOneNoulQuestion("Is this urgent?"))),
        )))
        @test !haskey(minimal, :images)
        @test !haskey(minimal, :keep_alive)

        normalized_request = SystemOneRequest(
            model="laya",
            state="state",
            questions=Dict("urgent" => SystemOneNoulQuestion("Is this urgent?")),
            images=[image_path],
        )
        @test normalized_request.questions isa OrderedDict{String,Any}
        @test normalized_request.questions["urgent"].type == "noul"
        @test normalized_request.images isa Vector{ImageData}
        @test normalized_request.images[1] isa ImageData
    end

    @testset "Question normalization" begin
        pairs = ["refund" => SystemOneNoulQuestion("Refund?")]
        normalized = FlootyStreams._normalize_questions(pairs)
        @test collect(keys(normalized)) == ["refund"]
        @test normalized["refund"].type == "noul"

        @test_throws ArgumentError FlootyStreams._normalize_questions(Dict{String,Any}())
        @test_throws ArgumentError FlootyStreams._normalize_questions(
            Dict("bad" => "not a question"))
        @test_throws ArgumentError FlootyStreams._normalize_questions(
            Dict(" " => SystemOneNoulQuestion("Refund?")))
    end

    @testset "Response parsing" begin
        raw = JSON3.read("""
        {
          "model": "laya",
          "answers": {
            "label": {
              "type": "choice",
              "choice": "bug",
              "probabilities": {"billing": 0.0125, "bug": 0.9781, "account": 0.0093},
              "confidence": 0.8906
            },
            "refund": {"type": "noul", "noul": 0.9989},
            "urgency": {
              "type": "score",
              "score": 0.8308,
              "legend": {"0": "Routine", "1": "Soon", "2": "Immediate"},
              "probabilities": {"0": 0.1, "1": 0.8, "2": 0.1},
              "confidence": 0.7
            }
          },
          "usage": {"input_tokens": 174, "output_tokens": 1}
        }
        """)
        response = FlootyStreams._parse_systemone_response(raw)

        @test response isa SystemOneResponse
        @test response.model == "laya"
        @test response.usage.input_tokens == 174
        @test response.usage.output_tokens == 1

        label = response.answers["label"]
        @test label isa SystemOneChoiceAnswer
        @test label.choice == "bug"
        @test label.probabilities["bug"] == 0.9781
        @test label.confidence == 0.8906

        refund = response.answers["refund"]
        @test refund isa SystemOneNoulAnswer
        @test refund.noul == 0.9989

        urgency = response.answers["urgency"]
        @test urgency isa SystemOneScoreAnswer
        @test urgency.score == 0.8308
        @test urgency.legend["2"] == "Immediate"
        @test urgency.probabilities["1"] == 0.8

        @test_throws ArgumentError FlootyStreams._parse_systemone_answer(
            JSON3.read("""{"type": "unknown"}"""))
    end

    @testset "HTTP endpoint and capabilities" begin
        captured = Dict{String,Any}()
        handler = function (request)
            if request.method == "POST" && request.target == "/v1/systemone"
                body = JSON3.read(String(request.body))
                captured["systemone"] = body
                body.model == "missing" && return HTTP.Response(
                    404, JSON3.write(Dict("error" => "model not found")))
                return HTTP.Response(200, JSON3.write(Dict(
                    "model" => body.model,
                    "answers" => Dict(
                        "label" => Dict(
                            "type" => "choice",
                            "choice" => "bug",
                            "probabilities" => Dict("billing" => 0.1, "bug" => 0.9),
                            "confidence" => 0.8),
                        "refund" => Dict("type" => "noul", "noul" => 0.75),
                    ),
                    "usage" => Dict("input_tokens" => 31, "output_tokens" => 0),
                )))
            elseif request.method == "POST" && request.target == "/api/show"
                body = JSON3.read(String(request.body))
                captured["show"] = body
                return HTTP.Response(200, JSON3.write(Dict(
                    "capabilities" => ["decision"],
                    "details" => Dict("family" => "laya"),
                )))
            elseif request.method == "GET" && request.target == "/api/tags"
                return HTTP.Response(200, JSON3.write(Dict(
                    "models" => [Dict(
                        "name" => "laya",
                        "model" => "laya",
                        "modified_at" => "2026-10-19T00:00:00Z",
                        "size" => 846_000_000,
                        "digest" => "abc",
                        "details" => Dict(
                            "parent_model" => "",
                            "format" => "gguf",
                            "family" => "laya",
                            "families" => ["laya"],
                            "parameter_size" => "421M",
                            "quantization_level" => "BF16"),
                        "capabilities" => ["decision"],
                    )],
                )))
            end
            return HTTP.Response(404, JSON3.write(Dict("error" => "not found")))
        end

        server = HTTP.serve!(handler, "127.0.0.1", 0; listenany=true)
        try
            port = parse(Int, server.listener.hostport)
            provider = OllamaProvider(baseURL="http://127.0.0.1:$port")

            questions = OrderedDict(
                "label" => SystemOneChoiceQuestion(
                    "Which label?",
                    Dict("billing" => "Payments", "bug" => "Software errors")),
                "refund" => SystemOneNoulQuestion("Is a refund requested?"),
            )
            response = systemone(provider, "laya", "Checkout returns 500s.", questions)

            @test response.model == "laya"
            @test response.answers["label"].choice == "bug"
            @test response.answers["refund"].noul == 0.75
            @test response.usage.input_tokens == 31
            @test captured["systemone"].state == "Checkout returns 500s."
            @test captured["systemone"].questions.label.type == "choice"
            @test !haskey(captured["systemone"].questions.refund, :criteria)

            @test model_capabilities(provider, "laya") == [:decision]
            @test is_decision_model(provider, "laya")
            @test captured["show"].model == "laya"

            models = FlootyStreams.list(provider).models
            @test length(models) == 1
            @test models[1] isa OllamaModel
            @test model_capabilities(models[1]) == [:decision]
            @test is_decision_model(models[1])
            @test !has_capability(models[1], :tools)

            @test_throws OllamaError systemone(
                provider, "missing", "state", questions)
        finally
            close(server)
        end
    end

    @testset "Model capabilities without metadata" begin
        model = OllamaModel(
            name="chat-model",
            model="chat-model",
            modified_at="2026-10-19T00:00:00Z",
            size=1,
            digest="abc",
            details=FlootyStreams.ModelDetails(),
            capabilities=nothing,
        )
        @test model_capabilities(model) == Symbol[]
        @test !is_decision_model(model)
        @test !has_capability(model, :decision)
    end
end
