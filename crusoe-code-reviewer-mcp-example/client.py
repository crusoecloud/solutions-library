"""
MCP Client Example — Connects to the Code Review Server
========================================================
Demonstrates how to programmatically connect to an MCP server,
discover its tools, and invoke them.

Run with:  python client.py
(Make sure server.py is in the same directory)
"""

import asyncio
import json
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main():
    # ─── Step 1: Define how to connect to the server ──────────────────────
    # StdioServerParameters tells the client how to launch the MCP server.
    # The client will spawn this as a subprocess and talk over stdin/stdout.

    server_params = StdioServerParameters(
        command="python",
        args=["server.py"],  # Path to your MCP server
    )

    # ─── Step 2: Connect to the server ────────────────────────────────────
    # stdio_client handles the subprocess lifecycle.
    # ClientSession manages the MCP protocol handshake.

    print("=" * 60)
    print("  MCP Client — Code Review Demo")
    print("=" * 60)
    print()

    async with stdio_client(server_params) as (read_stream, write_stream):
        async with ClientSession(read_stream, write_stream) as session:

            # Initialize the connection (protocol handshake)
            await session.initialize()
            print("[connected] MCP session established\n")

            # ─── Step 3: Discover what the server offers ──────────────
            # List all available tools, resources, and prompts.

            # --- Tools ---
            tools_result = await session.list_tools()
            print("AVAILABLE TOOLS:")
            print("-" * 40)
            for tool in tools_result.tools:
                print(f"  {tool.name}")
                print(f"    {tool.description.splitlines()[0]}")
                print()

            # --- Resources ---
            resources_result = await session.list_resources()
            print("AVAILABLE RESOURCES:")
            print("-" * 40)
            for resource in resources_result.resources:
                print(f"  {resource.uri}")
                print(f"    {resource.description}")
                print()

            # --- Prompts ---
            prompts_result = await session.list_prompts()
            print("AVAILABLE PROMPTS:")
            print("-" * 40)
            for prompt in prompts_result.prompts:
                print(f"  {prompt.name}")
                print(f"    {prompt.description}")
                print()

            # ─── Step 4: Read a resource ──────────────────────────────
            print("=" * 60)
            print("  Reading review rules resource...")
            print("=" * 60)

            rules = await session.read_resource("config://review-rules")
            print(rules.contents[0].text)
            print()

            # ─── Step 5: Call tools with sample code ──────────────────
            # This is the core of MCP — invoking tools and getting results.

            sample_code = '''
import os
import json
import sys  # unused import

API_KEY = "sk-1234567890abcdef"  # hardcoded secret!

def get_user(user_id):
    # TODO: add input validation
    query = f"SELECT * FROM users WHERE id = {user_id}"
    cursor.execute(query)
    return cursor.fetchone()

def process_data(data):
    try:
        result = eval(data)  # dangerous!
        return result
    except:  # bare except
        return None

def calculate_total(items):
    total = 0
    for item in items:
        total += item["price"] * item["quantity"]
    return total
'''

            print("=" * 60)
            print("  SAMPLE CODE TO REVIEW")
            print("=" * 60)
            print(sample_code)

            # --- Tool 1: analyze_code ---
            print("=" * 60)
            print("  Tool: analyze_code")
            print("=" * 60)

            result = await session.call_tool("analyze_code", {"code": sample_code})
            analysis = json.loads(result.content[0].text)
            print(json.dumps(analysis, indent=2))
            print()

            # --- Tool 2: check_security ---
            print("=" * 60)
            print("  Tool: check_security")
            print("=" * 60)

            result = await session.call_tool("check_security", {"code": sample_code})
            security = json.loads(result.content[0].text)
            print(json.dumps(security, indent=2))
            print()

            # --- Tool 3: suggest_tests ---
            print("=" * 60)
            print("  Tool: suggest_tests")
            print("=" * 60)

            result = await session.call_tool("suggest_tests", {"code": sample_code})
            tests = json.loads(result.content[0].text)
            print(json.dumps(tests, indent=2))
            print()

            # ─── Step 6: Use a prompt template ────────────────────────
            print("=" * 60)
            print("  Prompt template: full_review")
            print("=" * 60)

            prompt_result = await session.get_prompt(
                "full_review", {"code": "def add(a, b): return a + b"}
            )
            print("Generated prompt:")
            print(prompt_result.messages[0].content.text)
            print()

            # ─── Summary ─────────────────────────────────────────────
            total_issues = analysis.get("total_issues", 0)
            total_vulns = security.get("total_vulnerabilities", 0)
            total_tests = tests.get("total_functions", 0)

            print("=" * 60)
            print("  REVIEW SUMMARY")
            print("=" * 60)
            print(f"  Code issues found:      {total_issues}")
            print(f"  Security vulns found:   {total_vulns}")
            print(f"  Test stubs generated:   {total_tests}")
            print("=" * 60)


if __name__ == "__main__":
    asyncio.run(main())
