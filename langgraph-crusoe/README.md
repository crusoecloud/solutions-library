# LangGraph × Crusoe AI

Run multi-step agentic pipelines on [Crusoe Managed Inference](https://www.crusoe.ai/cloud/managed-inference) using LangGraph — ultra-low latency, powered by MemoryAlloy™.

## What this does

A 3-node research pipeline built with LangGraph:
Research → Analysis → Summarize

Each node calls Crusoe Managed Inference independently. LangGraph manages state between nodes — no manual plumbing required.

## Prerequisites

- Python 3.10+
- A Crusoe Cloud account → [console.crusoecloud.com](https://console.crusoecloud.com)
- Inference API key (Intelligence API Keys section under Security in the console)

## Setup

```bash
pip install -r requirements.txt
export CRUSOE_API_KEY="your-api-key"
```

## Run the example

```bash
python examples/research_agent.py
```

## Local testing (no Crusoe account needed)

The agent automatically falls back to Groq if `CRUSOE_API_KEY` is not set. Groq is free and OpenAI-compatible — identical behavior.

```bash
pip install langchain-groq
export GROQ_API_KEY="your-groq-key"  # free at console.groq.com
python examples/research_agent.py
```

## How it works

```python
from agent import run_research_agent

result = run_research_agent("GPU memory optimization for LLM inference")
print(result["summary"])
```

The graph wires three nodes together:

| Node | Role |
|------|------|
| `research` | Gathers key facts about the topic |
| `analysis` | Extracts 3 insights and open questions |
| `summarize` | Produces a clean 3-paragraph summary |

## Swap the model

Change the model string in `agent.py` to any model available on [Crusoe Intelligence Foundry](https://console.crusoecloud.com/foundry/models):

```python
return ChatCrusoe(
    model="deepseek-ai/DeepSeek-R1-0528",
    temperature=0.3,
    max_tokens=1024,
)
```

## Extend the pipeline

Add nodes to the graph in `agent.py`:

```python
graph.add_node("fact_check", fact_check_node)
graph.add_edge("analysis", "fact_check")
graph.add_edge("fact_check", "summarize")
```

LangGraph handles state passing. You just write the node logic.

## Related

- [langchain-crusoe](../langchain-crusoe/) — LangChain integration for Crusoe Managed Inference
- [Crusoe Managed Inference Docs](https://docs.crusoecloud.com/managed-inference/overview)
