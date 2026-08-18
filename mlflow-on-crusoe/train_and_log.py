"""
MLflow experiment tracking with Crusoe Managed Inference.
Logs model parameters, metrics, and LLM responses to MLflow.
Tested locally with Groq as a drop-in replacement for Crusoe.
"""
import os
import time
import mlflow
from dotenv import load_dotenv

load_dotenv()


def get_llm():
    if os.getenv("CRUSOE_API_KEY"):
        from langchain_crusoe import ChatCrusoe
        return ChatCrusoe(
            model="meta-llama/Llama-3.3-70B-Instruct",
            temperature=0.3,
            max_tokens=512,
        )
    else:
        from langchain_groq import ChatGroq
        return ChatGroq(
            model="llama-3.3-70b-versatile",
            temperature=0.3,
            max_tokens=512,
        )


def run_experiment(prompt: str, temperature: float, max_tokens: int, run_name: str):
    """Run a single LLM call and log everything to MLflow."""
    mlflow.set_experiment("crusoe-llm-experiments")

    with mlflow.start_run(run_name=run_name):
        # Log parameters
        mlflow.log_param("model", "Llama-3.3-70B-Instruct")
        mlflow.log_param("temperature", temperature)
        mlflow.log_param("max_tokens", max_tokens)
        mlflow.log_param("prompt", prompt)

        # Run inference
        llm = get_llm()
        start = time.time()
        from langchain_core.messages import HumanMessage
        response = llm.invoke([HumanMessage(content=prompt)])
        latency = time.time() - start

        output = response.content
        word_count = len(output.split())

        # Log metrics
        mlflow.log_metric("latency_seconds", round(latency, 3))
        mlflow.log_metric("output_word_count", word_count)
        mlflow.log_metric("words_per_second", round(word_count / latency, 2))

        # Log output as artifact
        with open("response.txt", "w") as f:
            f.write(f"PROMPT:\n{prompt}\n\nRESPONSE:\n{output}")
        mlflow.log_artifact("response.txt")
        os.remove("response.txt")

        print(f"\nRun: {run_name}")
        print(f"Latency: {latency:.2f}s | Words: {word_count} | WPS: {word_count/latency:.1f}")
        print(f"Response preview: {output[:200]}...")

        return {"latency": latency, "word_count": word_count, "output": output}


if __name__ == "__main__":
    prompts = [
        ("summarization", "Summarize the key advantages of GPU cluster computing for AI workloads in 3 bullet points."),
        ("reasoning",     "Explain the tradeoff between model quantization and inference accuracy."),
        ("generation",    "Write a Python function that retries an API call up to 3 times with exponential backoff."),
    ]

    print("Starting MLflow experiment tracking with Crusoe Managed Inference...")
    print("=" * 60)

    for run_name, prompt in prompts:
        run_experiment(prompt, temperature=0.3, max_tokens=512, run_name=run_name)

    print("\n" + "=" * 60)
    print("All runs logged. Launch the MLflow UI with:")
    print("    mlflow ui")
    print("Then open http://localhost:5000")
