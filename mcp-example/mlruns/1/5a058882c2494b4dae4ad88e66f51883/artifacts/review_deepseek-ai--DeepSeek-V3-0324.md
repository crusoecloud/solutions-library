Here's a prioritized code review with actionable recommendations:

**Critical Security Issues (Must Fix Immediately):**

1. **SQL Injection Vulnerabilities**
   - Location: `get_user()` and `create_user()`
   - Fix: Use parameterized queries
   - Before:
   ```python
   cursor.execute(f"SELECT * FROM users WHERE username = '{username}'")
   ```
   - After:
   ```python
   cursor.execute("SELECT * FROM users WHERE username = ?", (username,))
   ```

2. **Arbitrary Code Execution (eval())**  
   - Location: `run_query()`
   - Fix: Remove eval() - use safer alternatives specific to your needs
   - If evaluating queries is truly needed, use `ast.literal_eval()` with strict input validation

3. **Hardcoded Secret**  
   - Location: `create_user()`
   - Fix: Move to environment variables or secret management system
   - Before:
   ```python
   api_key = "sk-prod-abc123secretkey"
   ```
   - After (in config/env):
   ```
   API_KEY=your-secret-key-from-env
   ```
   - Then in code:
   ```python
   api_key = os.getenv('API_KEY')
   ```

**High Priority Security/Quality Issues:**

4. **Weak Password Hashing**
   - Location: `create_user()`
   - Fix: Use proper password hashing (bcrypt, PBKDF2)
   - Before:
   ```python
   hashed = hashlib.md5(password.encode()).hexdigest()
   ```
   - After:
   ```python
   import bcrypt
   hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt())
   ```

5. **Bare Except Clause**  
   - Location: `load_config()`
   - Fix: Catch specific exceptions
   - After:
   ```python
   try:
       with open(path) as f:
           return json.load(f)
   except (FileNotFoundError, json.JSONDecodeError) as e:
       logger.error(f"Config load failed: {str(e)}")
       return {}
   ```

**Medium Priority Functional Issues:**

6. **Missing Request Timeout**
   - Location: `fetch_external_data()`
   - Fix: Add timeout
   - After:
   ```python
   response = requests.get(url, timeout=10.0)
   ```

7. **Unvalidated Input**
   - Location: `calculate_discount()`
   - Fix: Add validation
   - After:
   ```python
   if not (0 <= discount_pct <= 100):
       raise ValueError("Discount must be between 0-100%")
   if price < 0:
       raise ValueError("Price cannot be negative")
   ```

**Lower Priority Cleaning Items:**

8. **Unused Imports**  
   - Remove `os` and `requests` (if truly unused)
   - Run `pyflakes` or similar to verify

**Testing Recommendations:**

1. **Priority Test Cases**
   - SQL injection protection tests
   - Password hashing verification tests
   - Input validation for discount calculator
   - Error handling tests for config loading

2. **Security Smoke Tests**
   - Attempt SQL injection in database methods
   - Test for secret leakage
   - Verify eval() isn't reachable from user input

**Tracked Technical Debt:**

- Pagination TODO (line 43)
- Binary data FIXME (line 52)
- Both should be addressed in next sprint

**Overall Recommendations:**

1. Security audit for all database interactions
2. Secrets management implementation
3. Input validation layer for all public methods
4. Expand test coverage focusing on security scenarios
5. Consider using an ORM (SQLAlchemy) to prevent SQL issues

The changes can be made in this order:
1. Critical security fixes first (SQL injection, eval removal)
2. Security hardening (hashing, secrets)
3. Error handling improvements
4. Cleanup items

Would you like me to elaborate on any specific aspect of these recommendations?