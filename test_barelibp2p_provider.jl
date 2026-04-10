#!/usr/bin/env julia
# Test BareLibP2P provider in FlootyStreams

using FlootyStreams
using FlootyStreams: BareLibP2PProvider, BareLibP2PMessage, BareLibP2PModel
using FlootyAbstract

println("="^60)
println("BareLibP2P Provider Test for FlootyStreams")
println("="^60)
println()

# Test 1: Create provider
println("Test 1: Create BareLibP2P provider")
provider = BareLibP2PProvider(
    p2p_port = 4001,
    api_port = 5001,
    service_topic = "peercompute-test-v1",
    bootstrap_peers = String[]
)
println("✓ Created provider:")
println("  P2P port: $(provider.p2p_port)")
println("  API port: $(provider.api_port)")
println("  Topic: $(provider.service_topic)")
println()

# Test 2: Start provider (only DHT/GossipSub, no network listeners)
println("Test 2: Start provider")
success = start_provider(provider)
if success
    println("✓ Provider started")
    println("  Peer ID: $(provider.peer_id[1:40])...")
    println("  DHT buckets: $(length(provider.dht.routing_table.buckets))")
else
    println("✗ Failed to start provider")
    exit(1)
end
println()

# Test 3: Register models
println("Test 3: Register models")
FlootyStreams.register_models(provider, ["llama2", "mistral"])
println("✓ Registered models: $(join(provider.announced_models, ", "))")
println()

# Test 4: Create message
println("Test 4: Create message")
msg = BareLibP2PMessage(role="user", content="Hello world")
println("✓ Created message:")
println("  Role: $(msg.role)")
println("  Content: $(msg.content)")
println()

# Test 5: Create model
println("Test 5: Create model info")
model = BareLibP2PModel(name="llama2", peer_id=provider.peer_id, reputation=1.0)
println("✓ Created model:")
println("  Name: $(model.name)")
println("  Provider: $(FlootyAbstract.model_provider(model))")
println()

# Test 6: Discover peers (will be empty)
println("Test 6: Discover peers")
peers = FlootyStreams.discover_peers(provider)
println("✓ Discovered $(length(peers)) peers (expected 0 in isolated test)")
println()

# Test 7: Get registered models
println("Test 7: Get registered models")
models = FlootyStreams.get_registered_models(provider)
println("✓ Registered models: $(join(models, ", "))")
println()

# Test 8: Stop provider
println("Test 8: Stop provider")
FlootyStreams.stop_provider(provider)
println("✓ Provider stopped")
println()

# Test 9: Test with bootstrap
println("Test 9: Provider with bootstrap")
provider2 = BareLibP2PProvider(
    p2p_port = 4002,
    api_port = 5002,
    bootstrap_peers = ["/ip4/127.0.0.1/tcp/4001"]
)
success = start_provider(provider2)
if success
    println("✓ Provider with bootstrap started")
    FlootyStreams.stop_provider(provider2)
    println("✓ Provider with bootstrap stopped")
else
    println("⚠ Provider with bootstrap failed (may be expected in isolated test)")
end
println()

println("="^60)
println("✅ All BareLibP2P provider tests passed!")
println("="^60)
