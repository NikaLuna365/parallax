#!/usr/bin/env python3
"""Parallax provider-schema shim (v0.37.3 F6/P1) — OpenAI-compatible stripped schema copy.

OpenAI-family structured output (codex `--output-schema`, and API `response_format`)
rejects a JSON Schema whose TOP LEVEL carries `allOf` — which Parallax's
review-round.schema.json legitimately uses for its verdict↔findings consistency rule.
Live runs worked around this ad hoc, per call. This helper makes the workaround
deterministic and one-directional:

    strip-openai-schema.py FULL_SCHEMA.json STRIPPED_OUT.json

It writes a copy with the top-level `allOf` (and top-level `$schema`, which some
providers also reject) removed, changing NOTHING else. The stripped copy is for the
PROVIDER CALL ONLY — the judge must still validate the returned JSON against the FULL
schema locally (the stripped copy is strictly weaker; treating it as the acceptance
bar would let a verdict/findings-inconsistent round through). If the input has no
top-level `allOf`, the copy is byte-equivalent content-wise and `stripped` is false.

Exit: 0 ok; 3 unreadable/unwritable input (fail closed).
"""
import json
import sys


def main(argv):
    if len(argv) != 2:
        print(json.dumps({"error": "usage: strip-openai-schema.py FULL_SCHEMA.json STRIPPED_OUT.json"}))
        return 3
    src, dst = argv
    try:
        schema = json.load(open(src, encoding="utf-8"))
    except Exception as exc:
        print(json.dumps({"error": f"cannot read schema {src!r}: {exc}"}))
        return 3
    stripped = []
    for key in ("allOf", "$schema"):
        if key in schema:
            schema.pop(key)
            stripped.append(key)
    try:
        with open(dst, "w", encoding="utf-8") as handle:
            json.dump(schema, handle, ensure_ascii=True, indent=2)
            handle.write("\n")
    except Exception as exc:
        print(json.dumps({"error": f"cannot write stripped copy {dst!r}: {exc}"}))
        return 3
    print(json.dumps({"stripped": bool(stripped), "removed": stripped, "out": dst,
                      "note": "provider-call copy only; validate the RESPONSE against the FULL schema"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
