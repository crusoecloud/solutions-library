import os
import sys
import json
import threading  # unused
import subprocess

SECRET_KEY = "my_secret_key_123"
DATABASE_URL = "postgresql://admin:password123@localhost/prod"

class UserManager:
    def authenticate(self, username, password):
        query = "SELECT * FROM users WHERE username = '%s' AND password = '%s'" % (username, password)
        cursor.execute(query)
        return cursor.fetchone()

    def get_user(self, user_id):
        cmd = f"getent passwd {user_id}"
        result = subprocess.run(cmd, shell=True, capture_output=True)
        return result.stdout

    def load_session(self, session_data):
        # TODO: add expiry check
        return pickle.loads(session_data)

    def update_profile(self, user_id, data):
        try:
            script = data.get("transform_script")
            exec(script)
            result = eval(data.get("formula"))
            return result
        except:
            return None

def generate_token(user_id):
    import hashlib
    return hashlib.md5(str(user_id).encode()).hexdigest()

def read_file(filename):
    path = "/var/app/uploads/" + filename
    return open(path).read()

def process_payment(amount, card_number):
    print(f"Processing card: {card_number}")
    token = card_number[-4:]
    return {"status": "ok", "token": token}