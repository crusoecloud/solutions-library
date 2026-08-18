# Structured Output & Tool Calling × Crusoe AI

Pydantic-validated structured output and tool calling on [Crusoe Managed Inference](https://www.crusoe.ai/cloud/managed-inference) using `langchain-crusoe`.

## What this demonstrates

| Demo | What it shows |
|------|--------------|
| Structured summary | Extract typed fields from free-form LLM output |
| Code review | Validate verdict, score, and issue lists with Pydantic |
| Entity extraction | Pull companies, people, technologies, locations from text |
| Tool calling | Bind tools to the model and parse tool call arguments |

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
python structured_output.py
```

## Local testing (no Crusoe account needed)

```bash
pip install langchain-groq
export GROQ_API_KEY="your-groq-key"  # free at console.groq.com
python structured_output.py
```

## How structured output works

Define a Pydantic model and pass it to `with_structured_output`:

```python
from pydantic import BaseModel, Field
from langchain_crusoe import ChatCrusoe

class Summary(BaseModel):
    title: str
    key_points: list[str]
    sentiment: str = Field(description="positive, neutral, or negative")

llm = ChatCrusoe(model="meta-llama/Llama-3.3-70B-Instruct")
structured = llm.with_structured_output(Summary)
result = structured.invoke("Summarize the benefits of vector databases.")

print(result.title)       # typed str
print(result.key_points)  # typed list[str]
print(result.sentiment)   # typed str
```

## How tool calling works

```python
from pydantic import BaseModel, Field
from langchain_crusoe import ChatCrusoe

class SearchTool(BaseModel):
    """Search for information on a topic."""
    query: str = Field(description="Search query")
    max_results: int = Field(description="Number of results", default=5)

llm = ChatCrusoe(model="meta-llama/Llama-3.3-70B-Instruct")
llm_with_tools = llm.bind_tools([SearchTool])
response = llm_with_tools.invoke("Search for recent GPU benchmarks.")

for call in response.tool_calls:
    print(call["name"])   # SearchTool
    print(call["args"])   # {"query": "recent GPU benchmarks", "max_results": 5}
```

## Related

- [langchain-crusoe](../langchain-crusoe/) — LangChain integration for Crusoe Managed Inference
- [langgraph-crusoe](../langgraph-crusoe/) — Multi-node agentic pipelines on Crusoe
- [rag-crusoe](../rag-crusoe/) — RAG pipeline with Qdrant on Crusoe
- [Crusoe Managed Inference Docs](https://docs.crusoecloud.com/managed-inference/overview)
