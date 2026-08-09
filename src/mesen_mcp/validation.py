from __future__ import annotations

from dataclasses import dataclass
from difflib import get_close_matches
from typing import Any


class ValidationError(ValueError):
    pass


@dataclass(frozen=True)
class Field:
    type: type | tuple[type, ...]
    required: bool = False
    default: Any = None


Schema = dict[str, Field]


def validate_args(tool_name: str, schema: Schema, args: dict[str, Any] | None) -> dict[str, Any]:
    if args is None:
        args = {}
    if not isinstance(args, dict):
        raise ValidationError(f"{tool_name}: arguments must be an object")

    accepted = sorted(schema)
    for key in sorted(args):
        if key not in schema:
            suggestion = get_close_matches(key, accepted, n=1)
            hint = f"; did you mean '{suggestion[0]}'?" if suggestion else ""
            raise ValidationError(
                f"{tool_name}: unknown argument '{key}'{hint}; accepted arguments: {', '.join(accepted) or '(none)'}"
            )

    out: dict[str, Any] = {}
    for key, field in schema.items():
        if key not in args:
            if field.required:
                raise ValidationError(f"{tool_name}: missing required argument '{key}'")
            if field.default is not None:
                out[key] = field.default
            continue
        value = args[key]
        if not isinstance(value, field.type):
            expected = _type_name(field.type)
            raise ValidationError(f"{tool_name}: argument '{key}' must be {expected}")
        out[key] = value
    return out


def _type_name(t: type | tuple[type, ...]) -> str:
    if isinstance(t, tuple):
        return " or ".join(_type_name(item) for item in t)
    if t is str:
        return "string"
    if t is int:
        return "integer"
    if t is bool:
        return "boolean"
    if t is list:
        return "array"
    if t is dict:
        return "object"
    return t.__name__

