"""
Example: Run the LangGraph research agent on Crusoe Managed Inference.

For production (Crusoe):
    export CRUSOE_API_KEY="your-api-key"

For local testing (Groq - free):
    export GROQ_API_KEY="your-groq-key"

Then run:
    python examples/research_agent.py
"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from dotenv import load_dotenv
load_dotenv()

from agent import run_research_agent

if __name__ == "__main__":
    topic = "GPU memory optimization techniques for large language model inference"

    print(f"\nTopic: {topic}")
    print("=" * 60)
    print("Running 3-node LangGraph pipeline: Research → Analysis → Summarize")
    print("=" * 60)

    result = run_research_agent(topic)

    print("\n📊 ANALYSIS:")
    print(result["analysis"])
    print("\n📝 SUMMARY:")
    print(result["summary"])
