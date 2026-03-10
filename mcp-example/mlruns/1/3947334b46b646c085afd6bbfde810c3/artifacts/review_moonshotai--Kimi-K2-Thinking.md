 # Code Review: Critical Security & Reliability Issues Found

**Overall Assessment**: This code contains multiple critical security vulnerabilities that must be fixed immediately before deployment. Several reliability bugs and code quality issues also need attention.

---

## 🔴 Priority 1: Critical Security Vulnerabilities (Fix Before Merge)

### 1. SQL Injection in `get_user()` and `create_user()`
**Lines 18 & 26** - Constructing SQL queries with f-strings allows attackers to manipulate database operations.

**Fix**: Use parameterized queries:
```python
# Line 18
cursor.execute("SELECT * FROM users WHERE username = ?", (username,))

# Line 26
cursor.execute(
    "INSERT INTO users (username, password) VALUES (?, ?)", 
    (username, hashed)
)
```

### 2. Arbitrary Code Execution via `eval()`
**Lines 38-39** - `eval()` executes unsanitized user input, allowing full system compromise.

**Fix**: Replace with safe alternatives. For expressions, use `ast.literal_eval()`:
```python
import ast

def run_query(self, query_string):
    try:
        return ast.literal_eval(query_string)
    except (ValueError, SyntaxError):
        return None  # Or raise ValueError("Invalid query format")
```

### 3. Hardcoded API Key
**Line 23** - Secret key is exposed in source code (security & secret management failure).

**Fix**: Use environment variables:
```python
import os

def create_user(self, username, password):
    api_key = os.getenv("API_SECRET_KEY")
    if not api_key:
        raise EnvironmentError("API_SECRET_KEY not configured")
    # ... rest of method
```

### 4. Weak Password Hashing (MD5)
**Line 24** - MD5 is cryptographically broken and unsuitable for passwords.

**Fix**: Use `bcrypt` (install via pip) or PBKDF2:
```python
import bcrypt

# Hashing
hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt())

# During verification, use:
# bcrypt.checkpw(password_input.encode(), stored_hash)
```

---

## 🟠 Priority 2: High-Risk Bugs & Reliability Issues

### 5. Missing Timeout in HTTP Request
**Function `fetch_external_data()`** - Can hang indefinitely, causing denial of service.

**Fix**: Add timeout with error handling:
```python
def fetch_external_data(url):
    try:
        response = requests.get(url, timeout=10)  # 10 second timeout
        response.raise_for_status()  # Check for HTTP errors
        return response.json()  # Use built-in JSON parser
    except requests.exceptions.Timeout:
        raise TimeoutError(f"Request to {url} timed out")
    except requests.exceptions.RequestException as e:
        raise ConnectionError(f"Request failed: {e}")
```

### 6. Bare Except Clause Swallows Critical Errors
**Line 34** - Catches `KeyboardInterrupt`, `SystemExit`, and masks real failures.

**Fix**: Catch specific exceptions only:
```python
def load_config(self, path):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, PermissionError) as e:
        # Log the error appropriately
        print(f"Config load failed: {e}")
        return {}
```

### 7. `process_users()` Crashes on None/Invalid Data
**Function `process_users()`** - No null checks; assumes `get_user()` always returns a dict with "email" key.

**Fix**: Add defensive programming:
```python
def process_users(db, user_list):
    results = []
    for user in user_list:
        if not user:
            continue  # Skip None/empty entries
        record = db.get_user(user.strip())
        if record and "email" in record:
            results.append(record["email"])
    return results
```

### 8. Missing Input Validation in `calculate_discount()`
**Function `calculate_discount()`** - No bounds checking allows negative prices or >100% discounts.

**Fix**: Add validation:
```python
def calculate_discount(price, discount_pct):
    if price < 0:
        raise ValueError("Price cannot be negative")
    if not (0 <= discount_pct <= 100):
        raise ValueError("Discount percentage must be between 0 and 100")
    discounted = price - (price * discount_pct / 100)
    return max(discounted, 0)  # Prevent negative results
```

---

## 🟡 Priority 3: Code Quality & Maintainability

### 9. Remove Unused Import & Fix Misleading Comment
**Line 1** - `os` is unused. The comment `# unused import` on line 4 incorrectly labels `requests` which *is* used.

**Fix**: Remove `os` import and correct the comment:
```python
import json
import hashlib
import requests  # Used in fetch_external_data
```

### 10. Poor Connection Management
**Class `UserDatabase`** - Connection never closed; `sqlite3` imported inside method.

**Fix**: Add context manager support and move import to top:
```python
import sqlite3  # At top of file

class UserDatabase:
    def __enter__(self):
        self.connect()
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        if self.connection:
            self.connection.close()
```

### 11. Inefficient Data Export Format
**Line 53** - Writing raw tuples is fragile and doesn't handle binary data.

**Fix**: Use proper CSV export:
```python
import csv

def export_users(self, output_path):
    # TODO: Implement pagination for large datasets
    cursor = self.connection.cursor()
    cursor.execute("SELECT * FROM users")
    
    with open(output_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([description[0] for description in cursor.description])  # Header
        writer.writerows(cursor)
```

---

## 🟢 Priority 4: Testing & Documentation

### 12. Implement Test Coverage
All 10 functions need tests. **Start with critical security functions**:

```python
# Example: Security-focused test for SQL injection
def test_sql_injection_protection():
    db = UserDatabase(":memory:")
    with db:
        db.connection.execute(
            "CREATE TABLE users (username TEXT, password TEXT)"
        )
        malicious_user = "'; DROP TABLE users; --"
        db.create_user(malicious_user, "password")
        # Should insert safely, not execute drop
        result = db.get_user(malicious_user)
        assert result[0] == malicious_user

# Example: Test for input validation
def test_calculate_discount_validation():
    with pytest.raises(ValueError):
        calculate_discount(-50, 10)
    with pytest.raises(ValueError):
        calculate_discount(100, 150)
```

### 13. Address TODO/FIXME Comments
- **Line 43**: Implement pagination for `export_users()` to prevent memory exhaustion on large tables
- **Line 52**: Add binary data detection/handling in export (e.g., base64 encode binary fields)

---

## Summary Action Items

1. **Immediate**: Fix all 4 critical security issues (SQL injection, eval, hardcoded secret, MD5)
2. **This Sprint**: Add timeout, implement proper exception handling, fix `process_users` crash
3. **Next Sprint**: Clean imports, add connection management, implement pagination
4. **Ongoing**: Write tests starting with security-critical functions; aim for >80% coverage

**Estimated Effort**: 2-3 days for critical fixes + security audit. Do not deploy to production until Priority 1 items are resolved.