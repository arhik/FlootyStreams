# Model Cache Utility
# Provides cached access to provider model lists so the UI doesn't
# block on network calls when fresh data isn't strictly necessary.
#
# Pattern:
#   - First call fetches from API, caches result
#   - Subsequent calls within TTL return cached data immediately
#   - After TTL expires, fetches fresh models
#
# This mirrors the PeerCompute approach: pre-collected data is the
# primary source, with on-demand fetches as fallback.

using Base: ReentrantLock
import Base.time

const DEFAULT_CACHE_TTL = 60  # seconds

"""Internal cache entry storing models and the timestamp they were cached."""
struct ModelCacheEntry
    models::Any
    timestamp::Float64
end

# Global model cache (per-process)
const MODEL_CACHE = Dict{String, ModelCacheEntry}()
const MODEL_CACHE_LOCK = ReentrantLock()

"""
    get_cached_models(key::String, ttl::Int=DEFAULT_CACHE_TTL) -> (models, true) or (nothing, false)

Returns cached models if fresh (within TTL), otherwise returns (nothing, false).
"""
function get_cached_models(key::String, ttl::Int=DEFAULT_CACHE_TTL)
    lock(MODEL_CACHE_LOCK) do
        if haskey(MODEL_CACHE, key)
            entry = MODEL_CACHE[key]
            if time() - entry.timestamp < ttl
                return (entry.models, true)
            end
        end
        return (nothing, false)
    end
end

"""
    cache_models(key::String, models) -> nothing

Store models in the cache with current timestamp.
"""
function cache_models(key::String, models)
    lock(MODEL_CACHE_LOCK) do
        MODEL_CACHE[key] = ModelCacheEntry(models, time())
    end
end

"""
    invalidate_model_cache(key::String) -> nothing

Remove a specific cache entry (use when models change externally).
"""
function invalidate_model_cache(key::String)
    lock(MODEL_CACHE_LOCK) do
        delete!(MODEL_CACHE, key)
    end
end

"""
    clear_model_cache() -> nothing

Clear all cached model lists (use e.g. on shutdown or config reload).
"""
function clear_model_cache()
    lock(MODEL_CACHE_LOCK) do
        empty!(MODEL_CACHE)
    end
end
