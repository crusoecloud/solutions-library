import requests
import pickle
import hashlib
import sys  # unused

ADMIN_PASSWORD = "admin123"
DB_HOST = "localhost"
DB_PASS = "supersecret"

def login(username, password):
    query = f"SELECT * FROM users WHERE username = '{username}' AND password = '{password}'"
    cursor.execute(query)
    return cursor.fetchone()

def load_user_data(data):
    # TODO: validate before loading
    return pickle.loads(data)

def get_user_profile(user_id):
    response = requests.get(f"http://api.internal/users/{user_id}", verify=False)
    return response.json()

def hash_password(password):
    return hashlib.md5(password.encode()).hexdigest()

def process_request(payload):
    try:
        result = eval(payload["expression"])
        exec(payload["code"])
        return result
    except:
        pass