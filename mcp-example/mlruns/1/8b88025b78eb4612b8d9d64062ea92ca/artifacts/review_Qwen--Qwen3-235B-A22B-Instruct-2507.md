# 🔍 Code Review Summary

The provided code contains **multiple critical security vulnerabilities, bugs, and code quality issues** that must be addressed before deployment. Below is a prioritized review with actionable recommendations.

---

## 🚨 Critical Issues (Security)

### 1. **Use of `eval()` in `run_query()`**  
**Lines:** 38–39  
**Severity:** Critical  
**Risk:** Remote Code Execution (RCE) — `eval()` can execute arbitrary Python code from untrusted input.

> ❌ **Example exploit:**  
> `db.run_query("__import__('os').system('rm -rf /')")`

✅ **Fix:**
- **Remove `run_query()` entirely** unless absolutely necessary.
- If dynamic queries are needed, use a **safe expression parser** (e.g., `ast.literal_eval()` for literals only) or a domain-specific language (DSL).
- Never pass user input to `eval()`.

```python
import ast

def run_query(self, query_string):
    # Only allows safe literals: strings, numbers, tuples, lists, dicts, booleans, None
    return ast.literal_eval(query_string)
```

> ⚠️ Even better: **Delete this method** unless strictly required.

---

### 2. **SQL Injection in `get_user()` and `create_user()`**  
**Lines:** 18, 26  
**Severity:** Critical  
**Risk:** Attackers can manipulate queries to dump, modify, or delete data.

✅ **Fix: Use parameterized queries**

Replace:
```python
cursor.execute(f"SELECT * FROM users WHERE username = '{username}'")
```

With:
```python
cursor.execute("SELECT * FROM users WHERE username = ?", (username,))
```

And in `create_user`:
```python
cursor.execute("INSERT INTO users (username, password_hash) VALUES (?, ?)", (username, hashed))
```

> ✅ Also ensure the table schema explicitly defines columns.

---

### 3. **Hardcoded Secret in `create_user()`**  
**Line:** 23  
**Severity:** High  
**Risk:** API key exposed in source — can be leaked via version control, logs, etc.

✅ **Fix: Use environment variables**

```python
import os
api_key = os.getenv("API_KEY")
if not api_key:
    raise ValueError("API_KEY environment variable not set")
```

> 🔐 Never commit secrets to code. Use `.env` files (with `.gitignore`) or secret managers.

---

## ⚠️ High-Risk Bugs & Poor Practices

### 4. **Weak Password Hashing with MD5**  
**Line:** 25  
**Risk:** MD5 is cryptographically broken and unsuitable for passwords.

✅ **Fix: Use `bcrypt`, `scrypt`, or `PBKDF2`**

```python
import bcrypt

hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt())
# Store hashed.decode() in DB
```

Or using standard library:
```python
import hashlib
import os

def hash_password(password):
    salt = os.urandom(32)
    pwdhash = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 100000)
    return salt + pwdhash  # Store both
```

---

### 5. **Bare `except:` Clause in `load_config()`**  
**Line:** 34  
**Risk:** Catches all exceptions (including `KeyboardInterrupt`, `SystemExit`), masking real errors.

✅ **Fix: Catch specific exceptions**

```python
def load_config(self, path):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, PermissionError):
        return {}
    except json.JSONDecodeError:
        print(f"Warning: Invalid JSON in {path}")
        return {}
```

---

### 6. **Missing Timeout in `requests.get()`**  
**Line:** 58  
**Risk:** Request may hang indefinitely on unresponsive servers.

✅ **Fix: Add timeout**

```python
response = requests.get(url, timeout=10)  # seconds
```

Also add error handling:
```python
try:
    response = requests.get(url, timeout=10)
    response.raise_for_status()
    return response.json()  # preferred over json.loads(response.text)
except requests.RequestException as e:
    print(f"Request failed: {e}")
    return None
```

---

### 7. **Bug in `process_users()` — Crashes on `None` or missing keys**  
**Line:** 70  
- `user.strip()` → crashes if `user is None`
- `record["email"]` → crashes if no user found or missing `"email"`

✅ **Fix: Add input validation and safe access**

```python
def process_users(db, user_list):
    results = []
    if not user_list:
        return results
    for user in user_list:
        if not user:
            continue
        username = user.strip()
        if not username:
            continue
        record = db.get_user(username)
        if record and "email" in record:
            results.append(record["email"])
        else:
            results.append(None)  # or log missing user
    return results
```

---

### 8. **`calculate_discount()` — No Input Validation**  
**Line:** 75  
- Accepts negative prices or discounts >100% (e.g., free + extra cash?)

✅ **Fix: Validate inputs**

```python
def calculate_discount(price, discount_pct):
    if price < 0:
        raise ValueError("Price cannot be negative")
    if not 0 <= discount_pct <= 100:
        raise ValueError("Discount must be between 0 and 100")
    return price * (1 - discount_pct / 100)
```

---

## 🛠 Code Quality & Maintainability

### 9. **Unused Imports**  
- `os` and `requests` (imported but only used if called)
- `requests` is used in `fetch_external_data`, so keep it.
- `os` is not used → remove.

✅ **Fix:**
```python
# Remove this line:
import os
```

---

### 10. **TODO/FIXME Comments**  
- `# TODO: add pagination` → large exports may exhaust memory.
- `# FIXME: doesn't handle binary data` → potential data corruption.

✅ **Fix:**
- **Add pagination** in `export_users()` using LIMIT/OFFSET or generator.
- **Serialize safely** using `json` or `pickle` if needed.

```python
def export_users(self, output_path, batch_size=1000):
    offset = 0
    with open(output_path, "w") as f:
        while True:
            cursor = self.connection.cursor()
            cursor.execute("SELECT * FROM users LIMIT ? OFFSET ?", (batch_size, offset))
            rows = cursor.fetchall()
            if not rows:
                break
            for row in rows:
                f.write(json.dumps(row) + "\n")
            offset += batch_size
```

---

## ✅ Testing Recommendations

All functions lack tests. Use `pytest` or `unittest`.

### Generate Tests For:
- `process_users()` → test empty list, `None`, invalid users
- `calculate_discount()` → test edge cases: 0%, 100%, negative
- `fetch_external_data()` → mock responses with `requests-mock`
- `get_user()` / `create_user()` → use in-memory SQLite DB (`:memory:`)

> ✅ Example:
```python
def test_calculate_discount():
    assert calculate_discount(100, 10) == 90
    assert calculate_discount(50, 0) == 50
    assert calculate_discount(200, 100) == 0

def test_calculate_discount_invalid():
    with pytest.raises(ValueError):
        calculate_discount(-10, 10)
    with pytest.raises(ValueError):
        calculate_discount(100, 150)
```

---

## ✅ Final Recommendations

| Priority | Action |
|--------|--------|
| 🔴 **Critical** | Remove `eval()`, fix SQL injection, remove hardcoded secret |
| 🟠 **High** | Fix MD5 → use `bcrypt`, add `timeout=`, validate inputs |
| 🟡 **Medium** | Fix bare `except`, handle `None` safely, remove unused imports |
| 🟢 **Good Practice** | Add pagination, write unit tests, use environment variables |

---

## ✅ Summary: Immediate Actions

1. 🔒 **Remove `run_query()` or replace `eval()` with `ast.literal_eval()`**
2. 🛑 **Fix SQL injection** using parameterized queries (`?` placeholders)
3. 🔑 **Move `api_key` to environment variable**
4. 🔐 **Replace `hashlib.md5()` with `bcrypt` or `PBKDF2`**
5. ⏱ **Add `timeout=` to `requests.get()`**
6. 🧹 **Catch specific exceptions**, not bare `except:`
7. ✅ **Validate inputs** in `calculate_discount()` and `process_users()`
8. 📝 **Write unit tests** for all public functions
9. 🧩 **Add pagination** and safe serialization in `export_users()`

---

✅ **Once these fixes are applied, re-run security and code analysis tools to verify resolution.**