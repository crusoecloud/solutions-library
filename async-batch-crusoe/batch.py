"""
Async batch inference on Crusoe Managed Inference.
Run multiple prompts concurrently, measure throughput, and compare
sequential vs parallel execution times.
Tested locally with Groq as a drop-in replacement for Crusoe.
"""
import os
import asyncio
import time
from dotenv import load_dotenv
from langchain_core.messages import HumanMessage, SystemMessage

load_dotenv()


def get_llm():
    if os.getenv("CRUSOE_API_KEY"):
        from langchain_crusoe import ChatCrusoe
        return ChatCrusoe(
            model="meta-llama/Llama-3.3-70B-Instruct",
            temperature=0.3,
            max_tokens=256,
        )
    else:
        from langchain_groq import ChatGroq
        return ChatGroq(
            model="llama-3.3-70b-versatile",
            temperature=0.3,
            max_tokens=256,
        )


PROMPTS = [
    "In 2 sentences: what is gradient descent?",
    "In 2 sentences: what is attention mechanism in transformers?",
    "In 2 sentences: what is a CUDA kernel?",
    "In 2 sentences: what is model quantization?",
    "In 2 sentences: what is reinforcement learning from human feedback?",
    "In 2 sentences: what is a mixture of experts model?",
    "In 2 sentences: what is speculative decoding?",
    "In 2 sentences: what is flash attention?",
]


def run_sequential(prompts: list[str]) -> tuple[list[str], float]:
    """Run prompts one at a time and measure total time."""
    llm = get_llm()
    results = []
    start = time.time()
    for prompt in prompts:
        response = llm.invoke([HumanMessage(content=prompt)])
        results.append(response.content)
    elapsed = time.time() - start
    return results, elapsed


async def run_parallel(prompts: list[str]) -> tuple[list[str], float]:
    """Run all prompts concurrently and measure total time."""
    llm = get_llm()

    async def call_one(prompt: str) -> str:
        response = await llm.ainvoke([HumanMessage(content=prompt)])
        return response.content

    start = time.time()
    results = await asyncio.gather(*[call_one(p) for p in prompts])
    elapsed = time.time() - start
    return list(results), elapsed


async def run_batched(prompts: list[str], batch_size: int = 4) -> tuple[list[str], float]:
    """Run prompts in controlled batches to balance speed and rate limits."""
    llm = get_llm()
    all_results = []

    async def call_one(prompt: str) -> str:
        response = await llm.ainvoke([HumanMessage(content=prompt)])
        return response.content

    start = time.time()
    for i in range(0, len(prompts), batch_size):
        batch = prompts[i:i + batch_size]
        batch_results = await asyncio.gather(*[call_one(p) for p in batch])
        all_results.extend(batch_results)
        print(f"  Batch {i // batch_size + 1} complete ({len(batch)} prompts)")
    elapsed = time.time() - start
    return all_results, elapsed


async def main():
    print("Async Batch Inference on Crusoe Managed Inference")
    print("=" * 60)
    print(f"Total prompts: {len(PROMPTS)}\n")

    # Sequential
    print("Running SEQUENTIAL (one at a time)...")
    seq_results, seq_time = run_sequential(PROMPTS)
    print(f"Sequential time: {seq_time:.2f}s\n")

    # Parallel
    print("Running PARALLEL (all at once)...")
    par_results, par_time = await run_parallel(PROMPTS)
    print(f"Parallel time:   {par_time:.2f}s\n")

    # Batched
    print("Running BATCHED (4 at a time)...")
    bat_results, bat_time = await run_batched(PROMPTS, batch_size=4)
    print(f"Batched time:    {bat_time:.2f}s\n")

    # Summary
    print("=" * 60)
    print("RESULTS SUMMARY")
    print("=" * 60)
    print(f"Sequential: {seq_time:.2f}s")
    print(f"Parallel:   {par_time:.2f}s  ({seq_time/par_time:.1f}x faster)")
    print(f"Batched:    {bat_time:.2f}s  ({seq_time/bat_time:.1f}x faster)")
    print()

    print("SAMPLE ANSWERS (parallel run):")
    print("-" * 60)
    for i, (prompt, result) in enumerate(zip(PROMPTS[:3], par_results[:3])):
        print(f"\nQ{i+1}: {prompt}")
        print(f"A{i+1}: {result}")


if __name__ == "__main__":
    asyncio.run(main())
