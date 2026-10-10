"""
RAG (Retrieval-Augmented Generation) pipeline on Crusoe Managed Inference.
Uses sentence-transformers for embeddings and Qdrant (in-memory) for vector search.
Tested locally with Groq as a drop-in replacement for Crusoe.
"""
import os
from dotenv import load_dotenv
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams, PointStruct, QueryRequest

load_dotenv()

COLLECTION_NAME = "crusoe-rag"
EMBEDDING_MODEL = "all-MiniLM-L6-v2"
EMBEDDING_DIM = 384


def get_llm():
    if os.getenv("CRUSOE_API_KEY"):
        from langchain_crusoe import ChatCrusoe
        return ChatCrusoe(
            model="meta-llama/Llama-3.3-70B-Instruct",
            temperature=0.2,
            max_tokens=512,
        )
    else:
        from langchain_groq import ChatGroq
        return ChatGroq(
            model="llama-3.3-70b-versatile",
            temperature=0.2,
            max_tokens=512,
        )


def build_vectorstore(documents: list[str]):
    """Embed documents and store in an in-memory Qdrant collection."""
    from sentence_transformers import SentenceTransformer
    embedder = SentenceTransformer(EMBEDDING_MODEL)
    client = QdrantClient(":memory:")

    client.create_collection(
        collection_name=COLLECTION_NAME,
        vectors_config=VectorParams(size=EMBEDDING_DIM, distance=Distance.COSINE),
    )

    points = [
        PointStruct(
            id=i,
            vector=embedder.encode(doc).tolist(),
            payload={"text": doc},
        )
        for i, doc in enumerate(documents)
    ]
    client.upsert(collection_name=COLLECTION_NAME, points=points)
    print(f"Indexed {len(documents)} documents into Qdrant.")
    return client, embedder


def retrieve(query: str, client: QdrantClient, embedder, top_k: int = 3) -> list[str]:
    """Retrieve top-k most relevant document chunks for a query."""
    query_vector = embedder.encode(query).tolist()
    results = client.query_points(
        collection_name=COLLECTION_NAME,
        query=query_vector,
        limit=top_k,
    ).points
    return [hit.payload["text"] for hit in results]


def answer(query: str, client: QdrantClient, embedder) -> str:
    """Retrieve relevant context then generate an answer with Crusoe."""
    from langchain_core.messages import HumanMessage, SystemMessage

    chunks = retrieve(query, client, embedder)
    context = "\n\n".join(f"[{i+1}] {chunk}" for i, chunk in enumerate(chunks))

    llm = get_llm()
    response = llm.invoke([
        SystemMessage(content=(
            "You are a helpful assistant. Answer the question using only the provided context. "
            "If the context does not contain enough information, say so."
        )),
        HumanMessage(content=f"Context:\n{context}\n\nQuestion: {query}"),
    ])
    return response.content


def run_rag_pipeline(documents: list[str], queries: list[str]):
    """Full pipeline: index documents then answer each query."""
    print("Building vector store...")
    client, embedder = build_vectorstore(documents)
    print()

    for query in queries:
        print(f"Q: {query}")
        print(f"A: {answer(query, client, embedder)}")
        print("-" * 60)
