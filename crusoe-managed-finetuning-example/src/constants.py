"""Constants for the Crusoe managed fine-tuning example.

These values are not environment-configurable. Environment defaults and the
resumable state file are managed by `src/config.py`.
"""

BASE_URL = "https://api.intelligence.crusoecloud.com/v1"

# Console base URL for linking to job pages in the Crusoe Console.
CONSOLE_BASE_URL = "https://console.crusoecloud.com"

TERMINAL_STATUSES = {"succeeded", "failed", "cancelled"}

# Polling / download tuning values.
ADAPTER_REGISTRATION_TIMEOUT_SECONDS = 120
ADAPTER_REGISTRATION_INTERVAL_SECONDS = 5
ADAPTER_DOWNLOAD_TIMEOUT_SECONDS = 120
DOWNLOAD_CHUNK_SIZE_BYTES = 8192

# Hyperparameter metadata derived from the gateway schema
# (FineTuneSupervisedHyperparameters). Each entry records the default the
# server uses, the allowed type/choices, and a short description.
HYPERPARAMS = [
    {"name": "n_epochs", "default": "auto", "kind": "int_or_auto", "min": 1, "max": 50,
     "help": "Number of training epochs"},
    {"name": "batch_size", "default": "auto", "kind": "enum", "choices": ["auto", 16, 32, 64, 128, 256, 512, 1024],
     "help": "Examples per batch"},
    {"name": "learning_rate_multiplier", "default": "auto", "kind": "float_or_auto",
     "help": "Learning-rate scaling factor (must be > 0)"},
    {"name": "learning_rate", "default": "auto", "kind": "float_or_auto",
     "help": "Absolute learning rate"},
    {"name": "lr_scheduler", "default": "cosine", "kind": "enum", "choices": ["cosine", "constant", "constant_with_warmup", "linear"],
     "help": "Learning-rate scheduler"},
    {"name": "lora_variant", "default": "lora", "kind": "enum", "choices": ["lora", "rslora"],
     "help": "LoRA variant"},
    {"name": "lora_rank", "default": None, "kind": "enum_or_null", "choices": [2, 4, 8, 16, 32, 64, 128, 256],
     "help": "LoRA attention dimension"},
    {"name": "lora_alpha", "default": None, "kind": "enum_or_null", "choices": [1, 2, 4, 8, 16, 32, 64, 128, 256, 512],
     "help": "LoRA scaling parameter"},
    {"name": "lora_dropout", "default": None, "kind": "float_or_null", "min": 0, "max": 1,
     "help": "LoRA dropout probability"},
    {"name": "early_stopping_patience", "default": None, "kind": "int_or_null", "min": 1,
     "help": "Eval calls without improvement before early stopping"},
    {"name": "warmup_ratio", "default": None, "kind": "float_or_null", "min": 0, "max": 1,
     "help": "Fraction of steps used for linear warmup"},
    {"name": "weight_decay", "default": None, "kind": "float_or_null", "min": 0,
     "help": "Weight decay (L2 regularization) coefficient"},
    {"name": "top_k_gating", "default": None, "kind": "enum_or_null", "choices": [1, 2, 4, 8, 16],
     "help": "Number of experts activated per token"},
    {"name": "checkpoint_steps", "default": None, "kind": "float_or_null", "min": 20,
     "help": "Update steps between checkpoint saves"},
    {"name": "eval_steps_per_epoch", "default": None, "kind": "float_or_null", "min": 1,
     "help": "Evaluation steps per epoch"},
    {"name": "overlong_row_behavior", "default": "error", "kind": "enum", "choices": ["error", "drop"],
     "help": "How to handle rows exceeding max sequence length"},
]
