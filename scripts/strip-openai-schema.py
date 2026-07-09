#!/usr/bin/env python3
"""Parallax provider-schema shim (v0.37.3 F6; extended v0.37.5 E1) — OpenAI-strict schema copy.

OpenAI-family structured output rejects more than the top-level `allOf` the v0.37.3 shim
stripped: RUN2 hit "invalid_json_schema: `required` is required to be supplied" and the
judge burned 3-4 model calls hand-tuning schema variants per slice. From v0.37.5 the shim
produces a FULLY OpenAI-strict copy in one deterministic pass — zero hand-tuning:

  strict transform (recursive, whole tree):
    * drop `allOf` / `$schema` at EVERY level (not only the top);
    * every object node gets `additionalProperties: false` (when absent) and `required`
      enumerating EVERY property (OpenAI strict demands all properties required);
    * a property that was OPTIONAL in the full schema gets `null` added to its type (the
      strict-mode idiom for optionality), so the provider can always satisfy `required`.

  The strict copy is STRICTLY WEAKER on the rules that matter (the dropped allOf
  consistency checks) and shape-shifted on optionality — so it is for the PROVIDER CALL
  ONLY. The acceptance bar stays the FULL schema. Because the strict copy lets a provider
  emit `"id": null` where the full schema says optional-string, `normalize` bridges the
  two: it drops null-valued keys that the full schema does not require, then validates the
  result against the FULL schema. A verdict/findings-inconsistent response still fails the
  full schema; nothing hand-tuned, nothing silently weakened.

Usage:
  strip-openai-schema.py FULL_SCHEMA.json STRICT_OUT.json          # produce the call copy
  strip-openai-schema.py normalize RESPONSE.json FULL_SCHEMA.json  # strip inert nulls; print
                                                                   # the normalized JSON; exit
                                                                   # 0 only if it validates
                                                                   # against the FULL schema

Exit: 0 ok; 2 normalize: response fails the FULL schema (provider error — retry/fallback,
never hand-author); 3 unreadable input (fail closed).
"""
import copy
import json
import sys


def _strict(node):
    """Recursive OpenAI-strict transform."""
    if isinstance(node, list):
        return [_strict(x) for x in node]
    if not isinstance(node, dict):
        return node
    node = {k: v for k, v in node.items() if k not in ("allOf", "$schema")}
    out = {}
    for key, val in node.items():
        if key == "properties" and isinstance(val, dict):
            req = set(node.get("required", []))
            props = {}
            for name, sub in val.items():
                sub = _strict(sub)
                if name not in req and isinstance(sub, dict):
                    t = sub.get("type")
                    if isinstance(t, str) and t != "null":
                        sub["type"] = [t, "null"]
                    elif isinstance(t, list) and "null" not in t:
                        sub["type"] = t + ["null"]
                    elif t is None and "enum" in sub and None not in sub["enum"]:
                        sub = {"anyOf": [sub, {"type": "null"}]}
                props[name] = sub
            out["properties"] = props
        else:
            out[key] = _strict(val)
    if out.get("type") == "object" or "properties" in out:
        if isinstance(out.get("properties"), dict):
            out["required"] = sorted(out["properties"].keys())   # strict: EVERY property required
        out.setdefault("additionalProperties", False)
    return out


def _normalize(doc, schema):
    """Drop null-valued keys the FULL schema does not require (the strict copy's optionality
    idiom), recursively, guided by the full schema's object shapes."""
    if isinstance(doc, list):
        items = schema.get("items", {}) if isinstance(schema, dict) else {}
        return [_normalize(x, items) for x in doc]
    if not isinstance(doc, dict) or not isinstance(schema, dict):
        return doc
    props = schema.get("properties", {})
    req = set(schema.get("required", []))
    out = {}
    for k, v in doc.items():
        if v is None and k not in req:
            continue
        out[k] = _normalize(v, props.get(k, {}))
    return out


def main(argv):
    if argv and argv[0] == "normalize":
        if len(argv) != 3:
            print(json.dumps({"error": "usage: strip-openai-schema.py normalize RESPONSE.json FULL_SCHEMA.json"}))
            return 3
        try:
            doc = json.load(open(argv[1], encoding="utf-8"))
            schema = json.load(open(argv[2], encoding="utf-8"))
        except Exception as exc:
            print(json.dumps({"error": f"cannot read input: {exc}"}))
            return 3
        norm = _normalize(doc, schema)
        try:
            import jsonschema
            jsonschema.validate(norm, schema)
        except ImportError as exc:
            print(json.dumps({"error": f"jsonschema required for normalize validation: {exc}"}))
            return 3
        except Exception as exc:
            print(json.dumps({"error": "provider-error: normalized response fails the FULL schema "
                                       f"({getattr(exc, 'message', exc)}) — retry/fallback, never "
                                       "hand-author (v0.37.5 E1)"}))
            return 2
        print(json.dumps(norm, ensure_ascii=True))
        return 0

    if len(argv) != 2:
        print(json.dumps({"error": "usage: strip-openai-schema.py FULL_SCHEMA.json STRICT_OUT.json"}))
        return 3
    src, dst = argv
    try:
        schema = json.load(open(src, encoding="utf-8"))
    except Exception as exc:
        print(json.dumps({"error": f"cannot read schema {src!r}: {exc}"}))
        return 3
    strict = _strict(copy.deepcopy(schema))
    try:
        with open(dst, "w", encoding="utf-8") as handle:
            json.dump(strict, handle, ensure_ascii=True, indent=2)
            handle.write("\n")
    except Exception as exc:
        print(json.dumps({"error": f"cannot write strict copy {dst!r}: {exc}"}))
        return 3
    print(json.dumps({"strict": True, "out": dst,
                      "note": "provider-call copy only (all-required, additionalProperties:false, "
                              "nullable optionals, no allOf anywhere); validate the RESPONSE against "
                              "the FULL schema after `normalize`"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
