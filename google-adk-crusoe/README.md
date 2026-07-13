# Google ADK × Crusoe AI

Use [Crusoe Managed Inference](https://www.crusoe.ai/cloud/managed-inference) models in agents built with [Google's Agent Development Kit (ADK)](https://google.github.io/adk-docs/).

Crusoe exposes an OpenAI-compatible API and is a first-class [LiteLLM](https://docs.litellm.ai/) provider, so ADK agents can use Crusoe models through ADK's built-in `LiteLlm` wrapper — no extra adapter code required.

## Setup

1. Create an account at [Crusoe Cloud](https://console.crusoecloud.com/) and generate an Inference API key in the **Security** tab.
2. Install the dependencies:

```bash
pip install google-adk litellm
```

3. Set your API key:

```bash
export CRUSOE_API_KEY="your-api-key"
```

> **Note:** If your installed LiteLLM version predates the endpoint update ([BerriAI/litellm#33121](https://github.com/BerriAI/litellm/pull/33121)), also set
> `export CRUSOE_API_BASE="https://api.inference.crusoecloud.com/v1"`.

## Quick start

Point ADK's `LiteLlm` model wrapper at a Crusoe model using the `crusoe/` prefix:

```python
from google.adk.agents import Agent
from google.adk.models.lite_llm import LiteLlm

root_agent = Agent(
    name="crusoe_agent",
    model=LiteLlm(model="crusoe/zai/GLM-5.2"),
    instruction="You are a helpful assistant.",
)
```

A complete tool-calling agent lives in [`agent.py`](agent.py). Run it from the parent directory with the ADK CLI:

```bash
adk run google-adk-crusoe   # interactive terminal session
adk web                     # browser-based dev UI
```

## Available models

| Model | Context window |
|---|---|
| `crusoe/zai/GLM-5.2` | 262,144 |
| `crusoe/zai/GLM-5.1` | 202,000 |
| `crusoe/nvidia/Nemotron-3-Nano-30B-A3B` | 262,144 |
| `crusoe/nvidia/Nemotron-3-Nano-Omni-Reasoning-30B-A3B` | 262,144 |
| `crusoe/nvidia/Nemotron-3-Super-120B-A12B` | 262,144 |
| `crusoe/nvidia/Nemotron-3-Ultra-550B` | 262,144 |
| `crusoe/google/gemma-4-31b-it` | 262,144 |
| `crusoe/meta-llama/Llama-3.3-70B-Instruct` | 131,072 |
| `crusoe/deepseek-ai/DeepSeek-V3-0324` | 163,840 |
| `crusoe/deepseek-ai/DeepSeek-V4-Flash` | 1,000,000 |
| `crusoe/deepseek-ai/DeepSeek-V4-Pro` | 1,000,000 |
| `crusoe/openai/gpt-oss-120b` | 131,072 |
| `crusoe/qwen/Qwen3-235B-A22B` | 131,072 |
| `crusoe/moonshotai/Kimi-K2.6` | 262,144 |

See the [Crusoe Managed Inference docs](https://docs.crusoecloud.com/managed-inference/overview) for the current catalog.

## Model parameters

`LiteLlm` forwards generation parameters to the Crusoe API:

```python
model = LiteLlm(
    model="crusoe/nvidia/Nemotron-3-Super-120B-A12B",
    temperature=0.2,
    max_tokens=1024,
    top_p=0.95,
)
```
