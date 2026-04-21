#!/usr/bin/env python3
# features_audit.py — cross-reference FEATURES.md claims against
# the codebase to distinguish verified features from aspirational ones.
#
# For each bullet in FEATURES.md:
#   1. extract code-like identifiers (PascalCase, backticked tokens,
#      Hecks::Namespaced names)
#   2. grep lib/, hecks_life/src/, hecks_conception/aggregates/**,
#      hecks_conception/capabilities/**, and spec/ for evidence
#   3. classify: verified | missing | unverifiable
#
# Usage:
#   python3 tools/features_audit.py              # summary report
#   python3 tools/features_audit.py --missing    # list missing claims
#   python3 tools/features_audit.py --section "Attributes"   # filter
#   python3 tools/features_audit.py --json       # machine-readable
#
# "verified" = at least one extracted identifier found in a searched path.
# "missing"  = identifiers exist but none were found anywhere.
# "unverifiable" = no code-like identifiers to grep on (pure prose).

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FEATURES = REPO / "FEATURES.md"

# Paths searched for evidence. Order matters only for reporting.
SEARCH_PATHS = [
    ("ruby", REPO / "lib"),
    ("rust", REPO / "hecks_life" / "src"),
    ("bluebook_aggregates", REPO / "hecks_conception" / "aggregates"),
    ("bluebook_capabilities", REPO / "hecks_conception" / "capabilities"),
    ("tests", REPO / "spec"),
    ("examples", REPO / "examples"),
    ("bin", REPO / "bin"),
    ("claude_config", REPO / ".claude"),
]

# Token shapes we strip before classifying — these aren't claims about
# implemented APIs, they're prose artifacts:
#   - <placeholder>.<method>  (Some*.foo, handle.build, OrdersDomain.x)
#   - <file>.md                (doc cross-references)
#   - model.<predicate>?       (generated predicate example)
PLACEHOLDER_PREFIXES = (
    "Some", "My", "handle.", "model.", "Orders", "TheModel",
)

# Token extraction patterns. We only trust tokens with enough shape to
# grep usefully — short English words would match everything.
BACKTICKED = re.compile(r"`([^`\n]{2,120})`")
PASCAL = re.compile(r"\b([A-Z][a-z]+(?:[A-Z][a-z]+){1,})\b")      # e.g. CreatePizza
NAMESPACED = re.compile(r"\b([A-Z]\w*(?:::[A-Z]\w*)+)\b")         # Hecks::Chapters::Bootstrap
DOTTED = re.compile(r"\b([A-Za-z_]\w+(?:\.\w+){1,})\b")           # Hecks.domain, Kernel.load
SYMBOL = re.compile(r":([a-z_][a-z0-9_]{2,})\b")                  # :status, :integer
# Inside backticks we also allow DSL keywords like `emits`, `list_of`,
# `reference_to`, `sets`, `lifecycle`, `saga`, `service` — single-word
# tokens that would be too noisy outside a code context.

# Prose tokens we refuse to search for (too noisy — match anywhere).
STOPWORDS = {
    "string", "integer", "float", "boolean", "date", "datetime", "json",
    "name", "type", "value", "block", "test", "spec", "file", "line",
    "true", "false", "none", "some", "all", "any", "each", "every",
    "one", "two", "three", "first", "last", "next", "new",
    "id", "ids", "uuid", "key", "keys", "field", "fields",
}


def _extract_backticked(text):
    """Inside-backtick tokens are trusted even if single-word —
    `emits`, `reference_to`, etc."""
    out = []
    for m in BACKTICKED.finditer(text):
        body = m.group(1).strip()
        # Prefer the first "identifier-like" chunk; split on spaces, parens,
        # braces. Take tokens of length >= 3, reject stopwords.
        for chunk in re.split(r"[\s(){}\[\]\"',]+", body):
            chunk = chunk.strip(".:=>")
            if not chunk or chunk.lower() in STOPWORDS:
                continue
            # allow :symbol, Word, snake_case_word, Name.Thing, Name::Thing
            if re.match(r"^[A-Za-z_:][\w:.!?]*$", chunk) and len(chunk) >= 3:
                out.append(chunk)
    return out


def _extract_outside_backticks(text):
    """Only trust shapes strong enough to not match English:
    PascalCase (2+ humps), dotted, namespaced, :symbol (len>=3)."""
    out = []
    out.extend(m.group(1) for m in PASCAL.finditer(text))
    out.extend(m.group(1) for m in NAMESPACED.finditer(text))
    out.extend(m.group(1) for m in DOTTED.finditer(text) if "." in m.group(1))
    out.extend(":" + m.group(1) for m in SYMBOL.finditer(text))
    return out


def _is_placeholder(token):
    """True for tokens that are prose artifacts, not code claims."""
    if token.endswith(".md"):
        return True  # doc cross-reference
    for p in PLACEHOLDER_PREFIXES:
        if token.startswith(p) and "." in token:
            return True
    # model.<predicate>? is a generated-predicate example.
    if re.match(r"^model\.\w+\?$", token):
        return True
    return False


def extract_identifiers(claim):
    """Return a list of greppable identifiers, deduped, ordered."""
    # Remove backticked bodies from outside-check to avoid double-count.
    bt_tokens = _extract_backticked(claim)
    outside = BACKTICKED.sub(" ", claim)
    plain_tokens = _extract_outside_backticks(outside)
    seen = set()
    ordered = []
    for t in bt_tokens + plain_tokens:
        if t in seen or _is_placeholder(t):
            continue
        seen.add(t)
        ordered.append(t)
    return ordered


def parse_features(path):
    """Parse FEATURES.md into a list of {section, subsection, line, text}."""
    claims = []
    section = subsection = ""
    in_banner = False
    for i, raw in enumerate(path.read_text().splitlines(), start=1):
        line = raw.rstrip()
        if line.startswith("> "):
            in_banner = True
            continue
        if in_banner and not line.startswith(">"):
            in_banner = False
        if line.startswith("## "):
            section = line[3:].strip()
            subsection = ""
            continue
        if line.startswith("### "):
            subsection = line[4:].strip()
            continue
        # bullet
        m = re.match(r"^[-*]\s+(.*)$", line)
        if not m:
            continue
        claims.append({
            "line": i,
            "section": section,
            "subsection": subsection,
            "text": m.group(1).strip(),
        })
    return claims


def _rg_count(pattern, path, fixed=True):
    """Run rg and return count of matching files. 0 on any error."""
    try:
        flags = ["--no-messages", "-l"]
        if fixed:
            flags.append("-F")
        out = subprocess.run(
            ["rg", *flags, pattern, str(path)],
            capture_output=True, text=True, timeout=10,
        )
        return len([x for x in out.stdout.splitlines() if x.strip()])
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return 0


def search_token(token, search_paths):
    """Return dict of category → int count of matching files.

    For `Foo.bar` tokens, also check `def self.bar` and `def bar` under
    any path that also mentions `Foo` — catches class-method conventions
    where the literal `Foo.bar` never appears in the source.
    """
    hits = {}
    # Split <head>.<method> tokens for a method-def fallback.
    method_def_self = method_def_inst = class_head = None
    m = re.match(r"^([A-Za-z_][\w:]*)\.([a-z_]\w*)$", token)
    if m:
        class_head, method_name = m.group(1), m.group(2)
        method_def_self = f"def self.{method_name}"
        method_def_inst = f"def {method_name}"

    for label, p in search_paths:
        if not p.exists():
            hits[label] = 0
            continue
        n = _rg_count(token, p, fixed=True)
        if n == 0 and method_def_self:
            # PascalCase head → class method. Only count if the class
            # name also appears in the tree. Lowercase head → instance
            # method on whatever; count the def itself.
            if class_head[:1].isupper():
                if _rg_count(class_head, p, fixed=True) > 0:
                    n = _rg_count(method_def_self, p, fixed=True)
            else:
                n = _rg_count(method_def_inst, p, fixed=True)
        hits[label] = n
    return hits


def classify(claim, tokens, hits_by_token):
    if not tokens:
        return "unverifiable"
    # Verified if any token has at least one hit anywhere.
    for t in tokens:
        if any(c > 0 for c in hits_by_token.get(t, {}).values()):
            return "verified"
    return "missing"


def run_audit(claims):
    results = []
    for c in claims:
        tokens = extract_identifiers(c["text"])
        hits = {t: search_token(t, SEARCH_PATHS) for t in tokens}
        verdict = classify(c, tokens, hits)
        results.append({**c, "tokens": tokens, "hits": hits, "verdict": verdict})
    return results


def print_summary(results):
    by_verdict = {"verified": 0, "missing": 0, "unverifiable": 0}
    for r in results:
        by_verdict[r["verdict"]] += 1
    total = len(results)
    print(f"\nFEATURES.md audit — {total} claims\n")
    for v, n in by_verdict.items():
        pct = (100 * n / total) if total else 0
        print(f"  {v:<13} {n:>4}  ({pct:5.1f}%)")
    print("\nBy section:")
    sections = {}
    for r in results:
        key = r["section"] + (f" / {r['subsection']}" if r["subsection"] else "")
        sections.setdefault(key, {"v": 0, "m": 0, "u": 0})
        k = {"verified": "v", "missing": "m", "unverifiable": "u"}[r["verdict"]]
        sections[key][k] += 1
    for name, c in sections.items():
        total = sum(c.values())
        print(f"  {name}  — v {c['v']}, m {c['m']}, u {c['u']}  ({total})")


def print_missing(results, limit=None):
    missing = [r for r in results if r["verdict"] == "missing"]
    print(f"\nMissing — {len(missing)} claims with identifiers but no codebase hits:\n")
    for r in missing[:limit]:
        sec = f"{r['section']}" + (f" / {r['subsection']}" if r["subsection"] else "")
        print(f"  L{r['line']}  [{sec}]")
        print(f"    {r['text'][:110]}{'…' if len(r['text']) > 110 else ''}")
        print(f"    searched: {', '.join(r['tokens'])}")
        print()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--missing", action="store_true", help="list missing claims")
    ap.add_argument("--unverifiable", action="store_true", help="list unverifiable claims")
    ap.add_argument("--section", help="filter to sections matching this substring")
    ap.add_argument("--limit", type=int, default=None, help="cap listing output")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    claims = parse_features(FEATURES)
    if args.section:
        s = args.section.lower()
        claims = [c for c in claims
                  if s in c["section"].lower() or s in c["subsection"].lower()]

    print(f"auditing {len(claims)} claims against {len(SEARCH_PATHS)} source trees…",
          file=sys.stderr)
    results = run_audit(claims)

    if args.json:
        print(json.dumps(results, indent=2))
        return

    print_summary(results)
    if args.missing:
        print_missing(results, limit=args.limit)
    if args.unverifiable:
        unv = [r for r in results if r["verdict"] == "unverifiable"]
        print(f"\nUnverifiable — {len(unv)} claims (no code-like identifiers):\n")
        for r in unv[:args.limit]:
            sec = f"{r['section']}" + (f" / {r['subsection']}" if r["subsection"] else "")
            print(f"  L{r['line']}  [{sec}]  {r['text'][:100]}")


if __name__ == "__main__":
    main()
