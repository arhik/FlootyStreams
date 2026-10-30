using Test
using FlootyStreams
using FlootyAbstract

@testset "Ollama speech" begin
    p = OllamaProvider()

    @testset "capability detection" begin
        @test supports_speech(p, "phonon:latest")
        @test !supports_speech(p, "definitely-not-a-model")
    end

    @testset "voices" begin
        v = speech_voices(p, "phonon:latest")
        @test "default" in v
        @test isempty(speech_voices(p, "llama3"))
    end

    @testset "argument validation" begin
        @test_throws ArgumentError speech(p, "")
        @test_throws ArgumentError speech(p, "x"; format=:mp3)
        @test_throws ArgumentError speech(p, repeat("a", 5000))
    end
end
