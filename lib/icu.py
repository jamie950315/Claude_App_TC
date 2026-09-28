"""Minimal ICU MessageFormat parser/expander used to turn translated messages
into DOM-matchable pieces (exact strings, regex templates, rich-text fragments).

A message is parsed into a list of nodes:
  ("text", str) | ("arg", name) | ("hash",) | ("tag_open", name) | ("tag_close", name)
  ("choice", name, kind, {key: [nodes]})
"""
import itertools
import re

MAX_VARIANTS = 32


class ParseError(Exception):
    pass


def parse(msg):
    nodes, pos = _parse(msg, 0, in_plural=False, depth=0)
    if pos != len(msg):
        raise ParseError(f"unexpected '}}' at {pos}")
    return nodes


def _parse(s, i, in_plural, depth):
    nodes = []
    buf = []

    def flush():
        if buf:
            nodes.append(("text", "".join(buf)))
            buf.clear()

    n = len(s)
    while i < n:
        c = s[i]
        if c == "'":
            # ICU quoting: '' is a literal quote; '{...' starts a quoted literal
            if i + 1 < n and s[i + 1] == "'":
                buf.append("'"); i += 2; continue
            if i + 1 < n and s[i + 1] in "{}#<|":
                j = s.find("'", i + 1)
                if j == -1:
                    buf.append(s[i + 1:]); i = n
                else:
                    buf.append(s[i + 1:j]); i = j + 1
                continue
            buf.append(c); i += 1; continue
        if c == "{":
            flush()
            node, i = _parse_arg(s, i + 1, depth)
            nodes.append(node)
            continue
        if c == "}":
            if depth == 0:
                raise ParseError(f"unbalanced '}}' at {i}")
            flush()
            return nodes, i
        if c == "#" and in_plural:
            flush(); nodes.append(("hash",)); i += 1; continue
        if c == "<":
            m = re.match(r"<(/?)([A-Za-z][\w-]*)\s*(/?)>", s[i:])
            if m:
                flush()
                name = m.group(2)
                if m.group(1):
                    nodes.append(("tag_close", name))
                elif m.group(3):
                    nodes.append(("tag_open", name)); nodes.append(("tag_close", name))
                else:
                    nodes.append(("tag_open", name))
                i += m.end()
                continue
        buf.append(c); i += 1
    flush()
    if depth:
        raise ParseError("unterminated '{'")
    return nodes, i


def _parse_arg(s, i, depth):
    m = re.match(r"\s*([^\s,{}]+)\s*(?:,\s*(\w+)\s*)?", s[i:])
    if not m:
        raise ParseError(f"bad argument at {i}")
    name, kind = m.group(1), m.group(2)
    i += m.end()
    if i >= len(s):
        raise ParseError("unterminated argument")
    if s[i] == "}":
        return ("arg", name), i + 1
    if s[i] != ",":
        raise ParseError(f"bad argument syntax at {i}")
    i += 1
    if kind in ("plural", "select", "selectordinal"):
        branches = {}
        while True:
            i += len(s[i:]) - len(re.sub(r"^\s*(offset:\s*\d+\s*)?", "", s[i:], count=1))
            if i < len(s) and s[i] == "}":
                return ("choice", name, kind, branches), i + 1
            m = re.match(r"\s*(=?[\w-]+)\s*\{", s[i:])
            if not m:
                raise ParseError(f"bad choice branch at {i}")
            key = m.group(1)
            sub, j = _parse(s, i + m.end(), kind != "select", depth + 1)
            branches[key] = sub
            i = j + 1
    # number/date/time with style: skip to matching brace
    lvl = 1
    while i < len(s) and lvl:
        if s[i] == "{":
            lvl += 1
        elif s[i] == "}":
            lvl -= 1
        i += 1
    if lvl:
        raise ParseError("unterminated formatted argument")
    return ("arg", name), i


def variants(nodes):
    """Yield (choice_path, flat_tokens) for every combination of branches.

    choice_path is a tuple of (arg_name, key) picked. flat tokens are
    ("text", s) | ("arg", name) | ("num", name) | ("tag_open"/"tag_close", name).
    """
    parts = []  # list of lists of alternatives: each alternative (path, tokens)
    for node in nodes:
        if node[0] == "choice":
            _, name, _kind, branches = node
            alts = []
            for key, sub in branches.items():
                for path, toks in variants(sub):
                    toks = [("num", name) if t[0] == "hash" else t for t in toks]
                    alts.append((((name, key),) + path, toks))
            parts.append(alts or [((), [])])
        else:
            parts.append([((), [node])])
    count = 0
    for combo in itertools.product(*parts):
        path = tuple(p for alt in combo for p in alt[0])
        toks = [t for alt in combo for t in alt[1]]
        yield path, toks
        count += 1
        if count >= MAX_VARIANTS:
            return


def pick_variant(zh_nodes, en_path):
    """Pick the Chinese variant matching an English choice path.

    Same key when the Chinese message has it, otherwise its `other` branch.
    """
    wanted = dict(en_path)

    def walk(nodes):
        out = []
        for node in nodes:
            if node[0] == "choice":
                _, name, _kind, branches = node
                key = wanted.get(name)
                sub = branches.get(key) if key in branches else branches.get("other")
                if sub is None:
                    sub = next(iter(branches.values()), [])
                for t in walk(sub):
                    out.append(("num", name) if t[0] == "hash" else t)
            else:
                out.append(node)
        return out

    return walk(zh_nodes)


def split_segments(tokens):
    """Split flat tokens at tag boundaries.

    Returns list of (tag_context, tokens) where tag_context is the innermost
    enclosing tag name or None for top level.
    """
    segs = []
    stack = []
    cur = []

    def flush():
        segs.append((stack[-1] if stack else None, cur[:]))
        cur.clear()

    for t in tokens:
        if t[0] == "tag_open":
            flush(); stack.append(t[1])
        elif t[0] == "tag_close":
            flush()
            if stack:
                stack.pop()
        else:
            cur.append(t)
    flush()
    return segs
