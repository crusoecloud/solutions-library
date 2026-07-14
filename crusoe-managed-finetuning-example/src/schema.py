"""Derive the supervised fine-tuning hyperparameter catalog from the live
gateway swagger, so schema changes are picked up without a code update."""

from __future__ import annotations

import logging
from typing import Any, TYPE_CHECKING

import httpx

from . import constants, path_cache, runtime

if TYPE_CHECKING:
    from .config import Config


log = logging.getLogger(__name__)

_MEMO: dict[str, list[dict]] = {}


def load_supervised_hyperparams(config: "Config") -> list[dict]:
    """Return specs: {"name", "default", "kind", "help", optional "choices"/"min"/"max"}."""
    key = config.swagger_cache_path
    if key not in _MEMO:
        swagger = _load_swagger(config)
        _MEMO[key] = _parse_params(swagger, "FineTuneSupervisedHyperparameters")
    return _MEMO[key]


def _load_swagger(config: "Config") -> dict:
    cache = path_cache.PathCache(
        path=config.swagger_cache_path,
        ttl_seconds=constants.SWAGGER_CACHE_TTL_SECONDS,
        fetch=lambda: _fetch_swagger(constants.SWAGGER_URL),
    )
    try:
        return cache.load()
    except path_cache.CacheMissError as e:
        runtime.abort(f"error: {e}")


def _fetch_swagger(url: str) -> dict:
    with httpx.Client(timeout=30) as client:
        resp = client.get(url)
        resp.raise_for_status()
        return resp.json()


def _get_schemas(swagger: dict) -> dict:
    # OpenAPI 3.x uses components.schemas; Swagger 2.x uses definitions.
    return swagger.get("components", {}).get("schemas") or swagger.get("definitions") or {}


def _resolve_ref(swagger: dict, ref: str) -> dict:
    node: Any = swagger
    for part in ref.lstrip("#/").split("/"):
        node = node[part]
    return node


def _parse_params(swagger: dict, schema_name: str) -> list[dict]:
    schemas = _get_schemas(swagger)
    if schema_name not in schemas:
        runtime.abort(
            f"error: could not find schema {schema_name!r} in swagger. "
            f"Available: {sorted(schemas.keys())[:10]}{'...' if len(schemas) > 10 else ''}"
        )
    schema = schemas[schema_name]

    specs = []
    for name, prop in schema.get("properties", {}).items():
        spec = _property_to_spec(name, prop, swagger)
        if spec is not None:
            specs.append(spec)
    return specs


def _property_to_spec(name: str, prop: dict, swagger: dict) -> dict | None:
    if "$ref" in prop:
        prop = _resolve_ref(swagger, prop["$ref"])

    types: set[str] = set()
    enum = None
    minimum = prop.get("minimum")
    maximum = prop.get("maximum")
    has_auto = False
    nullable = bool(prop.get("nullable", False))

    for branch in [prop] + prop.get("anyOf", []) + prop.get("oneOf", []):
        if "$ref" in branch:
            branch = _resolve_ref(swagger, branch["$ref"])
        for t in (branch.get("type") if isinstance(branch.get("type"), list) else [branch.get("type")]):
            if t == "null":
                nullable = True
            elif t is not None:
                types.add(t)
        if "enum" in branch:
            enum = list(branch["enum"])
            if "auto" in enum:
                has_auto = True
        if branch.get("const") == "auto":
            has_auto = True
        if minimum is None:
            minimum = branch.get("minimum")
        if maximum is None:
            maximum = branch.get("maximum")

    kind = _kind_for(types, enum, has_auto, nullable)
    if kind is None:
        log.warning("skipping %r: types=%s enum=%s auto=%s null=%s",
                    name, sorted(types), enum, has_auto, nullable)
        return None

    spec: dict = {
        "name": name,
        "default": prop.get("default"),
        "kind": kind,
        "help": (prop.get("description") or "").strip() or name,
    }
    if enum is not None and kind in ("enum", "enum_or_null"):
        spec["choices"] = enum
    if minimum is not None:
        spec["min"] = minimum
    if maximum is not None:
        spec["max"] = maximum
    return spec


def _kind_for(types: set[str], enum: list | None, has_auto: bool, nullable: bool) -> str | None:
    is_num = "integer" in types or "number" in types
    if enum:
        return "enum_or_null" if nullable else "enum"
    if "integer" in types and has_auto:
        return "int_or_auto"
    if is_num and has_auto:
        return "float_or_auto"
    if "integer" in types and nullable:
        return "int_or_null"
    if is_num and nullable:
        return "float_or_null"
    return None
