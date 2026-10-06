#!/usr/bin/env python3
"""
Interactive streaming chat CLI for KServe/vLLM deployments.

Usage:
    python3 scripts/chat.py [--url URL] [--model MODEL] [--system PROMPT]
"""

import argparse
import json
import sys
import time
import urllib.request
import urllib.error

RESET       = "\033[0m"
BOLD        = "\033[1m"
DIM         = "\033[2m"
BLUE_BOLD   = "\033[1;34m"
GREEN_BOLD  = "\033[1;32m"
CYAN_BOLD   = "\033[1;36m"
YELLOW_BOLD = "\033[1;33m"


def build_params(model_id: str) -> dict:
    if "minimax" in model_id.lower():
        return {"temperature": 1.0, "top_p": 0.95, "top_k": 40}
    return {"temperature": 0.7, "top_p": 1.0}


def detect_model(base_url: str) -> str:
    try:
        req = urllib.request.Request(
            f"{base_url}/v1/models",
            headers={"Accept": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        models = data.get("data", [])
        if models:
            return models[0]["id"]
    except Exception as exc:
        sys.stderr.write(f"[warn] Could not detect model: {exc}\n")
    return "default"


def stream_chat(url: str, payload: dict):
    """Yield (field, value) tuples.

    field is 'reasoning_content', 'content', or 'completion_tokens' (final chunk).
    """
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json", "Accept": "text/event-stream"},
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        for raw in resp:
            line = raw.decode("utf-8").rstrip("\r\n")
            if not line.startswith("data: "):
                continue
            s = line[6:]
            if s.strip() == "[DONE]":
                return
            try:
                chunk = json.loads(s)
            except json.JSONDecodeError:
                continue
            usage = chunk.get("usage")
            if usage and usage.get("completion_tokens"):
                yield "completion_tokens", usage["completion_tokens"]
            choices = chunk.get("choices", [])
            if not choices:
                continue
            choice = choices[0]
            delta = choice.get("delta", {})
            # reasoning_content may be on delta or on choice directly (vLLM version dependent)
            reasoning = delta.get("reasoning_content") or choice.get("reasoning_content")
            content = delta.get("content")
            if reasoning:
                yield "reasoning_content", reasoning
            if content:
                yield "content", content


def print_banner(model: str):
    lines = [
        "CMK KServe Chat",
        model,
        "",
        "/clear  reset history    /quit  exit",
    ]
    width = max(len(l) for l in lines) + 6
    bar = "═" * width
    sys.stdout.write(f"\n{CYAN_BOLD}╔{bar}╗\n")
    sys.stdout.write(f"║{'':^{width}}║\n")
    for line in lines:
        sys.stdout.write(f"║{line:^{width}}║\n")
    sys.stdout.write(f"║{'':^{width}}║\n")
    sys.stdout.write(f"╚{bar}╝{RESET}\n\n")
    sys.stdout.flush()


def chat_loop(base_url: str, model: str, display_name: str, system_prompt: str, max_tokens: int):
    messages = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})

    print_banner(display_name)

    while True:
        try:
            user_input = input(f"{BLUE_BOLD}You:{RESET} ").strip()
        except (EOFError, KeyboardInterrupt):
            sys.stdout.write(f"\n{DIM}Goodbye.{RESET}\n")
            return

        if not user_input:
            continue
        if user_input.lower() in ("/quit", "/exit", "quit", "exit"):
            sys.stdout.write(f"{DIM}Goodbye.{RESET}\n")
            return
        if user_input.lower() == "/clear":
            messages = []
            if system_prompt:
                messages.append({"role": "system", "content": system_prompt})
            sys.stdout.write(f"{DIM}  History cleared.{RESET}\n\n")
            continue
        if user_input.lower() == "/help":
            sys.stdout.write(
                f"{DIM}  /clear  — reset conversation history\n"
                f"  /quit   — exit\n"
                f"  /help   — show this message{RESET}\n\n"
            )
            continue

        messages.append({"role": "user", "content": user_input})
        sys.stdout.write(f"\n{GREEN_BOLD}Assistant:{RESET} ")
        sys.stdout.flush()

        payload = {
            "model": model,
            "messages": messages,
            "max_tokens": max_tokens,
            "stream": True,
            "stream_options": {"include_usage": True},
            **build_params(model),
        }

        start_time        = time.monotonic()
        first_tok         = None
        completion_tokens = None
        full_response     = ""
        interrupted       = False

        try:
            for field, value in stream_chat(f"{base_url}/v1/chat/completions", payload):
                now = time.monotonic()
                if field == "completion_tokens":
                    completion_tokens = value
                    continue
                if first_tok is None:
                    first_tok = now
                    ttft = (now - start_time) * 1000.0
                    sys.stdout.write(f"{YELLOW_BOLD}[⚡ {ttft:.0f}ms]{RESET} ")
                    sys.stdout.flush()
                sys.stdout.write(value)
                sys.stdout.flush()
                if field == "content":
                    full_response += value
        except KeyboardInterrupt:
            interrupted = True
            sys.stdout.write(f"\n{DIM}[interrupted]{RESET}\n\n")
        except urllib.error.URLError as exc:
            sys.stdout.write(f"\n{DIM}[connection error: {exc}]{RESET}\n\n")
            messages.pop()
            continue
        except Exception as exc:
            sys.stdout.write(f"\n{DIM}[error: {exc}]{RESET}\n\n")
            messages.pop()
            continue

        if not interrupted:
            elapsed = time.monotonic() - (first_tok or start_time)
            tps = completion_tokens / elapsed if completion_tokens and elapsed > 0.001 else 0.0
            tok_display = str(completion_tokens) if completion_tokens is not None else "?"
            sys.stdout.write(f"\n{DIM}  ✓ {tps:.1f} tok/s · {tok_display} tokens{RESET}\n\n")
            sys.stdout.flush()

        if full_response and not interrupted:
            messages.append({"role": "assistant", "content": full_response})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url",        default="http://localhost:8080")
    parser.add_argument("--model",      default=None)
    parser.add_argument("--system",     default="You are a helpful assistant.")
    parser.add_argument("--max-tokens", type=int, default=4096)
    args = parser.parse_args()

    base_url = args.url.rstrip("/")

    sys.stdout.write(f"{DIM}Detecting model...{RESET} ")
    sys.stdout.flush()
    model = args.model or detect_model(base_url)
    display_name = model
    sys.stdout.write(f"{GREEN_BOLD}{display_name}{RESET}\n")
    sys.stdout.flush()

    try:
        chat_loop(base_url, model, display_name, args.system, args.max_tokens)
    except KeyboardInterrupt:
        sys.stdout.write(f"\n{DIM}Goodbye.{RESET}\n")
        sys.exit(0)


if __name__ == "__main__":
    main()
