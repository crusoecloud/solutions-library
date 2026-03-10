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
  5. Log everything to MLflow (tracking, artifacts, registry, evaluations)

Run with:  uv run python ai_client.py
Set env:   export CRUSOE_API_KEY='<your-api-key>'
"""

import asyncio
import json
import os
import random
import time

import mlflow
import mlflow.deployments
import mlflow.pyfunc
from mlflow import MlflowClient
from langchain_core.messages import HumanMessage, SystemMessage
from langchain_crusoe import ChatCrusoe
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

# ─── Config ───────────────────────────────────────────────────────────────────

SYNTHESIS_MODEL = "moonshotai/Kimi-K2-Thinking"

# Add or remove models here as you get access to them in Crusoe
MODELS = [
    "moonshotai/Kimi-K2-Thinking",
    "Qwen/Qwen3-235B-A22B-Instruct-2507",
    "deepseek-ai/DeepSeek-V3-0324",
    "meta-llama/Llama-3.3-70B-Instruct",
    "openai/gpt-oss-120b",
    "google/gemma-3-12b-it",
    "deepseek-ai/DeepSeek-R1-0528",
]

MLFLOW_EXPERIMENT = "code-review-mcp"
MODEL_REGISTRY_NAME = "code-reviewer-ensemble"

MAX_RETRIES = 3          # attempts per LLM call
SYNTHESIS_COOLDOWN = 4   # seconds to wait after parallel reviews before synthesis


# ─── Helpers ──────────────────────────────────────────────────────────────────

def deployment_name(model: str) -> str:
    """Convert a model ID to a safe artifact/file name."""
    return model.replace("/", "--")


def ensure_deployments() -> mlflow.deployments.BaseDeploymentClient:
    """Create MLflow Crusoe deployments for each model if they don't exist."""
    client = mlflow.deployments.get_deploy_client("crusoe")
    existing = {d["name"] for d in client.list_deployments()}

    for model in MODELS:
        name = deployment_name(model)
        if name not in existing:
            client.create_deployment(
                name=name,
                model_uri=model,
                config={"temperature": 0.7, "max_tokens": 4096},
            )
            print(f"  [mlflow-crusoe] Created deployment: {name}")
        else:
            print(f"  [mlflow-crusoe] Deployment exists: {name}")

    return client


# ─── MCP helpers ──────────────────────────────────────────────────────────────

async def run_all_tools(session: ClientSession, code: str) -> dict[str, str]:
    """Run all three MCP tools and return their results."""
    results = {}
    for tool_name in ["analyze_code", "check_security", "suggest_tests"]:
        result = await session.call_tool(tool_name, {"code": code})
        results[tool_name] = result.content[0].text
    return results


# ─── LLM streaming with retry ────────────────────────────────────────────────

_TRANSIENT_SIGNALS = ("cloudflare", "blocked", "rate limit", "429", "502", "503", "529")


def _stream_with_retry(llm, messages, label: str) -> str:
    """Stream an LLM response, retrying on transient Cloudflare / rate-limit errors."""
    for attempt in range(MAX_RETRIES):
        try:
            chunks = []
            for chunk in llm.stream(messages):
                print(chunk.content, end="", flush=True)
                chunks.append(chunk.content)
            print()
            return "".join(chunks)
        except Exception as e:
            err_lower = str(e).lower()
            is_transient = any(sig in err_lower for sig in _TRANSIENT_SIGNALS)
            if is_transient and attempt < MAX_RETRIES - 1:
                delay = 2.0 * (2 ** attempt) + random.uniform(0, 1.5)
                print(f"\n  [{label}] blocked — retrying in {delay:.1f}s (attempt {attempt + 1}/{MAX_RETRIES - 1})...")
                time.sleep(delay)
            else:
                raise


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
    return _stream_with_retry(llm, messages, model)


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
    return _stream_with_retry(llm, messages, "synthesis")


# ─── MLflow: Registry & Model Management ─────────────────────────────────────

class _CodeReviewPipeline(mlflow.pyfunc.PythonModel):
    """Pyfunc wrapper that records the pipeline configuration in the Model Registry."""

    def predict(self, context, model_input):
        return {
            "note": "Live API model — run ai_client.py to perform code reviews.",
            "models": MODELS,
            "synthesis_model": SYNTHESIS_MODEL,
        }


def register_pipeline_model(run_id: str) -> None:
    """Register the logged pyfunc model to the MLflow Model Registry."""
    model_uri = f"runs:/{run_id}/code_reviewer"
    mv = mlflow.register_model(model_uri, MODEL_REGISTRY_NAME)
    client = MlflowClient()
    client.update_registered_model(
        MODEL_REGISTRY_NAME,
        description="Multi-model ensemble code review pipeline using MCP tools and Crusoe LLMs.",
    )
    client.set_model_version_tag(MODEL_REGISTRY_NAME, mv.version, "pipeline", "mcp-code-review")
    client.set_registered_model_alias(MODEL_REGISTRY_NAME, "staging", str(mv.version))
    print(f"  [mlflow] Registered '{MODEL_REGISTRY_NAME}' v{mv.version} → @staging")


# ─── MLflow: Evaluations ──────────────────────────────────────────────────────

_KEY_TOPICS = ["security", "performance", "test", "error", "bug", "fix", "suggest", "recommend"]


def _score_completeness(text: str) -> float:
    """Return the fraction of key review topics present in text (0–1)."""
    lower = text.lower()
    return sum(1 for kw in _KEY_TOPICS if kw in lower) / len(_KEY_TOPICS)


def evaluate_review(final_review: str) -> None:
    """Compute and log quality metrics for the final review."""
    completeness = _score_completeness(final_review)
    word_count = len(final_review.split())
    mlflow.log_metrics({
        "final_review_completeness": round(completeness, 3),
        "final_review_word_count": word_count,
    })
    print(f"  [mlflow] Evaluation — completeness: {completeness:.2f}, words: {word_count}")


# ─── Main ─────────────────────────────────────────────────────────────────────

async def main():
    if not os.environ.get("CRUSOE_API_KEY"):
        print("Error: CRUSOE_API_KEY environment variable is not set.")
        print("Run: export CRUSOE_API_KEY='<your-api-key>'")
        return

    # Set up MLflow
    mlflow.set_tracking_uri("sqlite:///mlflow.db")
    mlflow.set_experiment(MLFLOW_EXPERIMENT)
    mlflow.langchain.autolog()

    # Ensure deployments exist
    print("Checking MLflow Crusoe deployments...")
    ensure_deployments()

    print(f"\nUsing {len(MODELS)} model(s): {', '.join(MODELS)}\n")

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

    with mlflow.start_run() as run:
        mlflow.log_param("models", ", ".join(MODELS))
        mlflow.log_param("lines_of_code", len(code.splitlines()))
        mlflow.log_param("synthesis_model", SYNTHESIS_MODEL)
        mlflow.set_tags({
            "num_models": str(len(MODELS)),
            "pipeline": "mcp-code-review",
        })
        mlflow.log_text(code, "input_code.py")
        mlflow.pyfunc.log_model(artifact_path="code_reviewer", python_model=_CodeReviewPipeline())

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

        review_times: dict[str, float] = {}

        async def get_review_async(model: str) -> tuple[str, str]:
            print(f"  {model} — thinking...")
            t_start = time.time()
            review = await loop.run_in_executor(
                None, get_model_review, model, code, tool_results
            )
            review_times[model] = round(time.time() - t_start, 2)
            print(f"  {model} ✓  ({review_times[model]}s)")
            return model, review

        review_pairs = await asyncio.gather(*[get_review_async(m) for m in MODELS])
        reviews = dict(review_pairs)
        mlflow.log_metric("review_seconds", round(time.time() - t0, 2))

        # Per-model metrics + comparison artifact
        comparison: dict[str, dict] = {}
        for model, review in reviews.items():
            safe = deployment_name(model)
            words = len(review.split())
            completeness = _score_completeness(review)
            latency = review_times.get(model, 0.0)
            mlflow.log_metrics({
                f"words_{safe}": words,
                f"completeness_{safe}": round(completeness, 3),
                f"latency_s_{safe}": latency,
            })
            mlflow.log_text(review, f"review_{safe}.md")
            comparison[model] = {
                "word_count": words,
                "completeness": round(completeness, 3),
                "latency_seconds": latency,
            }
        mlflow.log_dict(comparison, "model_comparison.json")

        # Step 3: Synthesize or display
        if len(reviews) == 1:
            final_review = next(iter(reviews.values()))
            print("\n" + "=" * 60)
            print("  CODE REVIEW")
            print("=" * 60)
            print(final_review)
        else:
            print(f"\n[3/3] Cooling down {SYNTHESIS_COOLDOWN}s before synthesis...")
            await asyncio.sleep(SYNTHESIS_COOLDOWN)
            print(f"Synthesizing optimal review with {SYNTHESIS_MODEL}...")
            t0 = time.time()
            try:
                final_review = await loop.run_in_executor(
                    None, synthesize_reviews, reviews, code
                )
                mlflow.log_metric("synthesis_seconds", round(time.time() - t0, 2))
                mlflow.set_tag("synthesis_status", "ok")
                print("\n" + "=" * 60)
                print("  OPTIMAL CODE REVIEW  (synthesized)")
                print("=" * 60)
            except Exception as exc:
                print(f"\n  [synthesis] Failed after all retries ({type(exc).__name__}). "
                      "Falling back to the most thorough individual review.")
                mlflow.set_tag("synthesis_status", "failed")
                mlflow.set_tag("synthesis_error", type(exc).__name__)
                # Pick the longest review as the most thorough fallback
                best_model = max(reviews, key=lambda m: len(reviews[m]))
                final_review = reviews[best_model]
                print("\n" + "=" * 60)
                print(f"  BEST INDIVIDUAL REVIEW  ({best_model})")
                print("=" * 60)
            print(final_review)

        mlflow.log_text(final_review, "final_review.md")

        # Structured summary artifact
        total_issues = (
            json.loads(tool_results.get("analyze_code", "{}")).get("total_issues", 0)
            + json.loads(tool_results.get("check_security", "{}")).get("total_vulnerabilities", 0)
        )
        mlflow.log_dict(
            {
                "models": MODELS,
                "synthesis_model": SYNTHESIS_MODEL,
                "total_tool_issues": total_issues,
                "lines_of_code": len(code.splitlines()),
            },
            "run_summary.json",
        )

        # Evaluations
        print("[4/4] Evaluating review quality...")
        evaluate_review(final_review)

        print(f"\n[mlflow] Run logged to experiment '{MLFLOW_EXPERIMENT}'")
        print("[mlflow] View runs with: uv run mlflow ui --backend-store-uri sqlite:///mlflow.db")

    # Register model to MLflow Model Registry (outside active run)
    print("\nRegistering model to MLflow Model Registry...")
    register_pipeline_model(run.info.run_id)


if __name__ == "__main__":
    asyncio.run(main())
