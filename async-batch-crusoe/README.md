# Async Batch Inference × Crusoe AI

Run multiple prompts concurrently on [Crusoe Managed Inference](https://www.crusoe.ai/cloud/managed-inference) — 7x faster than sequential execution.

## What this demonstrates

| Mode | Description | Speed |
|------|-------------|-------|
| Sequential | One prompt at a time | baseline |
| Parallel | All prompts at once with `asyncio.gather` | 7x faster |
| Batched | Controlled batch size to balance speed and rate limits | 3x faster |

Benchmark: 8 prompts, `Llama-3.3-70B-Instruct`
- Sequential: 3.96s
- Parallel: 0.57s (7.0x faster)
- Batched (4 at a time): 1.29s (3.1x faster)

## Prerequisites

- Python 3.10+
- A Crusoe Cloud account → [console.crusoecloud.com](https://console.crusoecloud.com)
- Inference API key (Intelligence API Keys section under Security)

## Setup

```bash
pip install -r requirements.txt
export CRUSOE_API_KEY="your-api-key"
```

## Run the benchmark

```bash
python batch.py
```

## Local testing (no Crusoe account needed)

```bash
pip install langchain-groq
export GROQ_API_KEY="your-groq-key"  # free at console.groq.com
python batch.py
```

## How it works

### Sequential (baseline)

```python
for prompt in prompts:
    response = llm.invoke([HumanMessage(content=prompt)])
```

### Parallel (fastest)

```python
async def call_one(prompt: str) -> str:
    response = await llm.ainvoke([HumanMessage(content=prompt)])
    return response.content

results = await asyncio.gather(*[call_one(p) for p in prompts])
```

### Batched (rate-limit safe)

```python
for i in range(0, len(prompts), batch_size):
    batch = prompts[i:i + batch_size]
    results = await asyncio.gather(*[call_one(p) for p in batch])
```

## When to use each mode

- **Sequential** — debugging, single requests
- **Parallel** — maximum throughput, evaluation pipelines, batch scoring
- **Batched** — high volume with rate limit awareness

## Related

- [langchain-crusoe](../langchain-crusoe/) — LangChain integration for Crusoe Managed Inference
- [streaming-crusoe](../streaming-crusoe/) — Real-time token streaming on Crusoe
- [langgraph-crusoe](../langgraph-crusoe/) — Multi-node agentic pipelines on Crusoe
- [Crusoe Managed Inference Docs](https://docs.crusoecloud.com/managed-inference/overview)
