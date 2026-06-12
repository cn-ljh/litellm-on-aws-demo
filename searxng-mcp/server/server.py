"""SearXNG MCP server.

Wraps a SearXNG instance's /search?format=json endpoint as an MCP tool over
streamable-HTTP transport. Runs stateless so any LiteLLM replica can call it
without session affinity.

Env:
  SEARXNG_URL  base URL of the SearXNG instance (default http://localhost:8080)
  MCP_PORT     listen port (default 8000)
"""

import os
from typing import Annotated

import httpx
from mcp.server.fastmcp import FastMCP
from pydantic import Field

SEARXNG_URL = os.environ.get("SEARXNG_URL", "http://localhost:8080").rstrip("/")
MCP_PORT = int(os.environ.get("MCP_PORT", "8000"))

mcp = FastMCP(
    "searxng",
    host="0.0.0.0",
    port=MCP_PORT,
    stateless_http=True,
    json_response=True,
)


@mcp.custom_route("/health", methods=["GET"])
async def health(_request):
    """Container/LB health check: verifies SearXNG itself is reachable."""
    from starlette.responses import JSONResponse

    try:
        async with httpx.AsyncClient(timeout=5) as client:
            r = await client.get(f"{SEARXNG_URL}/healthz")
            r.raise_for_status()
        return JSONResponse({"status": "ok"})
    except Exception as e:  # noqa: BLE001
        return JSONResponse({"status": "degraded", "error": str(e)}, status_code=503)


@mcp.tool()
async def web_search(
    query: Annotated[str, Field(description="The search query")],
    max_results: Annotated[
        int, Field(description="Maximum number of results to return", ge=1, le=20)
    ] = 8,
    language: Annotated[
        str, Field(description="Search language code, e.g. 'en', 'zh-CN', or 'all'")
    ] = "all",
    time_range: Annotated[
        str,
        Field(description="Restrict results by age: '', 'day', 'week', 'month', 'year'"),
    ] = "",
    category: Annotated[
        str,
        Field(description="Search category: 'general', 'news', 'images', 'it', 'science'"),
    ] = "general",
) -> str:
    """Search the web via a self-hosted SearXNG metasearch instance
    (aggregates Google, Bing, DuckDuckGo, Brave and other public engines).
    Returns titles, URLs and content snippets for the top results."""
    params = {
        "q": query,
        "format": "json",
        "language": language,
        "categories": category,
        "safesearch": "0",
    }
    if time_range in ("day", "week", "month", "year"):
        params["time_range"] = time_range

    async with httpx.AsyncClient(timeout=20) as client:
        resp = await client.get(f"{SEARXNG_URL}/search", params=params)
        resp.raise_for_status()
        data = resp.json()

    results = data.get("results", [])[:max_results]
    if not results:
        return f"No results found for: {query}"

    lines = []
    for i, r in enumerate(results, 1):
        title = r.get("title", "(no title)")
        url = r.get("url", "")
        content = (r.get("content") or "").strip()
        published = r.get("publishedDate") or ""
        engine = r.get("engine", "")
        entry = f"{i}. {title}\n   URL: {url}"
        if published:
            entry += f"\n   Published: {published}"
        if content:
            entry += f"\n   {content}"
        if engine:
            entry += f"\n   (source engine: {engine})"
        lines.append(entry)

    answers = data.get("answers") or []
    header = ""
    if answers:
        header = "Direct answers: " + "; ".join(str(a) for a in answers) + "\n\n"

    return header + f"Search results for '{query}':\n\n" + "\n\n".join(lines)


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
