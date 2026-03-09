"""
AI Client — Multi-Model Ensemble Code Review
=============================================
Integrates:
  - langchain-crusoe  (ChatCrusoe) for streaming LLM inference
  - mlflow-crusoe     for deployment management and experiment tracking
  - MCP              for static analysis tools

Flow:
  1. Ensure MLflow Crusoe deployments exist for all models
  2. Run MCP tools once (deterministic)
  3. All models review in parallel via ChatCrusoe (streamed)
  4. Kimi-K2-Thinking synthesizes into one optimal final review
  5. Log everything to MLflow

Run with:  uv run python ai_client.py
Set env:   export CRUSOE_API_KEY='<your-api-key>'
"""

import asyncio
import os
import time

import mlflow
from langchain_core.messages import HumanMessage, SystemMessage
from langchain_crusoe import ChatCrusoe
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

# ─── Config ───────────────────────────────────────────────────────────────────

SYNTHESIS_MODEL = "moonshotai/Kimi-K2-Thinking"

# Add or remove models here as you get access to them in Crusoe
MODELS = [
    "moonshotai/Kimi-K2-Thinking",
]

MLFLOW_EXPERIMENT = "code-review-mcp"


# ─── Helpers ──────────────────────────────────────────────────────────────────

def deployment_name(model: str) -> str:
    """Convert a model ID to a safe artifact/file name."""
    return model.replace("/", "--")


# ─── MCP helpers ──────────────────────────────────────────────────────────────

async def run_all_tools(session: ClientSession, code: str) -> dict[str, str]:
    """Run all three MCP tools and return their results."""
    results = {}
    for tool_name in ["analyze_code", "check_security", "suggest_tests"]:
        result = await session.call_tool(tool_name, {"code": code})
        results[tool_name] = result.content[0].text
    return results


# ─── Per-model review ─────────────────────────────────────────────────────────

def get_model_review(model: str, code: str, tool_results: dict[str, str]) -> str:
    """Ask one ChatCrusoe model to review the code, streamed."""
    tool_summary = "\n\n".join(
        f"### {name}\n```json\n{result}\n```"
        for name, result in tool_results.items()
    )

    llm = ChatCrusoe(model=model)

    messages = [
        SystemMessage(content=(
            "You are a code review expert. You will be given the output of "
            "three static analysis tools. Synthesize them into a clear, "
            "prioritized, actionable code review with specific fix suggestions."
        )),
        HumanMessage(content=(
            f"Here is the code:\n\n```python\n{code}\n```\n\n"
            f"Here are the analysis results:\n\n{tool_summary}\n\n"
            "Please provide your review."
        )),
    ]

    print(f"\n--- {model} ---")
    chunks = []
    for chunk in llm.stream(messages):
        print(chunk.content, end="", flush=True)
        chunks.append(chunk.content)
    print()
    return "".join(chunks)


# ─── Final synthesis ──────────────────────────────────────────────────────────

def synthesize_reviews(reviews: dict[str, str], code: str) -> str:
    """Synthesize all model reviews into one optimal final review."""
    all_reviews = "\n\n".join(
        f"### Review from {model}:\n{review}"
        for model, review in reviews.items()
    )

    llm = ChatCrusoe(model=SYNTHESIS_MODEL)

    messages = [
        SystemMessage(content=(
            "You are a senior engineer synthesizing multiple AI code reviews "
            "into one optimal, non-redundant, prioritized review. "
            "Combine the best insights, eliminate duplicates, and present "
            "clear actionable findings with concrete fix suggestions."
        )),
        HumanMessage(content=(
            f"The following code was reviewed by multiple models:\n\n"
            f"```python\n{code}\n```\n\n"
            f"Here are all their reviews:\n\n{all_reviews}\n\n"
            "Synthesize these into one optimal final review."
        )),
    ]

    print(f"\n--- {SYNTHESIS_MODEL} (synthesis) ---")
    chunks = []
    for chunk in llm.stream(messages):
        print(chunk.content, end="", flush=True)
        chunks.append(chunk.content)
    print()
    return "".join(chunks)


# ─── Main ─────────────────────────────────────────────────────────────────────

async def main():
    if not os.environ.get("CRUSOE_API_KEY"):
        print("Error: CRUSOE_API_KEY environment variable is not set.")
        print("Run: export CRUSOE_API_KEY='<your-api-key>'")
        return

    # Set up MLflow experiment + enable LangChain auto-tracing
    mlflow.set_tracking_uri("sqlite:///mlflow.db")
    mlflow.set_experiment(MLFLOW_EXPERIMENT)
    mlflow.langchain.autolog()

    print(f"Using {len(MODELS)} model(s): {', '.join(MODELS)}\n")

    # Get code input
    print("Paste the Python code to review (then press Enter twice):")
    lines = []
    while True:
        line = input()
        if line == "" and lines and lines[-1] == "":
            break
        lines.append(line)
    code = "\n".join(lines[:-1])
    print(f"\n[received] {len(code.splitlines())} lines of code\n")

    server_params = StdioServerParameters(
        command="python",
        args=["server.py"],
    )

    with mlflow.start_run():
        # Log inputs
        mlflow.log_param("models", ", ".join(MODELS))
        mlflow.log_param("lines_of_code", len(code.splitlines()))
        mlflow.log_text(code, "input_code.py")

        async with stdio_client(server_params) as (read_stream, write_stream):
            async with ClientSession(read_stream, write_stream) as session:
                await session.initialize()

                # Step 1: Run MCP tools once
                print("[1/3] Running MCP analysis tools...")
                t0 = time.time()
                tool_results = await run_all_tools(session, code)
                tool_duration = time.time() - t0

                for name in tool_results:
                    print(f"  {name} ✓")
                    mlflow.log_text(tool_results[name], f"tool_{name}.json")

                mlflow.log_metric("tool_analysis_seconds", round(tool_duration, 2))

        # Step 2: All models review in parallel
        print(f"\n[2/3] Getting reviews from {len(MODELS)} model(s) in parallel...")
        loop = asyncio.get_event_loop()
        t0 = time.time()

        async def get_review_async(model: str) -> tuple[str, str]:
            print(f"  {model} — thinking...")
            review = await loop.run_in_executor(
                None, get_model_review, model, code, tool_results
            )
            print(f"  {model} ✓")
            return model, review

        review_pairs = await asyncio.gather(*[get_review_async(m) for m in MODELS])
        reviews = dict(review_pairs)
        mlflow.log_metric("review_seconds", round(time.time() - t0, 2))

        for model, review in reviews.items():
            mlflow.log_text(review, f"review_{deployment_name(model)}.md")

        # Step 3: Synthesize or display
        if len(reviews) == 1:
            final_review = next(iter(reviews.values()))
            print("\n" + "=" * 60)
            print("  CODE REVIEW")
            print("=" * 60)
            print(final_review)
        else:
            print(f"\n[3/3] Synthesizing optimal review with {SYNTHESIS_MODEL}...")
            t0 = time.time()
            final_review = await loop.run_in_executor(
                None, synthesize_reviews, reviews, code
            )
            mlflow.log_metric("synthesis_seconds", round(time.time() - t0, 2))
            print("\n" + "=" * 60)
            print("  OPTIMAL CODE REVIEW")
            print("=" * 60)
            print(final_review)

        mlflow.log_text(final_review, "final_review.md")
        print(f"\n[mlflow] Run logged to experiment '{MLFLOW_EXPERIMENT}'")
        print("[mlflow] View runs with: uv run mlflow ui")


if __name__ == "__main__":
    asyncio.run(main())
