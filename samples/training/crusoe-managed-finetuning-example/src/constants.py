"""Constants for the Crusoe managed fine-tuning example.

These values are not environment-configurable. Environment defaults and the
resumable state file are managed by `src/config.py`.
"""

BASE_URL = "https://api.intelligence.crusoecloud.com/v1"

# Console base URL for linking to job pages in the Crusoe Console.
CONSOLE_BASE_URL = "https://console.crusoecloud.com"

SWAGGER_URL = f"{BASE_URL}/swagger.json"
SWAGGER_CACHE_TTL_SECONDS = 24 * 60 * 60

TERMINAL_STATUSES = {"succeeded", "failed", "cancelled"}

# Polling / download tuning values.
ADAPTER_REGISTRATION_TIMEOUT_SECONDS = 120
ADAPTER_REGISTRATION_INTERVAL_SECONDS = 5
ADAPTER_DOWNLOAD_TIMEOUT_SECONDS = 120
DOWNLOAD_CHUNK_SIZE_BYTES = 8192
