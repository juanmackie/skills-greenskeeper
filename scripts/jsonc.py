"""Skills Greenskeeper - JSONC helpers (shared by mcp.sh and swipe.sh).

OpenCode configs are often .jsonc (comments, trailing commas). These
string-aware helpers strip both without touching string contents, so
"https://..." URLs and "//" inside values survive — and remove one key by
byte span so surrounding comments and formatting stay untouched.

Byte-span removal (jsonc_remove_key) is what makes swipe deletions safe on
.jsonc files: only the target entry's characters are cut, everything else is
preserved verbatim. Callers must re-parse the result and confirm the key is
gone before writing.
"""

import json


def _scan_string(text, i):
    # i at opening quote; return index past closing quote.
    n = len(text)
    i += 1
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == '"':
            return i + 1
        i += 1
    raise ValueError("unterminated string")


def _skip_ws(text, i):
    # Skip whitespace AND comments; return first content index.
    n = len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n":
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        return i
    return i


def _skip_value(text, i):
    # i at value start; return index past value end.
    n = len(text)
    i = _skip_ws(text, i)
    if i >= n:
        raise ValueError("unexpected end of config")
    c = text[i]
    if c == '"':
        return _scan_string(text, i)
    if c in "{[":
        depth = 0
        while i < n:
            c = text[i]
            if c == '"':
                i = _scan_string(text, i)
                continue
            if c in "{[":
                depth += 1
            elif c in "}]":
                depth -= 1
                if depth == 0:
                    return i + 1
            i += 1
        raise ValueError("unterminated value")
    while i < n and text[i] not in ",}]":
        i += 1
    return i


def _peek_next(text, i):
    # Next content character at/after i, skipping ws AND comments.
    j = _skip_ws(text, i)
    return text[j] if j < len(text) else ""


def parse_jsonc(text):
    """Parse JSON with // and /* */ comments and trailing commas."""
    out = []
    i, n = 0, len(text)
    in_str = False
    esc = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        if c == ",":
            # A comma is trailing when the next content (past any comments)
            # closes the object or array.
            if _peek_next(text, i + 1) in "}]":
                i += 1
                continue
            out.append(c)
            i += 1
            continue
        out.append(c)
        i += 1
    return json.loads("".join(out))


def _object_entries(text, brace_i):
    # -> [(key, key_start, val_start, val_end)] for one object level.
    entries = []
    i = _skip_ws(text, brace_i + 1)
    n = len(text)
    if i < n and text[i] == "}":
        return entries
    while True:
        i = _skip_ws(text, i)
        if i >= n or text[i] != '"':
            raise ValueError("expected key string")
        ks = i
        i = _scan_string(text, i)
        key = json.loads(text[ks:i])
        i = _skip_ws(text, i)
        if i >= n or text[i] != ":":
            raise ValueError("expected colon")
        vs = _skip_ws(text, i + 1)
        ve = _skip_value(text, vs)
        entries.append((key, ks, vs, ve))
        i = _skip_ws(text, ve)
        if i < n and text[i] == ",":
            i = _skip_ws(text, i + 1)
            if i < n and text[i] == "}":
                return entries  # trailing comma before the close
            continue
        break
    return entries


def _remove_in_object(text, brace_i, keys):
    entries = _object_entries(text, brace_i)
    tgt = None
    for e in entries:
        if e[0] == keys[0]:
            tgt = e
            break
    if tgt is None:
        raise ValueError("key not found: " + keys[0])
    _, ks, vs, ve = tgt
    if len(keys) > 1:
        nv = _skip_ws(text, vs)
        if nv >= len(text) or text[nv] != "{":
            raise ValueError("not an object: " + keys[0])
        return _remove_in_object(text, nv, keys[1:])
    start, end = ks, ve
    j = ks - 1
    while j >= 0 and text[j] in " \t\r\n":
        j -= 1
    if j >= 0 and text[j] == ",":
        start = j  # swallow the preceding comma ...
    else:
        m = _skip_ws(text, ve)
        if m < len(text) and text[m] == ",":
            end = m + 1  # ... or the following one
    return text[:start] + text[end:]


def jsonc_remove_key(text, key_path):
    """Remove one key (list of nested keys) by byte span. Raises on any
    structural surprise — callers must treat that as 'do not write'."""
    i = _skip_ws(text, 0)
    if i >= len(text) or text[i] != "{":
        raise ValueError("config root is not an object")
    return _remove_in_object(text, i, list(key_path))
