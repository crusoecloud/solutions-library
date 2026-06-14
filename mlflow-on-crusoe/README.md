# MLflow × Crusoe AI

Track LLM experiments on [Crusoe Managed Inference](https://www.crusoe.ai/cloud/managed-inference) using MLflow — log parameters, latency metrics, and model outputs across runs.

## What this does

Runs 3 LLM inference experiments and logs everything to MLflow:

- **Parameters** — model name, temperature, max tokens, prompt
- **Metrics** — latency, output word count, words per second
- **Artifacts** — full model response saved per run

## Prerequisites

- Python 3.10+
- A Crusoe Cloud account → [console.crusoecloud.com](https://console.crusoecloud.com)
- Inference API key (Intelligence API Keys section under Security)

## Setup

```bash
pip install -r requirements.txt
export CRUSOE_API_KEY="your-api-key"
```

## Run the experiments

```bash
python train_and_log.py
```

## View results in MLflow UI

```bash
mlflow ui
```

Then open http://localhost:5000 — you'll see all runs under the `crusoe-llm-experiments` experiment with latency and throughput metrics side by side.

## Local testing (no Crusoe account needed)

The script automatically falls back to Groq if `CRUSOE_API_KEY` is not set:

```bash
pip install langchain-groq
export GROQ_API_KEY="your-groq-key"  # free at console.groq.com
python train_and_log.py
```

## What gets logged per run

| Type | Details |
|------|---------|
| Parameters | model, temperature, max_tokens, prompt |
| Metrics | latency_seconds, output_word_count, words_per_second |
| Artifacts | full response saved as response.txt |

## Extend it

Add your own prompts to the list in `train_and_log.py`:

```python
prompts = [
    ("my_task", "Your prompt here"),
]
```

Each entry becomes a named MLflow run, making it easy to compare outputs across models or temperatures.

## Related

- [langchain-crusoe](../langchain-crusoe/) — LangChain integration for Crusoe Managed Inference
- [langgraph-crusoe](../langgraph-crusoe/) — Multi-node agentic pipelines on Crusoe
- [Crusoe Managed Inference Docs](https://docs.crusoecloud.com/managed-inference/overview)
