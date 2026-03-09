 # Code Review: Critical Security & Quality Issues

## 🔴 Priority 1: Critical Security Vulnerabilities

### 1. **SQL Injection in `fetch_user()`**
- **Line**: `query = f"SELECT * FROM users WHERE id = {user_id}"`
- **Risk**: Attackers can inject malicious SQL. Example: `user_id = "1; DROP TABLE users--"`
- **Fix**: Use parameterized queries (assuming `cursor` is from a DB-API 2.0 library):
```python
def fetch_user(user_id):
    query = "SELECT * FROM users WHERE id = %s"  # or ? for sqlite3
    cursor.execute(query, (user_id,))
    return cursor.fetchone()
```
**If using psycopg2**: Use `%s` placeholder  
**If using sqlite3**: Use `?` placeholder

---

### 2. **Arbitrary Code Execution via `eval()`**
- **Line**: `result = eval(data)`
- **Risk**: `eval()` can execute *any* Python code. Never trust user input.
- **Fix**: Use `ast.literal_eval()` for safe evaluation of literals:
```python
import ast

def parse_input(data):
    try:
        return ast.literal_eval(data)  # Only evaluates strings, numbers, tuples, lists, dicts, booleans, None
    except (ValueError, SyntaxError):  # Catch specific exceptions
        return None
```
**Alternative**: If parsing JSON is the goal, use `json.loads()` (and remove the unused `json` import).

---

### 3. **Arbitrary Code Execution via `exec()`**
- **Line**: `exec(open(path).read())`
- **Risk**: Executes any Python code from a file. Complete system compromise if file is tampered.
- **Fix**: Use a safe configuration format:
```python
import json

def load_config(path):
    with open(path, 'r') as f:
        return json.load(f)  # or yaml.safe_load() for YAML
```
**Note**: This requires changing config file format from Python to JSON/YAML.

---

### 4. **Hardcoded Secret Key**
- **Line**: `DEBUG_KEY = "super_secret_123"`
- **Risk**: Secrets in source code are exposed in version control and deployments.
- **Fix**: Use environment variables:
```python
import os

DEBUG_KEY = os.getenv('DEBUG_KEY')
if not DEBUG_KEY:
    raise ValueError("DEBUG_KEY environment variable is required")
```

---

## 🟡 Priority 2: Code Quality & Reliability

### 5. **Bare Except Clause**
- **Line**: `except:`
- **Risk**: Catches `KeyboardInterrupt`, `SystemExit`, and masks all errors.
- **Fix**: Specify exceptions:
```python
except (ValueError, SyntaxError, TypeError):  # or whichever are expected
    return None
```

### 6. **Unused Imports**
- Remove `os`, `sys`, and `json` (unless needed for the JSON fix above).
```python
# Keep only what's used
# If using json for config: import json
# If using os for env vars: import os
```

---

## 🟢 Priority 3: Testing & Validation

### 7. **Missing Test Coverage**
All functions need tests focusing on:
- **`fetch_user`**: Test valid ID, non-existent ID, SQL injection attempts, None input
- **`parse_input`**: Test valid data structures, malformed input, empty string, None, code injection attempts
- **`calculate_discount`**: Test normal values, zero price, 100% discount, negative values, None input
- **`load_config`**: Test valid file, missing file, invalid JSON, symlink attack attempts

### 8. **Incomplete TODO**
- **Line**: `# TODO: validate input`
- **Action**: 
  - Add type checking: `if not isinstance(user_id, int) or user_id <= 0: raise ValueError(...)`
  - Add boundary validation

---

## Summary Action List

1. **Immediately** replace `eval()` and `exec()` with safe alternatives
2. **Immediately** fix SQL injection with parameterized queries
3. Move `DEBUG_KEY` to environment variables
4. Remove unused imports
5. Specify exception types in `except` clauses
6. Write comprehensive tests for all functions
7. Implement input validation for `user_id`

**Estimated effort**: 2-3 hours for security fixes, 1 hour for cleanup, 2-3 hours for tests.