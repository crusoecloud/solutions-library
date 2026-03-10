# 🔍 Code Review: Security, Quality, and Maintainability

The provided code contains **critical security vulnerabilities**, **serious bugs**, and **code quality issues** that must be addressed before deployment. Below is a prioritized review with actionable fixes.

---

## 🚨 Critical Issues (Security)

### 1. **Use of `eval()` — Arbitrary Code Execution**
- **Location**: `run_query()` at lines 38–39
- **Risk**: `eval()` executes arbitrary Python code — an attacker could run system commands, exfiltrate data, or take full control.
- **Fix**: **Remove `eval()` entirely.** If dynamic queries are needed, use safe parsing (e.g., `ast.literal_eval()` for literals) or a domain-specific language.

```python
import ast

def run_query(self, query_string):
    # Only allow safe literals: dicts, lists, numbers, strings
    try:
        return ast.literal_eval(query_string)
    except (SyntaxError, ValueError):
        raise ValueError("Invalid query format")
```

> ✅ **Never use `eval()` on user input.**

---

### 2. **SQL Injection Vulnerabilities**
- **Locations**:
  - `get_user()` at line 18
  - `create_user()` at line 26
- **Risk**: Attackers can manipulate queries to dump, modify, or delete data.
- **Fix**: Use **parameterized queries** instead of f-strings.

**Before**:
```python
cursor.execute(f"SELECT * FROM users WHERE username = '{username}'")
```

**After**:
```python
cursor.execute("SELECT * FROM users WHERE username = ?", (username,))
```

Apply to both functions:
```python
def get_user(self, username):
    cursor = self.connection.cursor()
    cursor.execute("SELECT * FROM users WHERE username = ?", (username,))
    return cursor.fetchone()

def create_user(self, username, password):
    hashed = hashlib.md5(password.encode()).hexdigest()
    cursor = self.connection.cursor()
    cursor.execute("INSERT INTO users (username, password) VALUES (?, ?)", (username, hashed))
    self.connection.commit()
```

> ⚠️ Also ensure the table schema explicitly defines columns.

---

### 3. **Hardcoded Secret**
- **Location**: Line 23 — `api_key = "sk-prod-abc123secretkey"`
- **Risk**: Secrets in code can be exposed via version control, logs, or decompilation.
- **Fix**: Load from environment variables.

```python
import os
api_key = os.getenv("API_KEY")
if not api_key:
    raise RuntimeError("API_KEY environment variable not set")
```

> 🔐 Use tools like `python-decouple`, `python-dotenv`, or secret managers in production.

---

## ⚠️ High-Risk Issues

### 4. **Weak Password Hashing (MD5)**
- **Location**: `create_user()` — `hashlib.md5(...)`
- **Risk**: MD5 is cryptographically broken and fast — trivial to brute-force.
- **Fix**: Use `bcrypt`, `scrypt`, or `PBKDF2`.

```python
import bcrypt

def create_user(self, username, password):
    salt = bcrypt.gensalt()
    hashed = bcrypt.hashpw(password.encode(), salt)
    cursor = self.connection.cursor()
    cursor.execute("INSERT INTO users (username, password) VALUES (?, ?)", (username, hashed))
    self.connection.commit()
```

> 🔐 Never store passwords with MD5, SHA1, or plain text.

---

## ⚠️ Functional Bugs

### 5. **`process_users()` Crashes on `None` or Missing Keys**
- **Location**: `process_users()` at line 56–60
- **Bug**: Crashes if `user.strip()` fails (on `None`) or if record has no `"email"` key.
- **Fix**: Add input validation and handle missing keys.

```python
def process_users(db, user_list):
    results = []
    if not user_list:
        return results
    for user in user_list:
        if not user:
            continue
        try:
            username = user.strip()
            record = db.get_user(username)
            if record and "email" in record:
                results.append(record["email"])
            else:
                results.append(None)  # or log warning
        except Exception as e:
            print(f"Error processing user {user}: {e}")
            results.append(None)
    return results
```

---

### 6. **`calculate_discount()` Lacks Input Validation**
- **Bug**: Accepts negative prices or discounts >100%, possibly leading to invalid business logic.
- **Fix**: Add validation.

```python
def calculate_discount(price, discount_pct):
    if price < 0:
        raise ValueError("Price cannot be negative")
    if not 0 <= discount_pct <= 100:
        raise ValueError("Discount must be between 0 and 100")
    return price - (price * discount_pct / 100)
```

---

### 7. **`fetch_external_data()` Missing Timeout**
- **Risk**: Can hang indefinitely on slow/unresponsive servers.
- **Fix**: Add timeout and error handling.

```python
def fetch_external_data(url, timeout=10):
    try:
        response = requests.get(url, timeout=timeout)
        response.raise_for_status()  # Raise HTTP errors
        return response.json()  # Prefer .json() over json.loads(.text)
    except requests.exceptions.Timeout:
        raise TimeoutError(f"Request to {url} timed out after {timeout}s")
    except requests.exceptions.RequestException as e:
        raise ConnectionError(f"Request failed: {e}")
```

> ✅ Always use `timeout=` with `requests`.

---

## 🛠 Code Quality & Maintainability

### 8. **Bare `except:` Clause**
- **Location**: `load_config()` at line 34
- **Risk**: Catches `KeyboardInterrupt`, `SystemExit`, etc. — hard to debug.
- **Fix**: Catch specific exceptions.

```python
def load_config(self, path):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, PermissionError) as e:
        print(f"Config load failed: {e}")
        return {}
    except json.JSONDecodeError:
        print(f"Invalid JSON in config file: {path}")
        return {}
```

---

### 9. **Unused Imports**
- **Imports**: `os`, `requests` (imported but not used directly)
- **Fix**: Remove unused imports.

```python
# Remove: import os
# Remove: import requests  # unless used elsewhere
```

> ✅ `requests` is used in `fetch_external_data`, so keep it if that function is called.

---

### 10. **TODO/FIXME Comments**
- **Location**:
  - Line 43: `# TODO: add pagination for large datasets`
  - Line 52: `# FIXME: this doesn't handle binary data in rows`
- **Action**:
  - Add pagination using `LIMIT`/`OFFSET` or generator-based streaming.
  - Avoid `str(row)` for binary — use JSON or proper serialization.

**Improved `export_users()`**:
```python
def export_users(self, output_path):
    cursor = self.connection.cursor()
    cursor.execute("SELECT username, password FROM users")  # Explicit columns
    with open(output_path, "w") as f:
        for row in cursor:
            # Avoid binary issues — only export safe fields
            f.write(f"{row[0]},{row[1].hex()}\n")  # Example: hex-encode hash
```

---

## ✅ Testing Recommendations

All functions lack tests. Use the following patterns:

```python
def test_calculate_discount():
    assert calculate_discount(100, 10) == 90
    assert calculate_discount(50, 0) == 50
    assert calculate_discount(200, 100) == 0

def test_calculate_discount_edge_case():
    with pytest.raises(ValueError):
        calculate_discount(-10, 10)
    with pytest.raises(ValueError):
        calculate_discount(100, 150)

def test_fetch_external_data(monkeypatch):
    def mock_get(*args, **kwargs):
        class MockResponse:
            def __init__(self):
                self.status_code = 200
            def json(self): return {"data": "test"}
        return MockResponse()
    monkeypatch.setattr("requests.get", mock_get)
    result = fetch_external_data("http://example.com")
    assert result == {"data": "test"}
```

> 🧪 Use `pytest`, `unittest`, or `mock` for full coverage.

---

## ✅ Summary: Action Plan

| Priority | Fix | Action |
|--------|-----|--------|
| 🔴 Critical | Remove `eval()` | Replace with `ast.literal_eval()` or remove |
| 🔴 Critical | Fix SQL injection | Use parameterized queries (`?`) |
| 🔴 Critical | Remove hardcoded API key | Use `os.getenv("API_KEY")` |
| 🔴 Critical | Replace MD5 hashing | Use `bcrypt` or `PBKDF2` |
| 🟠 High | Add input validation | In `process_users`, `calculate_discount` |
| 🟠 High | Add timeout to `requests.get()` | Use `timeout=10` |
| 🟡 Medium | Fix bare `except` | Catch specific exceptions |
| 🟡 Medium | Handle TODO/FIXME | Add pagination, fix binary export |
| 🟡 Medium | Remove unused imports | `os`, if not used |
| 🟢 Low | Write tests | Use suggested patterns for all functions |

---

## Final Note

This code is **not production-safe** in its current state. The presence of `eval()` and SQL injection makes it **critically vulnerable**. Refactor immediately and add unit/integration tests before deployment.

🔐 **Security first. Always.**