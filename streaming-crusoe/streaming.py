"""
Real-time streaming output from Crusoe Managed Inference.
Demonstrates token streaming, async streaming, and streaming with callbacks.
Tested locally with Groq as a drop-in replacement for Crusoe.
"""
import os
import asyncio
import time
from dotenv import load_dotenv
from langchain_core.messages import HumanMessage, SystemMessage
from langchain_core.callbacks import StreamingStdOutCallbackHandler

load_dotenv()


def get_llm(streaming: bool = False, callbacks=None):
    if os.getenv("CRUSOE_API_KEY"):
        from langchain_crusoe import ChatCrusoe
        return ChatCrusoe(
            model="meta-llama/Llama-3.3-70B-Instruct",
            temperature=0.7,
            max_tokens=512,
            streaming=streaming,
            callbacks=callbacks or [],
        )
    else:
        from langchain_groq import ChatGroq
        return ChatGroq(
            model="llama-3.3-70b-versatile",
            temperature=0.7,
            max_tokens=512,
            streaming=streaming,
            callbacks=callbacks or [],
        )


def demo_basic_streaming():
    """Demo 1: Stream tokens to stdout as they arrive."""
    print("=" * 60)
    print("DEMO 1: Basic token streaming")
    print("=" * 60)
    llm = get_llm()
    prompt = "Explain how GPU clusters accelerate deep learning training in 5 steps."

    print(f"Prompt: {prompt}\n")
    print("Response (streaming):")

    start = time.time()
    token_count = 0
    for chunk in llm.stream([HumanMessage(content=prompt)]):
        print(chunk.content, end="", flush=True)
        if chunk.content:
            token_count += 1
    elapsed = time.time() - start
    print(f"\n\nTokens streamed: {token_count} | Time: {elapsed:.2f}s")


def demo_streaming_with_callback():
    """Demo 2: Stream using a callback handler."""
    print("\n" + "=" * 60)
    print("DEMO 2: Streaming with callback handler")
    print("=" * 60)
    print("Response (via StreamingStdOutCallbackHandler):\n")

    llm = get_llm(
        streaming=True,
        callbacks=[StreamingStdOutCallbackHandler()]
    )
    llm.invoke([
        SystemMessage(content="You are a concise technical writer."),
        HumanMessage(content="What is MemoryAlloy KV cache sharing and why does it matter for LLM inference?")
    ])
    print()


async def demo_async_streaming():
    """Demo 3: Async streaming for non-blocking token generation."""
    print("\n" + "=" * 60)
    print("DEMO 3: Async streaming")
    print("=" * 60)
    llm = get_llm()
    prompt = "List 5 best practices for deploying LLMs in production."

    print(f"Prompt: {prompt}\n")
    print("Response (async streaming):")

    start = time.time()
    async for chunk in llm.astream([HumanMessage(content=prompt)]):
        print(chunk.content, end="", flush=True)
    elapsed = time.time() - start
    print(f"\n\nTime: {elapsed:.2f}s")


async def demo_concurrent_streaming():
    """Demo 4: Stream multiple prompts concurrently."""
    print("\n" + "=" * 60)
    print("DEMO 4: Concurrent async streaming (3 prompts at once)")
    print("=" * 60)

    prompts = [
        "In one sentence: what is a vector database?",
        "In one sentence: what is retrieval-augmented generation?",
        "In one sentence: what is a LangGraph agent?",
    ]

    llm = get_llm()

    async def stream_one(i: int, prompt: str):
        result = ""
        async for chunk in llm.astream([HumanMessage(content=prompt)]):
            result += chunk.content
        return i, result

    start = time.time()
    results = await asyncio.gather(*[stream_one(i, p) for i, p in enumerate(prompts)])
    elapsed = time.time() - start

    for i, result in sorted(results):
        print(f"\nQ{i+1}: {prompts[i]}")
        print(f"A{i+1}: {result}")

    print(f"\n3 concurrent streams completed in {elapsed:.2f}s")


if __name__ == "__main__":
    demo_basic_streaming()
    demo_streaming_with_callback()
    asyncio.run(demo_async_streaming())
    asyncio.run(demo_concurrent_streaming())
