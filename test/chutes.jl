using Test
using FlootyStreams
using FlootyAbstract
using JSON3
using OrderedCollections

@testset "Chutes Provider" begin
    @testset "Provider Creation" begin
        # Test default provider
        provider = ChutesProvider()
        @test provider.baseURL == "https://llm.chutes.ai"
        @test provider.apiKey == ""
        @test provider.timeout == 120
        @test provider.chute == ""
        
        # Test provider with custom config
        provider2 = ChutesProvider(
            baseURL="https://custom.chutes.ai",
            apiKey="test-key",
            timeout=60,
            chute="my-chute"
        )
        @test provider2.baseURL == "https://custom.chutes.ai"
        @test provider2.apiKey == "test-key"
        @test provider2.timeout == 60
        @test provider2.chute == "my-chute"
    end
    
    @testset "Type Hierarchy" begin
        provider = ChutesProvider()
        @test provider isa FlootyAbstract.OpenAICompatibleProvider
        @test provider isa FlootyAbstract.AbstractLLMProvider
    end
    
    @testset "Provider Instance Creation" begin
        config = Dict{Symbol,Any}(
            :baseURL => "https://llm.chutes.ai",
            :apiKey => "sk-test",
            :timeout => 30,
            :chute => "test-chute"
        )
        
        provider = FlootyAbstract.create_provider_instance(Val(:chutes); config=config)
        @test provider isa ChutesProvider
        @test provider.baseURL == "https://llm.chutes.ai"
        @test provider.apiKey == "sk-test"
        @test provider.timeout == 30
        @test provider.chute == "test-chute"
    end
    
    @testset "Message Creation" begin
        provider = ChutesProvider()
        
        # Test basic message creation
        msg = FlootyAbstract.create_message(provider, "user", "Hello")
        @test msg isa OpenAIMessage
        @test msg.role == "user"
        @test msg.content == "Hello"
        
        # Test image data creation
        img_data = FlootyAbstract.create_image_data(provider, "https://example.com/image.jpg")
        @test img_data isa OpenAIImageContent
        @test img_data.image_url.url == "https://example.com/image.jpg"
    end
    
    @testset "Attachments" begin
        provider = ChutesProvider()
        
        attachments = FlootyAbstract.create_attachments(provider, 
            ["/path/to/image1.png", "/path/to/image2.jpg"],
            ["image/png", "image/jpeg"]
        )
        
        @test length(attachments) == 2
        @test FlootyAbstract.attachment_path(attachments[1]) == "/path/to/image1.png"
    end
end

println("All Chutes tests passed!")
