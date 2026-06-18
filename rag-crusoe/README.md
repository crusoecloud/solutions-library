# RAG × Crusoe AI

A Retrieval-Augmented Generation (RAG) pipeline on [Crusoe Managed Inference](https://www.crusoe.ai/cloud/managed-inference) — semantic search with sentence-transformers and Qdrant, generation with Crusoe's MemoryAlloy-powered models.

## What this does
Documents → Embeddings → Qdrant (in-memory) → Retrieve top-k → Generate answer

1. Embeds documents using `all-MiniLM-L6-v2` (sentence-transformers)
2. Stores vectors in Qdrant (in-memory, no setup required)
3. At query time, retrieves the top-3 most relevant chunks
4. Passes retrieved context to Crusoe Managed Inference to generate a grounded answer

## Prerequisites

- Python 3.10+
- A Crusoe Cloud account → [console.crusoecloud.com](https://console.crusoecloud.com)
- Inference API key (Intelligence API Keys section under Security)

## Setup

```bash
pip install -r requirements.txt
export CRUSOE_API_KEY="your-api-key"
```

## Run the example

```bash
python example.py
```

## Local testing (no Crusoe account needed)

The pipeline automatically falls back to Groq if `CRUSOE_API_KEY` is not set:

```bash
pip install langchain-groq
export GROQ_API_KEY="your-groq-key"  # free at console.groq.com
python example.py
```

## Use your own documents

Edit the `DOCUMENTS` and `QUERIES` lists in `example.py`:

```python
DOCUMENTS = [
    "Your first document here.",
    "Your second document here.",
]

QUERIES = [
    "Your question here?",
]
```

## Swap the vector store

The pipeline uses Qdrant in-memory mode for zero-setup. To persist data, swap the client in `rag.py`:

```python
# In-memory (default, no setup)
client = QdrantClient(":memory:")

# Persistent local storage
client = QdrantClient(path="./qdrant_data")

# Remote Qdrant Cloud
client = QdrantClient(url="https://your-cluster.qdrant.io", api_key="your-key")
```

## Related

- [langchain-crusoe](../langchain-crusoe/) — LangChain integration for Crusoe Managed Inference
- [langgraph-crusoe](../langgraph-crusoe/) — Multi-node agentic pipelines on Crusoe
- [mlflow-on-crusoe](../mlflow-on-crusoe/) — Experiment tracking for Crusoe Managed Inference
- [Crusoe Managed Inference Docs](https://docs.crusoecloud.com/managed-inference/overview)
