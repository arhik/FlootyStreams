using Test
using FlootyStreams
using FlootyAbstract
using JSON3
using OrderedCollections

@testset "OpenAI Types" begin
    @testset "Provider Creation" begin
        # Test default provider
        provider = FlootyStreams.OpenAIProvider()
        @test provider.baseURL == "https://api.openai.com/v1"
        @test provider.apiKey == ""
        @test provider.timeout == 120
        
        # Test provider with custom config
        provider2 = FlootyStreams.OpenAIProvider(
            baseURL="https://api.openrouter.ai/api/v1",
            apiKey="test-key",
            timeout=60
        )
        @test provider2.baseURL == "https://api.openrouter.ai/api/v1"
        @test provider2.apiKey == "test-key"
        @test provider2.timeout == 60
    end
    
    @testset "Message Creation" begin
        msg = FlootyStreams.OpenAIMessage(role="user", content="Hello")
        @test msg.role == "user"
        @test msg.content == "Hello"
        @test msg.tool_calls === nothing
        
        # Test with tool calls
        tool_call = FlootyStreams.OpenAIToolCall(
            "call_123",
            "function",
            FlootyStreams.OpenAIFunction("test_func", "A test function", OrderedCollections.OrderedDict())
        )
        msg2 = FlootyStreams.OpenAIMessage(
            role="assistant",
            content="",
            tool_calls=[tool_call]
        )
        @test msg2.tool_calls isa Vector
        @test length(msg2.tool_calls) == 1
        @test msg2.tool_calls[1].id == "call_123"
    end
    
    @testset "Interface Functions" begin
        provider = FlootyStreams.OpenAIProvider()
        
        # Test create_message
        msg = FlootyAbstract.create_message(provider, "user", "Hello")
        @test msg isa FlootyStreams.OpenAIMessage
        @test FlootyAbstract.role(msg) == "user"
        @test FlootyAbstract.content(msg) == "Hello"
        
        # Test provider_name
        @test FlootyAbstract.provider_name(provider) == :openai
    end
end

@testset "OpenAI Tools" begin
    @testset "Tool Creation" begin
        function_info = FlootyStreams.OpenAIFunction(
            "get_weather",
            "Get the weather for a location",
            OrderedCollections.OrderedDict(
                "type" => "object",
                "properties" => OrderedCollections.OrderedDict(
                    "location" => OrderedCollections.OrderedDict(
                        "type" => "string",
                        "description" => "The location"
                    )
                ),
                "required" => ["location"]
            )
        )
        
        tool = FlootyStreams.OpenAITool("function", function_info)
        @test FlootyAbstract.tool_name(tool) == "get_weather"
        @test FlootyAbstract.tool_description(tool) == "Get the weather for a location"
    end
end

@testset "OpenAI Errors" begin
    err = FlootyStreams.OpenAIError("Test error", 400, "invalid_request")
    @test err.message == "Test error"
    @test err.status == 400
    @test err.type == "invalid_request"
end

@testset "OpenAI Message Content Types" begin
    @testset "Text Content" begin
        text_content = FlootyStreams.OpenAITextContent("Hello world")
        @test text_content.type == "text"
        @test text_content.text == "Hello world"
    end
    
    @testset "Image Content" begin
        img_content = FlootyStreams.OpenAIImageContent("https://example.com/image.jpg")
        @test img_content.type == "image_url"
        @test img_content.image_url.url == "https://example.com/image.jpg"
        @test img_content.image_url.detail == "auto"
        
        # Test with detail
        img_content2 = FlootyStreams.OpenAIImageContent("https://example.com/image2.jpg", detail="high")
        @test img_content2.image_url.detail == "high"
    end
    
    @testset "Multimodal Message" begin
        provider = FlootyStreams.OpenAIProvider()
        content_items = [
            FlootyStreams.OpenAITextContent("What's in this image?"),
            FlootyStreams.OpenAIImageContent("https://example.com/image.jpg")
        ]
        msg = FlootyStreams.OpenAIMessage(role="user", content=content_items)
        @test msg.content isa Vector
        @test length(msg.content) == 2
    end
end

@testset "OpenAI Provider Instance" begin
    config = Dict{Symbol,Any}(
        :baseURL => "https://api.openrouter.ai/api/v1",
        :apiKey => "sk-test",
        :timeout => 30
    )
    
    provider = FlootyAbstract.create_provider_instance(Val(:openai); config=config)
    @test provider isa FlootyStreams.OpenAIProvider
    @test provider.baseURL == "https://api.openrouter.ai/api/v1"
    @test provider.apiKey == "sk-test"
    @test provider.timeout == 30
end

@testset "OpenAI Attachment Creation" begin
    provider = FlootyStreams.OpenAIProvider()
    
    # Test create_attachments
    attachments = FlootyAbstract.create_attachments(provider, 
        ["/path/to/image1.png", "/path/to/image2.jpg"],
        ["image/png", "image/jpeg"]
    )
    
    @test length(attachments) == 2
    @test FlootyAbstract.attachment_path(attachments[1]) == "/path/to/image1.png"
    @test FlootyAbstract.attachment_mime(attachments[1]) == "image/png"
    @test FlootyAbstract.attachment_type(attachments[1]) == :image
end

@testset "OpenAI Serialization" begin
    msg = FlootyStreams.OpenAIMessage(role="user", content="Test")
    json_str = JSON3.write(msg)
    @test contains(String(json_str), "user")
    @test contains(String(json_str), "Test")
    
    # Test tool call serialization
    tool_call = FlootyStreams.OpenAIToolCall(
        "call_123",
        "function",
        FlootyStreams.OpenAIFunction("test", "desc", OrderedCollections.OrderedDict())
    )
    json_str2 = JSON3.write(tool_call)
    @test contains(String(json_str2), "call_123")
end

@testset "OpenAI Tool Calls" begin
    tool_call = FlootyStreams.OpenAIToolCall(
        "call_abc123",
        "function",
        FlootyStreams.OpenAIFunction("test", "desc", OrderedCollections.OrderedDict("key" => "value"))
    )
    
    @test FlootyAbstract.call_id(tool_call) == "call_abc123"
    @test FlootyAbstract.call_name(tool_call) == "test"
end

@testset "OpenAI Embedder" begin
    provider = FlootyStreams.OpenAIProvider(apiKey="test-key")
    embedder = FlootyAbstract.create_embedder(provider, "text-embedding-3-small")
    @test embedder isa FlootyStreams.OpenAIEmbedder
    @test embedder.model == "text-embedding-3-small"
end

println("All OpenAI tests passed!")
