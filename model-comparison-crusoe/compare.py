"""
Multi-model comparison on Crusoe Managed Inference.
Benchmark multiple models across quality, latency, and throughput.
Tested locally with Groq as a drop-in replacement for Crusoe.
"""
import os
import time
import asyncio
from dotenv import load_dotenv
from langchain_core.messages import HumanMessage

load_dotenv()

# Models available on Crusoe Managed Inference
CRUSOE_MODELS = [
    "meta-llama/Llama-3.3-70B-Instruct",
    "deepseek-ai/DeepSeek-V3-0324",
    "Qwen/Qwen3-235B-A22B",
]

# Free Groq models for local testing (all verified active)
GROQ_MODELS = [
    "llama-3.3-70b-versatile",
    "llama-3.1-8b-instant",
    "meta-llama/llama-4-scout-17b-16e-instruct",
]

TASKS = [
    {
        "name": "Reasoning",
        "prompt": "If a train travels 120 miles in 2 hours, then stops for 30 minutes, then travels 90 miles in 1.5 hours, what is the average speed for the entire journey including the stop?",
    },
    {
        "name": "Code generation",
        "prompt": "Write a Python function that finds all prime numbers up to n using the Sieve of Eratosthenes. Include type hints and a docstring.",
    },
    {
        "name": "Summarization",
        "prompt": "Summarize the key tradeoffs between SQL and NoSQL databases in exactly 3 bullet points.",
    },
]


def get_llm(model: str):
    if os.getenv("CRUSOE_API_KEY"):
        from langchain_crusoe import ChatCrusoe
        return ChatCrusoe(model=model, temperature=0.3, max_tokens=512)
    else:
        from langchain_groq import ChatGroq
        return ChatGroq(model=model, temperature=0.3, max_tokens=512)


def get_models():
    if os.getenv("CRUSOE_API_KEY"):
        return CRUSOE_MODELS
    return GROQ_MODELS


async def run_task(model: str, task: dict) -> dict:
    """Run a single task on a single model and return metrics."""
    llm = get_llm(model)
    start = time.time()
    response = await llm.ainvoke([HumanMessage(content=task["prompt"])])
    elapsed = time.time() - start
    output = response.content
    word_count = len(output.split())
    return {
        "model": model.split("/")[-1],
        "task": task["name"],
        "latency": round(elapsed, 2),
        "words": word_count,
        "wps": round(word_count / elapsed, 1),
        "output": output,
    }


async def run_all_comparisons():
    models = get_models()
    print("Multi-Model Comparison on Crusoe Managed Inference")
    print("=" * 60)
    print(f"Models: {len(models)} | Tasks: {len(TASKS)}\n")

    jobs = [
        run_task(model, task)
        for model in models
        for task in TASKS
    ]
    results = await asyncio.gather(*jobs)

    # Results by task
    for task in TASKS:
        print(f"\nTASK: {task['name']}")
        print("-" * 60)
        task_results = [r for r in results if r["task"] == task["name"]]
        task_results.sort(key=lambda x: x["latency"])
        for r in task_results:
            print(f"  {r['model']:<45} {r['latency']}s | {r['words']} words | {r['wps']} wps")

    # Leaderboard
    print("\n" + "=" * 60)
    print("LEADERBOARD (average latency across all tasks)")
    print("=" * 60)
    model_names = list({r["model"] for r in results})
    leaderboard = []
    for name in model_names:
        model_results = [r for r in results if r["model"] == name]
        avg_latency = round(sum(r["latency"] for r in model_results) / len(model_results), 2)
        avg_wps = round(sum(r["wps"] for r in model_results) / len(model_results), 1)
        leaderboard.append((name, avg_latency, avg_wps))
    leaderboard.sort(key=lambda x: x[1])

    for i, (name, lat, wps) in enumerate(leaderboard):
        medal = ["1st", "2nd", "3rd"][i] if i < 3 else f"{i+1}th"
        print(f"  {medal}  {name:<43} avg {lat}s | {wps} wps")

    # Sample outputs
    print("\n" + "=" * 60)
    print("SAMPLE OUTPUTS: Code generation")
    print("=" * 60)
    code_results = [r for r in results if r["task"] == "Code generation"]
    for r in code_results:
        print(f"\n--- {r['model']} ---")
        print(r["output"][:400] + "..." if len(r["output"]) > 400 else r["output"])


if __name__ == "__main__":
    asyncio.run(run_all_comparisons())
