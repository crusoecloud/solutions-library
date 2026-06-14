# Streaming Output × Crusoe AI

Real-time token streaming from [Crusoe Managed Inference](https://www.crusoe.ai/cloud/managed-inference) — sync streaming, async streaming, callback handlers, and concurrent multi-prompt streaming.

## What this demonstrates

| Demo | What it shows |
|------|--------------|
| Basic streaming | Stream tokens to stdout as they arrive |
| Callback handler | Stream via `StreamingStdOutCallbackHandler` |
| Async streaming | Non-blocking token generation with `astream` |
| Concurrent streaming | 3 prompts streamed simultaneously in 0.50s |

## Prerequisites

- Python 3.10+
- A Crusoe Cloud account → [console.crusoecloud.com](https://console.crusoecloud.com)
- Inference API key (Intelligence API Keys section under Security)

## Setup

```bash
pip install -r requirements.txt
export CRUSOE_API_KEY="your-api-key"
```

## Run all demos

```bash
python streaming.py
```

## Local testing (no Crusoe account needed)

```bash
pip install langchain-groq
export GROQ_API_KEY="your-groq-key"  # free at console.groq.com
python streaming.py
```

## How streaming works

### Sync streaming

```python
from langchain_crusoe import ChatCrusoe
from langchain_core.messages import HumanMessage

llm = ChatCrusoe(model="meta-llama/Llama-3.3-70B-Instruct")

for chunk in llm.stream([HumanMessage(content="Explain KV cache sharing.")]):
    print(chunk.content, end="", flush=True)
```

### Async streaming

```python
import asyncio
from langchain_crusoe import ChatCrusoe
from langchain_core.messages import HumanMessage

llm = ChatCrusoe(model="meta-llama/Llama-3.3-70B-Instruct")

async def main():
    async for chunk in llm.astream([HumanMessage(content="Explain KV cache sharing.")]):
        print(chunk.content, end="", flush=True)

asyncio.run(main())
```

### Concurrent streaming (multiple prompts at once)

```python
import asyncio
from langchain_crusoe import ChatCrusoe
from langchain_core.messages import HumanMessage

llm = ChatCrusoe(model="meta-llama/Llama-3.3-70B-Instruct")

async def stream_one(prompt: str):
    result = ""
    async for chunk in llm.astream([HumanMessage(content=prompt)]):
        result += chunk.content
    return result

async def main():
    results = await asyncio.gather(
        stream_one("What is a vector database?"),
        stream_one("What is RAG?"),
        stream_one("What is a LangGraph agent?"),
    )
    for r in results:
        print(r)

asyncio.run(main())
```

## Related

- [langchain-crusoe](../langchain-crusoe/) — LangChain integration for Crusoe Managed Inference
- [langgraph-crusoe](../langgraph-crusoe/) — Multi-node agentic pipelines on Crusoe
- [rag-crusoe](../rag-crusoe/) — RAG pipeline with Qdrant on Crusoe
- [structured-output-crusoe](../structured-output-crusoe/) — Structured output and tool calling on Crusoe
- [Crusoe Managed Inference Docs](https://docs.crusoecloud.com/managed-inference/overview)
