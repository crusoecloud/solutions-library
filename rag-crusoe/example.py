"""
Example: RAG pipeline on Crusoe Managed Inference.

For production (Crusoe):
    export CRUSOE_API_KEY="your-api-key"

For local testing (Groq - free):
    export GROQ_API_KEY="your-groq-key"

Then run:
    python example.py
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from rag import run_rag_pipeline

DOCUMENTS = [
    "Crusoe Cloud is an AI-focused cloud provider that builds and operates GPU clusters powered by clean energy.",
    "Crusoe's MemoryAlloy technology enables cluster-wide KV cache sharing, dramatically reducing inference latency for large language models.",
    "Crusoe Managed Inference supports leading open-source models including Llama 3.3, DeepSeek V3, Qwen3, and Gemma 3.",
    "GPU clusters are well-suited for AI workloads because they can perform thousands of parallel floating-point operations simultaneously.",
    "Retrieval-Augmented Generation (RAG) combines a retrieval step over a vector database with a generative language model to produce grounded answers.",
    "Qdrant is an open-source vector database optimized for high-dimensional similarity search, commonly used in RAG pipelines.",
    "Sentence transformers produce dense vector embeddings that capture semantic meaning, enabling similarity search across documents.",
    "LangChain is a framework for building LLM-powered applications including chains, agents, and RAG pipelines.",
]

QUERIES = [
    "What makes Crusoe different from other cloud providers?",
    "How does MemoryAlloy technology improve inference?",
    "What is RAG and why is it useful?",
]

if __name__ == "__main__":
    run_rag_pipeline(DOCUMENTS, QUERIES)
