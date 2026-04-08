using HTTP
using JSON3

const OLLAMA_CLOUD_API = "https://ollama.com"

struct WebSearchResult <: AbstractSearchResult
    title::String
    url::String
    content::String
end

FlootyAbstract.result_title(r::WebSearchResult) = r.title
FlootyAbstract.result_url(r::WebSearchResult) = r.url
FlootyAbstract.result_content(r::WebSearchResult) = r.content

struct WebSearchResponse <: AbstractSearchResponse
    results::Vector{WebSearchResult}
end

FlootyAbstract.search_results(r::WebSearchResponse) = r.results

struct WebFetchResponse <: AbstractFetchResponse
    title::String
    content::String
    links::Vector{String}
end

FlootyAbstract.fetch_title(r::WebFetchResponse) = r.title
FlootyAbstract.fetch_content(r::WebFetchResponse) = r.content
FlootyAbstract.fetch_links(r::WebFetchResponse) = r.links

struct OllamaWebSearchProvider <: AbstractWebSearchProvider
    api_key::Union{String,Nothing}
end

OllamaWebSearchProvider() = OllamaWebSearchProvider(nothing)

function FlootyAbstract.default_web_search_provider()
    OllamaWebSearchProvider()
end

function FlootyAbstract.web_search(provider::OllamaWebSearchProvider, query::String; max_results::Int=5)
    key = provider.api_key !== nothing ? provider.api_key : get(ENV, "OLLAMA_API_KEY", nothing)
    isnothing(key) && throw(ArgumentError("OLLAMA_API_KEY environment variable or api_key parameter is required"))

    url = "$OLLAMA_CLOUD_API/api/web_search"
    headers = [
        "Content-Type" => "application/json",
        "Authorization" => "Bearer $key"
    ]
    body = Dict("query" => query, "max_results" => clamp(max_results, 1, 10))

    try
        response = HTTP.request("POST", url, headers, JSON3.write(body))
        data = JSON3.read(String(response.body))
        return WebSearchResponse([WebSearchResult(r.title, r.url, r.content) for r in data.results])
    catch e
        if e isa HTTP.StatusError
            error_body = JSON3.read(String(e.response.body))
            throw(OllamaError(get(error_body, :error, "Unknown error"), e.status))
        else
            rethrow(e)
        end
    end
end

function FlootyAbstract.web_fetch(provider::OllamaWebSearchProvider, url::String)
    key = provider.api_key !== nothing ? provider.api_key : get(ENV, "OLLAMA_API_KEY", nothing)
    isnothing(key) && throw(ArgumentError("OLLAMA_API_KEY environment variable or api_key parameter is required"))

    api_url = "$OLLAMA_CLOUD_API/api/web_fetch"
    headers = [
        "Content-Type" => "application/json",
        "Authorization" => "Bearer $key"
    ]
    body = Dict("url" => url)

    try
        response = HTTP.request("POST", api_url, headers, JSON3.write(body))
        data = JSON3.read(String(response.body))
        return WebFetchResponse(
            data.title,
            data.content,
            Vector{String}(data.links)
        )
    catch e
        if e isa HTTP.StatusError
            error_body = JSON3.read(String(e.response.body))
            throw(OllamaError(get(error_body, :error, "Unknown error"), e.status))
        else
            rethrow(e)
        end
    end
end

function FlootyAbstract.web_search_tool(provider::OllamaWebSearchProvider)
    params = [
        ToolParameter("query", "string", "The search query string"; required=true),
        ToolParameter("max_results", "integer", "Maximum number of results (1-10)"; required=false)
    ]

    OllamaTool(
        "function",
        OllamaFunction(
            "web_search",
            "Search the web for current information on any topic",
            params
        )
    )
end

function FlootyAbstract.web_fetch_tool(provider::OllamaWebSearchProvider)
    params = [
        ToolParameter("url", "string", "The URL to fetch content from"; required=true)
    ]

    OllamaTool(
        "function",
        OllamaFunction(
            "web_fetch",
            "Fetch and extract content from a specific web page URL",
            params
        )
    )
end

# Legacy convenience functions using default provider
web_search(query::String; kw...) = FlootyAbstract.web_search(default_web_search_provider(), query; kw...)
web_fetch(url::String; kw...) = FlootyAbstract.web_fetch(default_web_search_provider(), url; kw...)
web_search_tool() = FlootyAbstract.web_search_tool(default_web_search_provider())
web_fetch_tool() = FlootyAbstract.web_fetch_tool(default_web_search_provider())
