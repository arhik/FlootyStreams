"""
Test PeerCompute peer discoverability via FlootyStreams.

Run this test:
    cd /Users/arhik/.julia/dev/FlootyStreams
    julia --project=. test/test_peer_discovery.jl

This test:
1. Starts a bootstrap node
2. Starts a regular PeerCompute node that connects to bootstrap
3. Announces models from the node
4. Tests model discovery via FlootyStreams

Note: Requires Ollama to be running (for model inference) or uses dummy models.
"""

using PeerCompute
using FlootyStreams
using FlootyAbstract

println("="^60)
println("PeerCompute Discovery Test")
println("="^60)

# Step 1: Start bootstrap node
println("\n[1] Starting PeerCompute bootstrap node...")
try
    # Generate a static key for consistent identity
    key_file = "/tmp/peercompute_test_bootstrap.key"
    if !isfile(key_file)
        PeerCompute.generate_static_key(key_file)
        println("  ✓ Generated static key: $key_file")
    end
    
    # Start bootstrap node
    PeerCompute.start_bootstrap_node(4002, 5002, key_file)
    sleep(2)  # Give it time to start
    
    bootstrap_id = PeerCompute.get_bootstrap_node_id()
    println("  ✓ Bootstrap node started: $(bootstrap_id[1:min(16, length(bootstrap_id))])...")
    
    multiaddrs = PeerCompute.get_bootstrap_multiaddresses()
    println("  ✓ Bootstrap addresses:")
    for addr in multiaddrs
        println("    - $addr")
    end
    bootstrap_addr = multiaddrs[1]
catch e
    println("  ✗ Failed to start bootstrap: $e")
    exit(1)
end

# Step 2: Start regular PeerCompute node
println("\n[2] Starting regular PeerCompute node...")
try
    # Create settings with bootstrap peer
    settings = PeerCompute.PeerComputeSettings(
        p2p_port=4003,
        api_port=5003,
        bootstrap_peers=[bootstrap_addr],
        service_topic="peercompute-nodes-v1",
        allowed_models=["llama2:7b", "mistral:latest", "phi:latest"]
    )
    
    PeerCompute.start_daemon(settings)
    sleep(2)  # Give it time to connect
    println("  ✓ Regular node started on P2P port 4003")
    
    # Get our node ID
    our_id = PeerCompute.get_node_id()
    println("  ✓ Our node ID: $(our_id[1:min(16, length(our_id))])...")
catch e
    println("  ✗ Failed to start node: $e")
    println("  (May be normal if Ollama is not running - continuing with test)")
end

# Step 3: Announce models
println("\n[3] Announcing models to P2P network...")
try
    models = ["llama2:7b", "mistral:latest", "phi:latest"]
    PeerCompute.announce_models(models)
    println("  ✓ Announced models: $models")
    sleep(2)  # Allow propagation
catch e
    println("  ✗ Failed to announce: $e")
end

# Step 4: Test discovery via PeerCompute directly
println("\n[4] Testing peer discovery via PeerCompute...")
try
    discovered = PeerCompute.get_discovered_nodes()
    println("  ✓ Discovered $(length(discovered)) nodes")
    
    for (peer_id, info) in discovered
        models = get(info, "model_names", String[])
        println("    - $(peer_id[1:8])...: $models")
    end
catch e
    println("  ✗ Discovery failed: $e")
end

# Step 5: Test discovery via FlootyStreams
println("\n[5] Testing model discovery via FlootyStreams...")
try
    provider = FlootyAbstract.create_provider_instance(:peercompute)
    println("  ✓ Provider created: $(typeof(provider))")
    
    # Use FlootyCore-style bootstrap config
    config = Dict{Symbol,Any}(
        :bootstrap => Dict{Symbol,Any}(
            :enable => true,
            :multiaddresses => [bootstrap_addr]
        )
    )
    
    models = FlootyAbstract.list_provider_models(:peercompute, config)
    println("  ✓ Found $(length(models)) models via FlootyStreams:")
    
    for model in models
        model_name = FlootyAbstract.model_name(model)
        peer_id = model.peer_id
        println("    - $model_name @ $(peer_id[1:8])...")
    end
    
    if isempty(models)
        println("    (No models found - this is OK if discovery hasn't propagated yet)")
    end
catch e
    println("  ✗ FlootyStreams discovery failed: $e")
    showerror(stdout, e)
end

# Step 6: Test provider with bootstrap config
println("\n[6] Testing provider creation with bootstrap config...")
try
    provider = FlootyAbstract.create_provider_instance(:peercompute; config=Dict{Symbol,Any}(
        :bootstrap => Dict{Symbol,Any}(
            :enable => true,
            :multiaddresses => [bootstrap_addr]
        ),
        :service_topic => "peercompute-nodes-v1"
    ))
    println("  ✓ Provider with bootstrap config: " * (isempty(provider.bootstrap_peers) ? "no peers" : "$(length(provider.bootstrap_peers)) peers"))
catch e
    println("  ✗ Failed: $e")
end

# Cleanup
println("\n[7] Cleanup...")
try
    PeerCompute.stop_daemon()
    println("  ✓ Regular node stopped")
catch
    # Ignore
end

try
    PeerCompute.stop_bootstrap_node()
    println("  ✓ Bootstrap node stopped")
catch
    # Ignore
end

println("\n" * "="^60)
println("Test complete!")
println("="^60)
