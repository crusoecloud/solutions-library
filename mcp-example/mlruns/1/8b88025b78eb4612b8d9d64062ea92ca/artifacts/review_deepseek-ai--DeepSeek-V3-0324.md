# Code Review: Critical Security Issues and Quality Improvements

## Critical Security Issues (Priority 1)

1. **SQL Injection Vulnerabilities** (Critical)
   - Lines 18 & 26: Using f-strings to build SQL queries
   - **Fix**: Use parameterized queries instead:
     ```python
     # In get_user()
     cursor.execute("SELECT * FROM users WHERE username = ?", (username,))
     
     # In create_user()
     cursor.execute("INSERT INTO users VALUES (?, ?, ?)", (username, hashed, api_key))
     ```

2. **Arbitrary Code Execution via eval()** (Critical)
   - Lines 38-39: `run_query()` uses unsafe eval()
   - **Fix**: Remove entirely or implement strict sanitization if absolutely needed
   - Better alternatives: Use AST parser or sqlite3's execute() for SQL queries

3. **Hardcoded Secret** (High)
   - Line 23: API key in source code
   - **Fix**: Store in environment variables or secret management service:
     ```python
     api_key = os.environ.get('API_SECRET_KEY')
     ```

4. **Weak Password Hashing** (High)
   - Line 24: Using MD5 for password hashing
   - **Fix**: Use bcrypt or Argon2:
     ```python
     import bcrypt
     hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt())
     ```

5. **Missing Request Timeout** (Medium)
   - `fetch_external_data()` can hang indefinitely
   - **Fix**: Add reasonable timeout:
     ```python
     response = requests.get(url, timeout=10.0)
     ```

## High Priority Functional Issues

1. **Bare except Clause** (Line 34)
   - Catches all exceptions including KeyboardInterrupt
   - **Fix**: Catch specific exceptions (JSONDecodeError, FileNotFoundError)
   ```python
   except (json.JSONDecodeError, FileNotFoundError) as e:
       logger.error(f"Config load failed: {e}")
       return {}
   ```

2. **Unhandled Edge Cases**
   - `process_users()` crashes on None entries
   - `calculate_discount()` allows invalid inputs
   - **Fixes**:
     ```python
     def process_users(db, user_list):
         results = []
         for user in user_list:
             if not user:  # Handle None/empty
                 continue
             record = db.get_user(user.strip())
             if record:  # Handle None from database
                 results.append(record["email"])
         return results

     def calculate_discount(price, discount_pct):
         if not all(isinstance(x, (int, float)) for x in (price, discount_pct)):
             raise ValueError("Numeric inputs required")
         if price < 0 or not (0 <= discount_pct <= 100):
             raise ValueError("Invalid price or discount percentage")
         return price - (price * discount_pct / 100)
     ```

## Code Quality Improvements (Priority 2)

1. **Remove Unused Imports**
   - `os` and `requests` are imported but unused

2. **Address TODOs/FIXMEs**
   - Line 43 (pagination): Implement with LIMIT/OFFSET in SQL
   - Line 52 (binary data): Handle properly or document limitation

3. **Testing Recommendations**
   - High priority test cases to add:
     - SQL injection attempts
     - Invalid inputs for all public methods
     - Authentication/secret key loading
     - Timeout behavior for external requests

## Implementation Order Recommendation:

1. Fix SQL injection vulnerabilities immediately
2. Remove eval() usage
3. Move secrets to environment variables
4. Improve password hashing
5. Add input validation
6. Address TODOs and testing
7. Clean up imports and comments

All security fixes should be treated as urgent due to potential exploit vectors. The SQL injection and eval() issues in particular could allow complete system compromise if exploited.