"""
MCP Server Example — Code Review Tools
=======================================
A simple MCP server that exposes tools for analyzing Python code.
This demonstrates: tool registration, resource exposure, and prompt templates.

Run with:  python server.py
"""

import json
import ast
import re
from mcp.server.fastmcp import FastMCP

# ─── Create the MCP Server ───────────────────────────────────────────────────
# FastMCP is the high-level Python SDK for building MCP servers.
# It handles the protocol, serialization, and transport automatically.

mcp = FastMCP(name="code-review-server")


# ─── TOOLS ────────────────────────────────────────────────────────────────────
# Tools are actions the AI can invoke. Each tool has:
#   - A name (derived from the function name)
#   - A description (from the docstring)
#   - Typed parameters (from the function signature + type hints)
#   - A return value


@mcp.tool()
def analyze_code(code: str) -> str:
    """Analyze Python code for common bugs and issues.

    Takes a string of Python source code and returns a JSON report
    of any issues found, including syntax errors, undefined variables,
    and unused imports.
    """
    issues = []

    # 1. Check for syntax errors
    try:
        tree = ast.parse(code)
    except SyntaxError as e:
        return json.dumps({
            "status": "error",
            "issues": [{"type": "syntax_error", "line": e.lineno, "message": str(e)}],
        }, indent=2)

    # 2. Find unused imports
    imports = set()
    used_names = set()

    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imports.add(alias.asname or alias.name)
        elif isinstance(node, ast.ImportFrom):
            for alias in node.names:
                imports.add(alias.asname or alias.name)
        elif isinstance(node, ast.Name):
            used_names.add(node.id)

    unused = imports - used_names
    for name in unused:
        issues.append({
            "type": "unused_import",
            "severity": "warning",
            "message": f"Import '{name}' is imported but never used",
        })

    # 3. Check for bare except clauses
    for node in ast.walk(tree):
        if isinstance(node, ast.ExceptHandler) and node.type is None:
            issues.append({
                "type": "bare_except",
                "severity": "warning",
                "line": node.lineno,
                "message": "Bare 'except:' clause — catches all exceptions including KeyboardInterrupt",
            })

    # 4. Check for TODO/FIXME comments
    for i, line in enumerate(code.splitlines(), 1):
        if re.search(r"#\s*(TODO|FIXME|HACK|XXX)", line, re.IGNORECASE):
            issues.append({
                "type": "todo_comment",
                "severity": "info",
                "line": i,
                "message": f"Found comment: {line.strip()}",
            })

    return json.dumps({
        "status": "ok",
        "total_issues": len(issues),
        "issues": issues,
    }, indent=2)


@mcp.tool()
def check_security(code: str) -> str:
    """Scan Python code for common security vulnerabilities.

    Checks for SQL injection patterns, use of eval/exec,
    hardcoded secrets, and other security anti-patterns.
    """
    vulnerabilities = []

    # 1. Check for eval/exec usage
    for i, line in enumerate(code.splitlines(), 1):
        if re.search(r"\beval\s*\(", line):
            vulnerabilities.append({
                "type": "dangerous_function",
                "severity": "critical",
                "line": i,
                "message": "Use of eval() — can execute arbitrary code",
            })
        if re.search(r"\bexec\s*\(", line):
            vulnerabilities.append({
                "type": "dangerous_function",
                "severity": "critical",
                "line": i,
                "message": "Use of exec() — can execute arbitrary code",
            })

    # 2. Check for SQL injection patterns
    for i, line in enumerate(code.splitlines(), 1):
        if re.search(r"(execute|cursor\.execute)\s*\(\s*f['\"]", line):
            vulnerabilities.append({
                "type": "sql_injection",
                "severity": "critical",
                "line": i,
                "message": "Possible SQL injection — use parameterized queries instead of f-strings",
            })
        if re.search(r"(execute|cursor\.execute)\s*\(.*%\s", line):
            vulnerabilities.append({
                "type": "sql_injection",
                "severity": "high",
                "line": i,
                "message": "Possible SQL injection — use parameterized queries instead of % formatting",
            })

    # 3. Check for hardcoded secrets
    for i, line in enumerate(code.splitlines(), 1):
        if re.search(r"(password|secret|api_key|token)\s*=\s*['\"][^'\"]+['\"]", line, re.IGNORECASE):
            vulnerabilities.append({
                "type": "hardcoded_secret",
                "severity": "high",
                "line": i,
                "message": "Possible hardcoded secret — use environment variables instead",
            })

    return json.dumps({
        "status": "ok",
        "total_vulnerabilities": len(vulnerabilities),
        "vulnerabilities": vulnerabilities,
    }, indent=2)


@mcp.tool()
def suggest_tests(code: str) -> str:
    """Suggest unit test cases for the given Python code.

    Analyzes function signatures and returns suggested pytest test stubs.
    """
    try:
        tree = ast.parse(code)
    except SyntaxError:
        return json.dumps({"error": "Cannot parse code — fix syntax errors first"})

    test_suggestions = []

    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            func_name = node.name
            args = [arg.arg for arg in node.args.args if arg.arg != "self"]

            test_code = f"""def test_{func_name}():
    # TODO: Add test values
    result = {func_name}({', '.join(f'{a}=...' for a in args)})
    assert result is not None  # Replace with actual assertion


def test_{func_name}_edge_case():
    # TODO: Test edge cases (empty input, None, boundary values)
    pass
"""
            test_suggestions.append({
                "function": func_name,
                "parameters": args,
                "suggested_test": test_code,
            })

    return json.dumps({
        "total_functions": len(test_suggestions),
        "test_suggestions": test_suggestions,
    }, indent=2)


# ─── RESOURCES ────────────────────────────────────────────────────────────────
# Resources are data the AI can read for context.
# They have a URI and return content.


@mcp.resource("config://review-rules")
def get_review_rules() -> str:
    """Returns the current code review rules and standards."""
    return json.dumps({
        "max_function_length": 50,
        "max_complexity": 10,
        "required_docstrings": True,
        "naming_convention": "snake_case",
        "forbidden_patterns": ["eval()", "exec()", "import *"],
    }, indent=2)


@mcp.resource("config://supported-languages")
def get_supported_languages() -> str:
    """Returns the list of supported programming languages."""
    return json.dumps(["python"], indent=2)


# ─── PROMPTS ──────────────────────────────────────────────────────────────────
# Prompts are reusable templates the AI can use.


@mcp.prompt()
def full_review(code: str) -> str:
    """Run a comprehensive code review combining all tools."""
    return f"""Please perform a full code review on the following code.

Use these tools in order:
1. analyze_code — find bugs and style issues
2. check_security — find security vulnerabilities
3. suggest_tests — generate test suggestions

Then synthesize all findings into a clear, prioritized report.

Code to review:
```python
{code}
```"""


# ─── Run the Server ──────────────────────────────────────────────────────────

if __name__ == "__main__":
    # This starts the MCP server using stdio transport.
    # The AI host (Claude, etc.) launches this as a subprocess
    # and communicates over stdin/stdout.
    print("Starting Code Review MCP Server...", flush=True)
    mcp.run(transport="stdio")
