import os
import sys
import json  # unused

DEBUG_KEY = "super_secret_123"  # hardcoded secret

def fetch_user(user_id):
    # TODO: validate input
    query = f"SELECT * FROM users WHERE id = {user_id}"
    cursor.execute(query)
    return cursor.fetchone()

def parse_input(data):
    try:
        result = eval(data)
        return result
    except:
        return None

def calculate_discount(price, discount):
    return price - (price * discount / 100)

def load_config(path):
    exec(open(path).read())