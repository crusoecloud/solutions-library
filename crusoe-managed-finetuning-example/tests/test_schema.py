"""Fixture-driven smoke tests for src/schema.py.

Runnable with plain Python — no pytest dependency required:

    python3 tests/test_schema.py

The fixture below intentionally covers every `kind` that
`helper._prompt_for_hyperparam` understands, plus a couple of edge cases
(schema $refs, allOf composition, anyOf-with-null for nullability, and
const:"auto" for the "or auto" shapes).
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src.schema import _parse_params


FIXTURE = {
    "components": {
        "schemas": {
            "PositiveInteger": {
                "type": "integer",
                "minimum": 1,
                "maximum": 50,
            },
            "FineTuneSupervisedHyperparameters": {
                "type": "object",
                "properties": {
                    # int_or_auto via anyOf(int, const:"auto") + $ref
                    "n_epochs": {
                        "anyOf": [
                            {"$ref": "#/components/schemas/PositiveInteger"},
                            {"const": "auto"},
                        ],
                        "default": "auto",
                        "description": "Number of training epochs",
                    },
                    # enum containing "auto" and integer choices
                    "batch_size": {
                        "enum": ["auto", 16, 32, 64, 128],
                        "default": "auto",
                        "description": "Examples per batch",
                    },
                    # float_or_auto
                    "learning_rate": {
                        "anyOf": [
                            {"type": "number"},
                            {"const": "auto"},
                        ],
                        "default": "auto",
                        "description": "Absolute learning rate",
                    },
                    # pure enum, no null
                    "lr_scheduler": {
                        "enum": ["cosine", "constant", "linear"],
                        "default": "cosine",
                        "description": "LR scheduler",
                    },
                    # enum_or_null (enum + nullable via type array)
                    "lora_rank": {
                        "type": ["integer", "null"],
                        "enum": [2, 4, 8, 16, 32],
                        "default": None,
                        "description": "LoRA rank",
                    },
                    # float_or_null with min/max
                    "lora_dropout": {
                        "type": ["number", "null"],
                        "minimum": 0,
                        "maximum": 1,
                        "default": None,
                        "description": "LoRA dropout",
                    },
                    # int_or_null via anyOf-with-null
                    "early_stopping_patience": {
                        "anyOf": [
                            {"type": "integer", "minimum": 1},
                            {"type": "null"},
                        ],
                        "default": None,
                        "description": "Early stopping patience",
                    },
                    # unknown shape — should be skipped with a warning, not crash
                    "mystery_param": {
                        "type": "boolean",
                        "default": False,
                    },
                },
            },
        },
    },
}


def _by_name(specs, name):
    return next(s for s in specs if s["name"] == name)


def main() -> int:
    specs = _parse_params(FIXTURE, "FineTuneSupervisedHyperparameters")
    by_name = {s["name"]: s for s in specs}

    # Unknown shape was skipped.
    assert "mystery_param" not in by_name, "boolean param should have been skipped"

    # n_epochs — int_or_auto with min/max inherited from $ref
    s = by_name["n_epochs"]
    assert s["kind"] == "int_or_auto", s
    assert s["default"] == "auto", s
    assert s["min"] == 1 and s["max"] == 50, s

    # batch_size — enum with all choices preserved (auto is a valid choice)
    s = by_name["batch_size"]
    assert s["kind"] == "enum", s
    assert s["choices"] == ["auto", 16, 32, 64, 128], s
    assert s["default"] == "auto", s

    # learning_rate — float_or_auto
    s = by_name["learning_rate"]
    assert s["kind"] == "float_or_auto", s

    # lr_scheduler — plain enum
    s = by_name["lr_scheduler"]
    assert s["kind"] == "enum", s
    assert s["choices"] == ["cosine", "constant", "linear"], s

    # lora_rank — enum_or_null
    s = by_name["lora_rank"]
    assert s["kind"] == "enum_or_null", s
    assert s["choices"] == [2, 4, 8, 16, 32], s
    assert s["default"] is None, s

    # lora_dropout — float_or_null with min/max
    s = by_name["lora_dropout"]
    assert s["kind"] == "float_or_null", s
    assert s["min"] == 0 and s["max"] == 1, s
    assert s["default"] is None, s

    # early_stopping_patience — int_or_null with min from anyOf branch
    s = by_name["early_stopping_patience"]
    assert s["kind"] == "int_or_null", s
    assert s["min"] == 1, s
    assert s["default"] is None, s

    print(f"OK — parsed {len(specs)} hyperparameter specs from fixture")
    for s in specs:
        print(f"  {s['name']:32s} kind={s['kind']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
