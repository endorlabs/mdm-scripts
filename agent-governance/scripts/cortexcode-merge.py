"""Merge Endor's Cortex Code hooks into a user's hooks.json (Linux engine).

Usage: cortexcode-merge.py EXISTING RENDERED OUT

cortexcode-merge.js is the macOS (JXA) engine and must give the same result.
Run through cortexcode-merge.sh, which picks the engine.

A hook whose command matches "ai-audit cortexcode" is Endor's. Every other hook,
matcher group, event, and top-level key is the user's and is kept in place.
Endor's current groups go after the user's in each event. When nothing of the
user's is left, OUT is RENDERED byte for byte, so a file that holds only Endor's
hooks is written exactly as render.sh made it.

Exit 0 on success. Exit 2 when EXISTING cannot be parsed or has a shape this
merge does not know. Then OUT is not written, and the caller must leave the
user's file as it is.
"""
import json
import re
import sys

ENDOR = re.compile(r"ai-audit[ \t]+cortexcode(?![A-Za-z0-9_])")


class Refuse(Exception):
    pass


def reject_constant(name):
    raise ValueError("non-standard JSON constant " + name)


def parse(text, label):
    try:
        return json.loads(text, parse_constant=reject_constant)
    except ValueError as e:
        raise Refuse(label + " is not valid JSON: " + str(e))


def is_endor(hook):
    return (isinstance(hook, dict) and isinstance(hook.get("command"), str)
            and ENDOR.search(hook["command"]) is not None)


def strip_endor(groups):
    keep = []
    for g in groups:
        if isinstance(g, dict) and isinstance(g.get("hooks"), list):
            inner = [h for h in g["hooks"] if not is_endor(h)]
            if len(inner) == len(g["hooks"]):
                keep.append(g)
            elif inner:
                keep.append({k: (inner if k == "hooks" else v) for k, v in g.items()})
        else:
            keep.append(g)
    return keep


def merge(existing_text, rendered_text):
    existing = parse(existing_text, "the existing file")
    rendered = parse(rendered_text, "the rendered file")
    if not isinstance(existing, dict):
        raise Refuse("the existing file is not a JSON object")
    hooks = existing.get("hooks", {})
    if not isinstance(hooks, dict):
        raise Refuse('the existing "hooks" is not a JSON object')

    foreign = {}
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            raise Refuse('the existing "hooks.%s" is not a JSON array' % event)
        keep = strip_endor(groups)
        # An event left empty is not the user's when it is one of Endor's
        # events: either the strip emptied it, or Endor's groups go into it
        # anyway. Dropping it puts Endor's groups at the same place on every
        # run, so a second run gives the same bytes. Any other empty event
        # is the user's.
        if keep or (not groups and event not in rendered["hooks"]):
            foreign[event] = keep

    if not foreign and set(existing) <= {"hooks"}:
        return rendered_text

    for event, groups in rendered["hooks"].items():
        foreign[event] = foreign.get(event, []) + groups
    merged = dict(existing)
    merged["hooks"] = foreign
    return json.dumps(merged, indent=2, ensure_ascii=False) + "\n"


def main(argv):
    if len(argv) != 4:
        sys.stderr.write("usage: cortexcode-merge.py EXISTING RENDERED OUT\n")
        return 64
    try:
        with open(argv[1], encoding="utf-8") as f:
            existing_text = f.read()
    except ValueError as e:
        sys.stderr.write("the existing file is not UTF-8: %s\n" % e)
        return 2
    with open(argv[2], encoding="utf-8") as f:
        rendered_text = f.read()
    try:
        out = merge(existing_text, rendered_text)
    except Refuse as e:
        sys.stderr.write(str(e) + "\n")
        return 2
    with open(argv[3], "w", encoding="utf-8", newline="") as f:
        f.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
