# MCP Code Review — Crusoe AI + MLflow

An AI-powered code review system built on the **Model Context Protocol (MCP)**. Static analysis tools run on your code, and **Kimi-K2-Thinking** (via Crusoe managed inference) synthesizes the findings into a prioritized, actionable review. Every run is tracked in **MLflow**.

## Architecture

```
Your Code
    │
    ▼
MCP Server (server.py)
    ├── analyze_code     — AST-based bug detection
    ├── check_security   — regex-based vulnerability scanning
    └── suggest_tests    — pytest stub generation
    │
    ▼
ChatCrusoe / Kimi-K2-Thinking
    │  synthesizes tool results into a human review
    ▼
MLflow (mlflow.db)
    └── logs code, tool results, reviews, latency metrics
```

## Files

| File | Description |
|---|---|
| `server.py` | MCP server — 3 tools, 2 resources, 1 prompt template |
| `client.py` | Demo client — calls tools directly, no LLM, prints raw JSON |
| `ai_client.py` | AI client — uses Crusoe LLM + MLflow tracking |
| `claude_desktop_config.json` | Register server with Claude Desktop |

## Prerequisites

- Python 3.12+
- [uv](https://docs.astral.sh/uv/) package manager
- A Crusoe API key from the [Crusoe console](https://console.crusoecloud.com)

## Setup

```bash
# Clone and install dependencies
git clone <repo-url>
cd mcp-example
uv sync

# Set your Crusoe API key (single quotes required — key contains $ characters)
export CRUSOE_API_KEY='<your-api-key>'

# Or persist it across sessions
echo "export CRUSOE_API_KEY='<your-api-key>'" >> ~/.zshrc
source ~/.zshrc
```

## Usage

### Run the AI code reviewer

```bash
uv run python ai_client.py
```

Paste your Python code when prompted, then press **Enter twice** to submit.

### Run the demo client (no API key needed)

```bash
uv run python client.py
```

Connects to the MCP server and calls all tools directly, printing raw JSON results.

### View MLflow experiment tracking

```bash
uv run mlflow ui --backend-store-uri sqlite:///mlflow.db
```

Open `http://localhost:5000` → select the **code-review-mcp** experiment.

Each run logs:

| Artifact | Contents |
|---|---|
| `input_code.py` | Code submitted for review |
| `tool_analyze_code.json` | Bugs and style issues |
| `tool_check_security.json` | Security vulnerabilities |
| `tool_suggest_tests.json` | Generated test stubs |
| `review_<model>.md` | Per-model review |
| `final_review.md` | Final output |

Metrics logged: `tool_analysis_seconds`, `review_seconds`.

## MCP Server — Tools

| Tool | How it works | Detects |
|---|---|---|
| `analyze_code` | Python `ast` module | Syntax errors, unused imports, bare `except`, TODO comments |
| `check_security` | `re` regex matching | `eval`/`exec`, SQL injection, hardcoded secrets |
| `suggest_tests` | AST function walker | Generates `pytest` stubs for every function |

## Adding More Models

Edit the `MODELS` list in `ai_client.py`:

```python
MODELS = [
    "moonshotai/Kimi-K2-Thinking",
    "meta-llama/Llama-3.3-70B-Instruct",
    "deepseek-ai/DeepSeek-R1-0528",
]
```

When multiple models are listed, all run in parallel and their reviews are synthesized into one optimal final output by `SYNTHESIS_MODEL`.

## Register with Claude Desktop

Copy `claude_desktop_config.json` to your Claude Desktop config directory:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

Update the path in the config to point to your `server.py`, then restart Claude Desktop. Claude will automatically discover and use the code review tools.

## Dependencies

| Package | Purpose |
|---|---|
| `mcp` | MCP server/client protocol |
| `langchain-crusoe` | `ChatCrusoe` streaming inference |
| `langchain` | MLflow LangChain autologging |
| `openai` | Underlying HTTP client for Crusoe API |
| `mlflow` | Experiment tracking, traces, metrics |
