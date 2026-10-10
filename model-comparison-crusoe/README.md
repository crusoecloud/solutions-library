# Multi-Model Comparison × Crusoe AI

Benchmark multiple models on [Crusoe Managed Inference](https://www.crusoe.ai/cloud/managed-inference) across reasoning, code generation, and summarization — with latency, word count, and throughput metrics.

## What this does

Runs 3 models × 3 tasks concurrently and produces a leaderboard:
TASK: Reasoning

Llama-3.3-70B-Instruct    1.2s | 101 words | 84.2 wps

DeepSeek-V3-0324          0.9s | 118 words | 131.1 wps

Qwen3-235B-A22B           1.4s | 142 words | 101.4 wps
LEADERBOARD (average latency across all tasks)

1st  DeepSeek-V3-0324     avg 0.95s | 128.3 wps

2nd  Llama-3.3-70B        avg 1.18s | 97.2 wps

3rd  Qwen3-235B           avg 1.41s | 108.7 wps

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
python compare.py
```

## Local testing (no Crusoe account needed)

```bash
pip install langchain-groq
export GROQ_API_KEY="your-groq-key"  # free at console.groq.com
python compare.py
```

## Models compared on Crusoe

| Model | Provider | Context |
|-------|----------|---------|
| `meta-llama/Llama-3.3-70B-Instruct` | Meta | 128k |
| `deepseek-ai/DeepSeek-V3-0324` | DeepSeek | 160k |
| `Qwen/Qwen3-235B-A22B` | Qwen | 131k |

See the full model list at [Crusoe Intelligence Foundry](https://console.crusoecloud.com/foundry/models).

## Tasks

| Task | What it tests |
|------|--------------|
| Reasoning | Multi-step math problem |
| Code generation | Sieve of Eratosthenes with type hints |
| Summarization | SQL vs NoSQL tradeoffs in 3 bullets |

## Add your own tasks

```python
TASKS = [
    {
        "name": "My task",
        "prompt": "Your prompt here",
    },
]
```

Each task runs concurrently across all models — total time equals the slowest single call.

## Related

- [langchain-crusoe](../langchain-crusoe/) — LangChain integration for Crusoe Managed Inference
- [async-batch-crusoe](../async-batch-crusoe/) — Async batch inference benchmark
- [streaming-crusoe](../streaming-crusoe/) — Real-time token streaming on Crusoe
- [Crusoe Managed Inference Docs](https://docs.crusoecloud.com/managed-inference/overview)
