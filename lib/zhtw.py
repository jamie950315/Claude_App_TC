#!/usr/bin/env python3
"""Build and apply the zh-TW translation for Claude Desktop.

Subcommands:
  inject <translations.json> <mainView.js>      Inject the Web UI DOM translator
  strip <mainView.js>                           Remove a previous injection
  patch-defaults <translations.json> <build_dir> Replace defaultMessage strings in main-process bundles
  catalog <translations.json> <en-US.json> <out.json>  Translate the desktop message catalog by ID
  stats <translations.json>                     Print what the injection would contain
  missing <translations.json> <Claude.app> <dir>  Write untranslated strings as batch files
  merge <translations.json> <in_dir> <out_dir>  Merge translated batch files into the dictionary
  unpack-pattern <app.asar>                     Print the --unpack glob for the asar's unpacked files
  verify-unpacked <orig.asar> <new.asar>        Check both archives unpack the same files
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import icu  # noqa: E402

MARK_BEGIN = "/*__czhtw_begin__*/"
MARK_END = "/*__czhtw_end__*/"
RUNTIME = os.path.join(os.path.dirname(os.path.abspath(__file__)), "inject.js")
JS_SPECIAL = re.compile(r"([\\^$.*+?()\[\]{}|/])")
LETTERS = re.compile(r"[A-Za-z]")


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def js_re_escape(s):
    return JS_SPECIAL.sub(r"\\\1", s)


def letters(s):
    return len(LETTERS.findall(s))


def plain_text(tokens):
    """Return the text if tokens are only literal text, else None."""
    if all(t[0] == "text" for t in tokens):
        return "".join(t[1] for t in tokens)
    return None


def build_template(en_toks, zh_toks):
    """Return (regex_source, replacement) or None."""
    # merge adjacent text and trim the outer whitespace (DOM lookup trims too)
    en_toks = _merge(en_toks)
    zh_toks = _merge(zh_toks)
    if not en_toks or not zh_toks:
        return None
    literal = "".join(t[1] for t in en_toks if t[0] == "text")
    if letters(literal) < 2:
        return None
    # With little literal text, free-text captures match unrelated sentences
    # ("{m}m {s}s" would rewrite "Emails from … sessions", "About {x}" user-named chats),
    # so such templates only capture numbers.
    words = re.findall(r"[A-Za-z]+", literal)
    long_words = sum(len(w) >= 3 for w in words)
    strong = long_words >= 2 or (len(words) >= 2 and any(len(w) >= 5 for w in words))
    # A leading capture ("{x} this week") or several captures ("{a} of Claude {b}") make the
    # match depend on a short suffix, so require more literal words before allowing free text.
    free_args = len({t[1] for t in en_toks if t[0] == "arg"})
    if en_toks[0][0] == "arg" or free_args >= 2:
        strong = strong and long_words >= 3
    free = r"(.+?)" if strong else r"(\d[\d,.]*)"
    groups = {}
    pattern = []
    for t in en_toks:
        if t[0] == "text":
            pattern.append(js_re_escape(t[1]))
        else:
            name = t[1]
            if name in groups:
                pattern.append("\\%d" % groups[name])
            else:
                groups[name] = len(groups) + 1
                pattern.append(r"(\d[\d,.]*)" if t[0] == "num" else free)
    repl = []
    for t in zh_toks:
        if t[0] == "text":
            if repl and isinstance(repl[-1], str):
                repl[-1] += t[1]
            else:
                repl.append(t[1])
        else:
            if t[1] not in groups:
                return None
            repl.append(groups[t[1]])
    return "^" + "".join(pattern) + "$", repl


def _merge(toks):
    out = []
    for t in toks:
        if t[0] == "text" and out and out[-1][0] == "text":
            out[-1] = ("text", out[-1][1] + t[1])
        else:
            out.append(t)
    if out and out[0][0] == "text":
        s = out[0][1].lstrip()
        out = ([("text", s)] if s else []) + out[1:]
    if out and out[-1][0] == "text":
        s = out[-1][1].rstrip()
        out = out[:-1] + ([("text", s)] if s else [])
    return out


def build(translations):
    exact = {}
    fragments = {}
    templates = {}
    skipped = 0
    for en, zh in translations.items():
        if not isinstance(zh, str) or not zh.strip():
            continue
        if "{" not in en and "<" not in en:
            exact[en] = zh
            continue
        try:
            en_nodes = icu.parse(en)
            zh_nodes = icu.parse(zh)
        except icu.ParseError:
            skipped += 1
            continue
        has_tags = any(n[0] == "tag_open" for n in en_nodes) or "<" in en
        for path, en_flat in icu.variants(en_nodes):
            zh_flat = icu.pick_variant(zh_nodes, path)
            en_segs = icu.split_segments(en_flat)
            zh_segs = icu.split_segments(zh_flat)
            if [c for c, _ in en_segs] == [c for c, _ in zh_segs]:
                pairs = list(zip(en_segs, zh_segs))
            else:
                # tag order differs: only pair segments inside identically named tags
                zh_by_tag = {}
                for c, toks in zh_segs:
                    if c:
                        zh_by_tag.setdefault(c, []).append((c, toks))
                pairs = []
                for c, toks in en_segs:
                    if c and zh_by_tag.get(c):
                        pairs.append(((c, toks), zh_by_tag[c].pop(0)))
            for (_, e_toks), (_, z_toks) in pairs:
                e_text = plain_text(e_toks)
                z_text = plain_text(z_toks)
                if e_text is not None:
                    if z_text is None:
                        continue
                    k, v = e_text.strip(), z_text.strip()
                    if not k or not v or letters(k) < 2 or k == v:
                        continue
                    if has_tags:
                        if letters(k) >= 4:
                            fragments.setdefault(k, v)
                    else:
                        exact.setdefault(k, v)
                else:
                    t = build_template(e_toks, z_toks)
                    if t:
                        templates.setdefault(t[0], t[1])
    for k, v in fragments.items():
        exact.setdefault(k, v)
    exact = {k: v for k, v in exact.items() if k != v}
    return exact, templates, skipped


def bucket_templates(templates):
    """Group templates for fast runtime lookup.

    p: keyed by the first 2 chars of a literal prefix, s: by the last 2 chars
    of a literal suffix, m: [anchor, index] pairs for the rest.
    """
    items = []
    buckets = {"p": {}, "s": {}, "m": []}
    for src, repl in sorted(templates.items()):
        idx = len(items)
        items.append([src, repl])
        body = src[1:-1]
        lead = re.match(r"(?:\\.|[^\\(])+", body)
        lead_lit = _unescape(lead.group(0)) if lead else ""
        tail = re.search(r"(?:\\.|[^\\)])+$", body)
        tail_lit = _unescape(tail.group(0)) if tail and not re.search(r"\\\d$", body) else ""
        if len(lead_lit) >= 2:
            buckets["p"].setdefault(lead_lit[:2], []).append(idx)
        elif len(tail_lit) >= 2:
            buckets["s"].setdefault(tail_lit[-2:], []).append(idx)
        else:
            lits = [_unescape(x) for x in re.split(r"\((?:\\.|[^)])*\)|\\\d", body)]
            anchor = max(lits, key=len) if lits else ""
            buckets["m"].append([anchor, idx])
    return items, buckets


def _unescape(s):
    return re.sub(r"\\(.)", r"\1", s)


def cmd_inject(translations_path, main_view):
    translations = load(translations_path)
    exact, templates, skipped = build(translations)
    items, buckets = bucket_templates(templates)
    data = {"d": exact, "t": items, "b": buckets}
    payload = json.dumps(json.dumps(data, ensure_ascii=False, separators=(",", ":")), ensure_ascii=False)
    with open(RUNTIME, encoding="utf-8") as f:
        runtime = f.read().replace("__CZHTW_DATA__", payload)
    injection = MARK_BEGIN + "\n" + runtime + "\n" + MARK_END + "\n"
    content = strip(open(main_view, encoding="utf-8").read())
    marker = "//# sourceMappingURL=mainView.js.map"
    if marker in content:
        content = content.replace(marker, injection + marker)
    else:
        content += "\n" + injection
    with open(main_view, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"mainView.js: {len(exact)} exact strings, {len(items)} templates "
          f"({skipped} unparsable skipped), injection {len(injection):,} bytes")


def strip(content):
    # current format
    content = re.sub(re.escape(MARK_BEGIN) + r"[\s\S]*?" + re.escape(MARK_END) + r"\n?", "", content)
    # legacy (v1) format
    content = re.sub(r";\(function\(\)\{[\s\S]*?window\.__czhtw[\s\S]*?\}\)\(\);\n?", "", content)
    return content


def cmd_strip(main_view):
    content = open(main_view, encoding="utf-8").read()
    with open(main_view, "w", encoding="utf-8") as f:
        f.write(strip(content))


DM_RE = re.compile(r'defaultMessage:"((?:[^"\\]|\\.)*)"')


def js_unescape(raw):
    raw = re.sub(r"\\x([0-9a-fA-F]{2})", r"\\u00\1", raw)
    raw = raw.replace("\\'", "'")
    return json.loads('"' + raw + '"')


def js_escape(s):
    return json.dumps(s, ensure_ascii=False)[1:-1].replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")


def cmd_patch_defaults(translations_path, build_dir):
    translations = load(translations_path)
    total = 0
    files = 0
    for name in sorted(os.listdir(build_dir)):
        if not name.endswith(".js") or name == "mainView.js":
            continue
        path = os.path.join(build_dir, name)
        content = open(path, encoding="utf-8").read()
        count = 0

        def repl(m):
            nonlocal count
            try:
                en = js_unescape(m.group(1))
            except ValueError:
                return m.group(0)
            zh = translations.get(en)
            if not zh:
                return m.group(0)
            count += 1
            return 'defaultMessage:"' + js_escape(zh) + '"'

        new = DM_RE.sub(repl, content)
        if count:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
            total += count
            files += 1
    print(f"main process: {total} defaultMessage strings replaced in {files} files")


def cmd_catalog(translations_path, src, out):
    translations = load(translations_path)
    catalog = load(src)
    result = {}
    hit = 0
    for k, v in catalog.items():
        zh = translations.get(v)
        if zh:
            hit += 1
            result[k] = zh
        else:
            result[k] = v
    with open(out, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print(f"desktop catalog: {hit}/{len(catalog)} messages translated")


def read_asar_header(path):
    import struct
    with open(path, "rb") as f:
        prefix = f.read(16)
        size = struct.unpack("<I", prefix[12:16])[0]
        return json.loads(f.read(size).decode("utf-8"))


def read_asar_files(path, prefix, suffix):
    """Yield (name, bytes) for packed files directly under `prefix` ending with `suffix`."""
    import struct
    with open(path, "rb") as f:
        head = f.read(16)
        base = 8 + struct.unpack("<I", head[4:8])[0]
        header = json.loads(f.read(struct.unpack("<I", head[12:16])[0]).decode("utf-8"))
        node = header
        for part in prefix.strip("/").split("/"):
            node = node["files"][part]
        for name, child in sorted(node["files"].items()):
            if "files" in child or child.get("unpacked") or not name.endswith(suffix):
                continue
            f.seek(base + int(child["offset"]))
            yield prefix + name, f.read(child["size"])


def unpacked_files(path):
    out = []

    def walk(node, prefix):
        for name, child in node.get("files", {}).items():
            p = prefix + "/" + name if prefix else name
            if "files" in child:
                walk(child, p)
            elif child.get("unpacked"):
                out.append(p)

    walk(read_asar_header(path), "")
    return sorted(out)


def cmd_unpack_pattern(asar_path):
    """Print an `asar pack --unpack` glob that keeps the original unpacked files."""
    names = sorted({os.path.basename(p) for p in unpacked_files(asar_path)})
    print("{" + ",".join(names) + (",__none__" if len(names) == 1 else "") + "}" if names else "")


def cmd_verify_unpacked(original, rebuilt):
    a, b = unpacked_files(original), unpacked_files(rebuilt)
    if a != b:
        print("unpacked file mismatch:\n  original: %s\n  rebuilt:  %s" % (a, b))
        sys.exit(1)
    print(f"unpacked files preserved ({len(a)})")


def collect_sources(app_path):
    """All English UI messages shipped with a Claude.app."""
    res = os.path.join(app_path, "Contents", "Resources")
    found = {}
    catalog = "en-US.json.bak" if os.path.exists(os.path.join(res, "en-US.json.bak")) else "en-US.json"
    for rel in ("ion-dist/i18n/en-US.json", "ion-dist/i18n/dynamic/en-US.json", catalog):
        path = os.path.join(res, rel)
        if os.path.exists(path):
            for v in load(path).values():
                if isinstance(v, str) and v.strip():
                    found[v] = 1
    asar = os.path.join(res, "app.asar.bak")
    if not os.path.exists(asar):
        asar = os.path.join(res, "app.asar")
    for name, data in read_asar_files(asar, ".vite/build/", ".js"):
        if name.endswith("/mainView.js"):
            continue
        for raw in DM_RE.findall(data.decode("utf-8", "replace")):
            try:
                v = js_unescape(raw)
            except ValueError:
                continue
            if v.strip():
                found[v] = 1
    for v in collect_cache_sources():
        found[v] = 1
    return sorted(found)


CACHE_DIR = os.path.expanduser("~/Library/Application Support/Claude/Cache/Cache_Data")
CACHE_EOF = bytes.fromhex("d8410d97456ffaf4")  # Chromium simple-cache stream terminator
DM_ANY_RE = re.compile(r'defaultMessage:(?:"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'|`([^`$\\]*)`)')


def collect_cache_sources():
    """defaultMessages from claude.ai bundles in Claude's HTTP cache.

    The remote web UI is often newer than the catalog shipped in ion-dist, so the
    cached bundles carry strings the app copy does not have yet.
    """
    if not os.path.isdir(CACHE_DIR):
        return []
    try:
        import zstandard
    except ImportError:
        print("note: pip install zstandard to include strings from Claude's web cache", file=sys.stderr)
        return []
    found = {}
    for name in os.listdir(CACHE_DIR):
        if not name.endswith("_0"):
            continue
        with open(os.path.join(CACHE_DIR, name), "rb") as f:
            blob = f.read()
        if len(blob) < 24:
            continue
        key_len = int.from_bytes(blob[12:16], "little")
        key = blob[24:24 + key_len].decode("latin1")
        if "assets-proxy.anthropic.com" not in key or not re.search(r"\.js(\?|$)", key):
            continue
        body = blob[24 + key_len:]
        end = body.find(CACHE_EOF)
        if end > 0:
            body = body[:end]
        try:
            text = zstandard.ZstdDecompressor().decompressobj().decompress(body).decode("utf-8")
        except Exception:
            try:
                text = body.decode("utf-8")
            except UnicodeDecodeError:
                continue
        for dq, sq, bt in DM_ANY_RE.findall(text):
            raw = dq or sq or bt
            try:
                v = js_unescape(raw) if (dq or sq) else raw
            except ValueError:
                continue
            if v.strip():
                found[v] = 1
    return list(found)


def cmd_missing(translations_path, app_path, out_dir):
    """Write untranslated source strings into batch files <out_dir>/bNNN.json."""
    translations = load(translations_path)
    missing = [s for s in collect_sources(app_path) if s not in translations]
    os.makedirs(out_dir, exist_ok=True)
    batches, cur, size = [], {}, 0
    for n, s in enumerate(missing, 1):
        cur["k%05d" % n] = s
        size += len(s)
        if size >= 18000 or len(cur) >= 450:
            batches.append(cur)
            cur, size = {}, 0
    if cur:
        batches.append(cur)
    for i, b in enumerate(batches):
        with open(os.path.join(out_dir, "b%03d.json" % i), "w", encoding="utf-8") as f:
            json.dump(b, f, ensure_ascii=False, indent=0)
    print(f"{len(missing)} untranslated strings -> {len(batches)} batches in {out_dir}")


def cmd_merge(translations_path, in_dir, out_dir):
    """Merge translated batches (<out_dir>/bNNN.json keyed like <in_dir>) into the dictionary."""
    translations = load(translations_path)
    added = 0
    for name in sorted(os.listdir(in_dir)):
        out_path = os.path.join(out_dir, name)
        if not name.endswith(".json") or not os.path.exists(out_path):
            continue
        src, out = load(os.path.join(in_dir, name)), load(out_path)
        for k, en in src.items():
            zh = out.get(k)
            if isinstance(zh, str) and zh.strip() and en not in translations:
                translations[en] = zh
                added += 1
    with open(translations_path, "w", encoding="utf-8") as f:
        json.dump(dict(sorted(translations.items())), f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"merged {added} new translations ({len(translations)} total)")


def cmd_stats(translations_path):
    exact, templates, skipped = build(load(translations_path))
    items, buckets = bucket_templates(templates)
    print(f"exact={len(exact)} templates={len(items)} skipped={skipped} "
          f"prefix_buckets={len(buckets['p'])} suffix_buckets={len(buckets['s'])} misc={len(buckets['m'])}")


def main():
    cmds = {"inject": cmd_inject, "strip": cmd_strip, "patch-defaults": cmd_patch_defaults,
            "catalog": cmd_catalog, "stats": cmd_stats,
            "unpack-pattern": cmd_unpack_pattern, "missing": cmd_missing, "merge": cmd_merge, "verify-unpacked": cmd_verify_unpacked}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        print(__doc__)
        sys.exit(2)
    cmds[sys.argv[1]](*sys.argv[2:])


if __name__ == "__main__":
    main()
