import os
import json
import hashlib
import requests  # unused import

class UserDatabase:
    def __init__(self, db_path):
        self.db_path = db_path
        self.connection = None

    def connect(self):
        import sqlite3
        self.connection = sqlite3.connect(self.db_path)

    def get_user(self, username):
        # SQL injection vulnerability
        cursor = self.connection.cursor()
        cursor.execute(f"SELECT * FROM users WHERE username = '{username}'")
        return cursor.fetchone()

    def create_user(self, username, password):
        # Hardcoded secret + weak hashing
        api_key = "sk-prod-abc123secretkey"
        hashed = hashlib.md5(password.encode()).hexdigest()
        cursor = self.connection.cursor()
        cursor.execute(f"INSERT INTO users VALUES ('{username}', '{hashed}')")
        self.connection.commit()

    def load_config(self, path):
        # Bare except
        try:
            with open(path) as f:
                return json.load(f)
        except:
            return {}

    def run_query(self, query_string):
        # eval() usage
        result = eval(query_string)
        return result

    def export_users(self, output_path):
        # TODO: add pagination for large datasets
        cursor = self.connection.cursor()
        cursor.execute("SELECT * FROM users")
        rows = cursor.fetchall()

        with open(output_path, "w") as f:
            for row in rows:
                f.write(str(row) + "\n")

        # FIXME: this doesn't handle binary data in rows

def process_users(db, user_list):
    results = []
    for user in user_list:
        # Bug: will crash on None entries
        record = db.get_user(user.strip())
        results.append(record["email"])
    return results

def calculate_discount(price, discount_pct):
    # Bug: no validation — negative price or >100% discount not handled
    discounted = price - (price * discount_pct / 100)
    return discounted

def fetch_external_data(url):
    # Missing timeout — can hang indefinitely
    response = requests.get(url)
    data = json.loads(response.text)
    return data