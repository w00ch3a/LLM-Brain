#!/usr/bin/env python3
"""Derived, read-only memory signals for LLM-Brain.

Every command in this helper is a pure function of the vault files it is
given: canonical OKF records, opt-in retrieval receipts, retrieval feedback,
review items, intentions and (for code anchors) read-only ``git`` queries.
Nothing here writes canonical memory, promotes review items or deletes
anything.  Outputs are deterministic for a fixed vault and ``--now`` value,
so they can be rebuilt or discarded at any time.

The CLI (``bin/llm-brain``) owns locking, audit and all persistent writes.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import math
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

sys.dont_write_bytecode = True  # never write __pycache__ into an installed package
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import okf  # noqa: E402  (sibling helper; PyYAML-backed strict OKF parser)

TOKEN_RE = re.compile(r"[a-z0-9]+")
PATH_HINT_RE = re.compile(
    r"(?<![A-Za-z0-9_])((?:[A-Za-z0-9_.@-]+/)+[A-Za-z0-9_.@*-]+|[A-Za-z0-9_-]+\.(?:py|pyi|js|jsx|ts|tsx|mjs|cjs|go|rs|rb|java|kt|swift|c|h|cc|cpp|hpp|cs|php|sh|bash|zsh|md|json|yaml|yml|toml|ini|cfg|sql|html|css|scss|vue|svelte|lock|tf|gradle|xml))(?![A-Za-z0-9_])"
)
EXPANSION_RE = re.compile(r"^Expansion: <code>([^<]+)</code>", re.MULTILINE)
ANCHOR_RE = re.compile(r"^(?P<path>[^@\s][^@]*)@(?P<commit>[0-9a-fA-F]{7,40})$")
INTENTION_TRIGGERS = ("date", "path", "keyword", "state")
INTENTION_STATUSES = ("open", "done", "cancelled")
RELATION_FIELDS = (
    "brain_supports",
    "brain_conflicts",
    "brain_supersedes",
    "brain_version_of",
    "brain_depends_on",
    "brain_derived_from",
)
# Field weights for BM25F.  Titles carry the most signal, structured
# frontmatter (state keys, topics, tags, paths) next, then the body.
BM25_FIELD_WEIGHTS = {"title": 3.0, "meta": 1.5, "body": 1.0}
BM25_B = {"title": 0.3, "meta": 0.5, "body": 0.75}
BM25_K1 = 1.2
PHRASE_BONUS = 2.0
PATH_BOOST = 6.0
# Fields that never carry retrievable meaning (hashes, ids, bookkeeping).
META_SKIP = re.compile(
    r"(hash|sha256|_id$|^brain_schema_version$|^okf_version$|_at$|^timestamp$|^generated$|^verified$|^brain_provenance$|^brain_source_ref$|^brain_code_anchors$)"
)
# FSRS-4.5 default parameters (open-spaced-repetition).  Difficulty is held
# at a neutral 5 because memory records have no per-item grading history.
FSRS_W = (
    0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2298, 0.8975, 0.031,
    1.6474, 0.1367, 1.0461, 2.1072, 0.0793, 0.3246, 1.587, 0.2272, 2.8755,
)
FSRS_DECAY = -0.5
FSRS_FACTOR = 19.0 / 81.0
FSRS_DIFFICULTY = 5.0
FSRS_MAX_DAYS = 365.0
FSRS_MIN_DAYS = 1.0
FSRS_RETENTION = 0.9


# ---------------------------------------------------------------- utilities

def now_from(value: str) -> dt.datetime:
    if value:
        parsed = parse_time(value)
        if parsed is None:
            raise SystemExit("memory-signals: --now must be an ISO-8601 datetime with timezone")
        return parsed
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def parse_time(value: Any) -> dt.datetime | None:
    if isinstance(value, dt.datetime):
        return value if value.tzinfo else value.replace(tzinfo=dt.timezone.utc)
    if isinstance(value, dt.date):
        return dt.datetime(value.year, value.month, value.day, tzinfo=dt.timezone.utc)
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    try:
        if okf.DATE_RE.fullmatch(text):
            day = dt.date.fromisoformat(text)
            return dt.datetime(day.year, day.month, day.day, tzinfo=dt.timezone.utc)
        parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(dt.timezone.utc)


def iso(value: dt.datetime | None) -> str:
    if value is None:
        return ""
    return value.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def clean(value: Any) -> str:
    return okf.scalar_text(value).replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def tokens(text: str) -> list[str]:
    return [token for token in TOKEN_RE.findall(text.lower()) if len(token) > 2]


def query_terms(query: str) -> list[str]:
    seen: list[str] = []
    for token in tokens(query):
        if token not in seen:
            seen.append(token)
    return seen


def ref_list(value: Any) -> list[str]:
    return okf.LifecycleResolver.refs(value)


def first_sentence(body: str, limit: int = 180) -> str:
    lines = []
    for line in body.splitlines():
        text = line.strip()
        if not text or text.startswith("#") or text.startswith("```"):
            continue
        lines.append(text.lstrip("-*+ ").strip())
        if sum(len(item) for item in lines) > limit:
            break
    text = " ".join(lines)
    match = re.search(r"(.+?[.!?])(\s|$)", text)
    if match and len(match.group(1)) <= limit:
        text = match.group(1)
    if len(text) > limit:
        text = text[: limit - 1].rstrip() + "…"
    return text


def lead_sentences(body: str, limit: int = 200) -> str:
    """Whole leading sentences up to ``limit`` characters.

    A first sentence such as "Correction: erratum X corrects Y." carries no
    value on its own; following sentences are kept while they fit, so the
    corrected value or instruction is not cut from briefs and notices.
    """
    lines = []
    for line in body.splitlines():
        text = line.strip()
        if not text or text.startswith("#") or text.startswith("```"):
            continue
        lines.append(text.lstrip("-*+ ").strip())
        if sum(len(item) for item in lines) > limit * 2:
            break
    text = " ".join(lines)
    sentences = re.findall(r".+?[.!?](?=\s|$)|.+$", text)
    result = ""
    for sentence in sentences:
        candidate = (result + " " + sentence.strip()).strip()
        if len(candidate) > limit:
            break
        result = candidate
    if not result:
        result = first_sentence(body, limit)
    return result


def keyword_stem(word: str) -> str:
    """Conservative suffix stripping so "recommend" names "recommendation"."""
    word = word.lower()
    for suffix in ("ations", "ation", "ments", "ment", "ings", "ing", "ers", "er", "ed", "es", "s"):
        if word.endswith(suffix) and len(word) - len(suffix) >= 5:
            return word[: -len(suffix)]
    return word


def utf8_len(text: str) -> int:
    return len(text.encode("utf-8"))


def emit_tsv(rows: Iterable[Iterable[Any]]) -> None:
    for row in rows:
        print("\t".join(clean(value) for value in row))


class Vault:
    """Read-only view over one project directory."""

    def __init__(self, project_dir: str, principal: str = "") -> None:
        self.root = Path(project_dir).expanduser().resolve()
        self.principal = principal or ""
        self.resolver = okf.LifecycleResolver(self.root, self.principal)
        self._superseded: set[Path] | None = None

    def meta(self, path: Path) -> dict[str, Any]:
        return self.resolver.load(path)

    def body(self, path: Path) -> str:
        self.resolver.load(path)
        return self.resolver.bodies.get(path.resolve(), "")

    def rel(self, path: Path) -> str:
        return self.resolver.relative(path)

    def title(self, path: Path) -> str:
        value = clean(self.meta(path).get("title"))
        return value or path.stem

    def superseded(self) -> set[Path]:
        if self._superseded is None:
            result: set[Path] = set()
            for path in self.resolver.files:
                if not self.resolver.effective(path):
                    continue
                for field in ("brain_supersedes",):
                    for ref in ref_list(self.meta(path).get(field)):
                        target = self.resolver.canonical_ref(ref)
                        if target is not None and target != path:
                            result.add(target)
            self._superseded = result
        return self._superseded

    def eligible(self, path: Path, now: dt.datetime, *, include_cold: bool = False) -> bool:
        """Approved, visible, current and not retired; the conservative brief view."""
        resolver = self.resolver
        if not resolver.effective(path) or not resolver.visible(path, strict_principal=True):
            return False
        metadata = self.meta(path)
        if metadata.get("type") in ("Project", "Directory"):
            return False
        if not include_cold and clean(metadata.get("brain_loading_temperature")) == "cold":
            return False
        if path in self.superseded():
            return False
        valid_to = parse_time(metadata.get("brain_valid_to"))
        if valid_to is not None and valid_to <= now:
            return False
        valid_from = parse_time(metadata.get("brain_valid_from"))
        if valid_from is not None and valid_from > now:
            return False
        return True

    def semantic_files(self) -> list[Path]:
        return [path for path in self.resolver.files if path.parent.name != "retractions"]

    def frontmatter_dir(self, folder: str) -> list[tuple[Path, dict[str, Any], str]]:
        directory = self.root / folder
        records: list[tuple[Path, dict[str, Any], str]] = []
        if not directory.is_dir():
            return records
        for path in sorted(directory.glob("*.md")):
            if path.is_symlink() or not path.is_file():
                continue
            try:
                metadata, body = okf.split_frontmatter(path)
            except okf.OkfError:
                continue
            records.append((path, metadata, body))
        return records


# ------------------------------------------------------------ path matching

def glob_regex(pattern: str) -> re.Pattern[str]:
    pattern = pattern.strip()
    while pattern.startswith("./"):
        pattern = pattern[2:]
    result = ""
    index = 0
    while index < len(pattern):
        char = pattern[index]
        if char == "*":
            if pattern[index : index + 3] == "**/":
                result += "(?:.*/)?"
                index += 3
                continue
            if pattern[index : index + 2] == "**":
                result += ".*"
                index += 2
                continue
            result += "[^/]*"
        elif char == "?":
            result += "[^/]"
        else:
            result += re.escape(char)
        index += 1
    return re.compile(f"^{result}$")


def normalise_hint(hint: str) -> str:
    text = hint.strip().strip("`'\"()[]{}<>,;:")
    while text.startswith("./"):
        text = text[2:]
    return text.rstrip("/")


def path_suffixes(hint: str) -> list[str]:
    parts = [part for part in PurePosixPath(hint).parts if part not in ("/", "")]
    return ["/".join(parts[index:]) for index in range(len(parts))]


def path_matches(globs: list[str], hints: list[str]) -> str:
    for pattern in globs:
        if not pattern.strip():
            continue
        regex = glob_regex(pattern)
        for hint in hints:
            for suffix in path_suffixes(hint):
                if regex.match(suffix) or fnmatch.fnmatchcase(suffix, pattern):
                    return f"{pattern}~{hint}"
    return ""


def hints_from(query: str, explicit: list[str]) -> list[str]:
    hints = [normalise_hint(item) for item in explicit if normalise_hint(item)]
    for match in PATH_HINT_RE.finditer(query or ""):
        value = normalise_hint(match.group(1))
        if value and "://" not in value and value not in hints:
            hints.append(value)
    return hints


# ------------------------------------------------------------------ BM25F

def bm25_fields(path: Path) -> tuple[dict[str, str], dict[str, Any]]:
    raw = path.read_bytes().decode("utf-8", "replace")
    metadata, body = okf.split_frontmatter_text(raw)
    title = clean(metadata.get("title"))
    meta_values: list[str] = []
    for key in sorted(metadata):
        if key == "title" or META_SKIP.search(key):
            continue
        value = metadata[key]
        if isinstance(value, (list, tuple)):
            meta_values.extend(clean(item) for item in value)
        elif isinstance(value, dict):
            continue
        else:
            meta_values.append(clean(value))
    return {"title": title, "meta": " ".join(meta_values), "body": body}, metadata


def term_frequency(field_tokens: list[str], lowered: str, term: str) -> float:
    count = 0.0
    for token in field_tokens:
        if token == term or (len(term) >= 4 and token.startswith(term)):
            count += 1.0
    if count == 0.0 and term in lowered:
        # Preserve the historical substring recall of the grep scorer at a
        # discounted weight (e.g. identifiers glued to other words).
        count = 0.5
    return count


def command_bm25(args: argparse.Namespace) -> int:
    project = Path(args.project_dir).resolve()
    paths = [line.strip() for line in Path(args.paths_file).read_text(encoding="utf-8").splitlines() if line.strip()]
    terms = query_terms(args.query)
    phrase = args.query.strip().lower()
    hints = hints_from(args.query, args.hint_path or [])
    documents: list[tuple[str, dict[str, list[str]], dict[str, str], list[str]]] = []
    for item in paths:
        path = Path(item)
        try:
            fields, metadata = bm25_fields(path)
        except (OSError, okf.OkfError):
            continue
        try:
            rel = path.resolve().relative_to(project).as_posix()
        except ValueError:
            continue
        globs = ref_list(metadata.get("brain_paths"))
        lowered = {name: text.lower() for name, text in fields.items()}
        documents.append((rel, {name: tokens(text) for name, text in fields.items()}, lowered, globs))
    total = len(documents)
    if total == 0:
        return 0
    average = {
        name: max(sum(len(doc[1][name]) for doc in documents) / total, 1.0)
        for name in BM25_FIELD_WEIGHTS
    }
    frequencies: dict[str, dict[int, dict[str, float]]] = {}
    document_frequency: dict[str, int] = {}
    for term in terms:
        per_doc: dict[int, dict[str, float]] = {}
        for index, (_, field_tokens, lowered, _) in enumerate(documents):
            values = {name: term_frequency(field_tokens[name], lowered[name], term) for name in BM25_FIELD_WEIGHTS}
            if any(values.values()):
                per_doc[index] = values
        frequencies[term] = per_doc
        document_frequency[term] = len(per_doc)
    rows: list[tuple[str, float, str]] = []
    for index, (rel, field_tokens, lowered, globs) in enumerate(documents):
        score = 0.0
        for term in terms:
            values = frequencies[term].get(index)
            if not values:
                continue
            combined = 0.0
            for name, weight in BM25_FIELD_WEIGHTS.items():
                length = len(field_tokens[name])
                normaliser = 1.0 - BM25_B[name] + BM25_B[name] * (length / average[name])
                combined += weight * values[name] / max(normaliser, 1e-9)
            df = document_frequency[term]
            idf = math.log(1.0 + (total - df + 0.5) / (df + 0.5))
            score += idf * combined / (BM25_K1 + combined)
        if score > 0 and len(terms) > 1 and phrase and any(phrase in lowered[name] for name in lowered):
            score += PHRASE_BONUS
        matched = path_matches(globs, hints) if globs and hints else ""
        if matched:
            score += PATH_BOOST
        if score > 0:
            rows.append((rel, round(score, 6), matched))
    rows.sort(key=lambda row: (-row[1], row[0]))
    for rel, score, matched in rows:
        print(f"{rel}\t{score:.6f}\t{matched or '-'}")
    return 0


# ------------------------------------------------------------- usage data

def read_receipts(root: Path) -> list[dict[str, Any]]:
    receipt = root / "audit" / "retrieval-receipts.jsonl"
    rows: list[dict[str, Any]] = []
    if not receipt.is_file() or receipt.is_symlink():
        return rows
    with receipt.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if isinstance(value, dict) and isinstance(value.get("selected", []), list):
                rows.append(value)
    return rows


def pack_refs(root: Path, pack_ref: str, expected_hash: str) -> list[str]:
    text, error = okf.LifecycleResolver._safe_ref(pack_ref)
    if error:
        return []
    pack = root / text
    if not pack.is_file() or pack.is_symlink():
        return []
    raw = pack.read_bytes()
    if expected_hash and hashlib.sha256(raw).hexdigest() != expected_hash:
        return []
    refs = []
    for match in EXPANSION_RE.finditer(raw.decode("utf-8", "replace")):
        ref = match.group(1).strip()
        if ref.startswith("okf/") and ref not in refs:
            refs.append(ref)
    return refs


def feedback_rows(vault: Vault) -> list[tuple[str, str, list[str], dt.datetime | None]]:
    rows = []
    for path, metadata, _ in vault.frontmatter_dir("feedback"):
        if metadata.get("type") != "RetrievalFeedback":
            continue
        usefulness = clean(metadata.get("brain_usefulness"))
        refs = pack_refs(vault.root, clean(metadata.get("brain_pack_ref")), clean(metadata.get("brain_pack_hash_sha256")))
        rows.append((path.name, usefulness, refs, parse_time(metadata.get("brain_recorded_at"))))
    return rows


def usage_table(vault: Vault) -> tuple[dict[str, dict[str, Any]], int]:
    table: dict[str, dict[str, Any]] = defaultdict(lambda: {
        "uses": 0, "rendered": 0, "useful": 0, "partial": 0, "not_useful": 0, "last_used": None,
    })
    receipts = read_receipts(vault.root)
    for receipt in receipts:
        when = parse_time(receipt.get("recorded_at"))
        selected = [item for item in receipt.get("selected", []) if isinstance(item, str)]
        rendered = [item for item in receipt.get("rendered_selection", []) if isinstance(item, str)]
        for ref in sorted(set(selected)):
            if not ref.startswith("okf/"):
                continue
            entry = table[ref]
            entry["uses"] += 1
            if when and (entry["last_used"] is None or when > entry["last_used"]):
                entry["last_used"] = when
        for ref in sorted(set(rendered)):
            if ref.startswith("okf/"):
                table[ref]["rendered"] += 1
    for _, usefulness, refs, when in feedback_rows(vault):
        key = {"useful": "useful", "partial": "partial", "not-useful": "not_useful"}.get(usefulness)
        if not key:
            continue
        for ref in refs:
            entry = table[ref]
            entry[key] += 1
            if when and (entry["last_used"] is None or when > entry["last_used"]):
                entry["last_used"] = when
    return table, len(receipts)


def record_created(metadata: dict[str, Any]) -> dt.datetime | None:
    generated = metadata.get("generated")
    candidates = [
        metadata.get("brain_observed_at"),
        generated.get("at") if isinstance(generated, dict) else None,
        metadata.get("timestamp"),
    ]
    for value in candidates:
        parsed = parse_time(value)
        if parsed is not None:
            return parsed
    return None


def command_usage(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    now = now_from(args.now)
    table, receipt_count = usage_table(vault)
    rows = []
    for path in vault.semantic_files():
        if not vault.resolver.effective(path) or not vault.resolver.visible(path, strict_principal=True):
            continue
        rel = vault.rel(path)
        entry = table.get(rel, {"uses": 0, "rendered": 0, "useful": 0, "partial": 0, "not_useful": 0, "last_used": None})
        rows.append((rel, entry, vault.title(path), record_created(vault.meta(path))))
    if args.json:
        print(json.dumps({
            "status": "ok", "receipts": receipt_count, "derived": True, "now": iso(now),
            "records": [
                {"ref": rel, "title": title, "uses": entry["uses"], "rendered": entry["rendered"],
                 "useful": entry["useful"], "partial": entry["partial"], "not_useful": entry["not_useful"],
                 "last_used": iso(entry["last_used"]) or None}
                for rel, entry, title, _ in rows
            ],
        }, ensure_ascii=False, separators=(",", ":")))
        return 0
    print("ref\tuses\trendered\tuseful\tpartial\tnot_useful\tlast_used\ttitle")
    for rel, entry, title, _ in rows:
        print(f"{rel}\t{entry['uses']}\t{entry['rendered']}\t{entry['useful']}\t{entry['partial']}\t{entry['not_useful']}\t{iso(entry['last_used']) or 'never'}\t{clean(title)}")
    return 0


def retention_signals(vault: Vault, now: dt.datetime, grace_days: int, idle_days: int) -> list[tuple[str, str, str, str, str, str]]:
    table, receipt_count = usage_table(vault)
    if receipt_count == 0 and not any(entry["useful"] + entry["partial"] + entry["not_useful"] for entry in table.values()):
        # Receipts are opt-in; without any usage evidence "never used" would
        # be a false signal for every record.
        return []
    rows = []
    for path in vault.semantic_files():
        if not vault.eligible(path, now, include_cold=True):
            continue
        rel = vault.rel(path)
        entry = table.get(rel)
        created = record_created(vault.meta(path))
        old_enough = created is None or (now - created).days >= grace_days
        title = vault.title(path)
        if entry is None or (entry["uses"] == 0 and entry["useful"] + entry["partial"] + entry["not_useful"] == 0):
            if old_enough:
                rows.append(("retention-signal", rel, title, "never-used", f"unused-across-{receipt_count}-receipts", "review-retention"))
            continue
        if entry["not_useful"] >= 2 and entry["useful"] == 0:
            rows.append(("retention-signal", rel, title, "mostly-not-useful", f"not-useful={entry['not_useful']}", "review-retention"))
        elif entry["last_used"] is not None and (now - entry["last_used"]).days >= idle_days:
            rows.append(("retention-signal", rel, title, "idle", f"last-used={iso(entry['last_used'])}", "review-retention"))
    return rows


# --------------------------------------------------------- doctor findings

def shingles(words: list[str], size: int = 3) -> set[str]:
    if len(words) < size:
        return {" ".join(words)} if words else set()
    return {" ".join(words[index : index + size]) for index in range(len(words) - size + 1)}


def normalised_title(title: str) -> str:
    return " ".join(TOKEN_RE.findall(title.lower()))


def link_targets(vault: Vault, path: Path) -> set[Path]:
    targets: set[Path] = set()
    metadata = vault.meta(path)
    for field in RELATION_FIELDS:
        for ref in ref_list(metadata.get(field)):
            target = vault.resolver.canonical_ref(ref)
            if target is not None and target != path:
                targets.add(target)
    body = vault.body(path)
    for match in re.finditer(r"\[\[([^\]]+)\]\]|\[[^\]]+\]\(([^)\s]+)\)", body):
        ref = (match.group(1) or match.group(2) or "").strip()
        if not ref or "://" in ref:
            continue
        target = vault.resolver.canonical_ref(ref.split("#", 1)[0])
        if target is None:
            for candidate in vault.resolver.files:
                if vault.title(candidate) == ref:
                    target = candidate
                    break
        if target is not None and target != path:
            targets.add(target)
    return targets


def doctor_findings(vault: Vault, now: dt.datetime, max_bytes: int, threshold: float) -> list[tuple[str, str, str, str, str, str]]:
    files = [path for path in vault.semantic_files() if vault.eligible(path, now, include_cold=True)]
    file_set = set(files)
    outgoing = {path: link_targets(vault, path) for path in files}
    incoming: dict[Path, int] = defaultdict(int)
    for path, targets in outgoing.items():
        for target in targets:
            incoming[target] += 1
    associated: set[str] = set()
    for _, metadata, _ in vault.frontmatter_dir("projections"):
        if metadata.get("type") == "AssociativeProjection" and clean(metadata.get("brain_projection_state")) == "active":
            associated.add(clean(metadata.get("brain_association_a")))
            associated.add(clean(metadata.get("brain_association_b")))
    findings: list[tuple[str, str, str, str, str, str]] = []
    for path in files:
        metadata = vault.meta(path)
        rel = vault.rel(path)
        title = vault.title(path)
        if metadata.get("type") not in ("Topic",) and not outgoing[path] and not incoming[path] and rel not in associated and not clean(metadata.get("brain_topic_id")) and not clean(metadata.get("brain_state_key")):
            findings.append(("memory-doctor", rel, title, "orphan", "no-links-topic-state-key-or-association", "link-or-review"))
        size = utf8_len(vault.body(path))
        if size > max_bytes:
            findings.append(("memory-doctor", rel, title, "oversized", f"body-bytes={size}>{max_bytes}", "split-or-summarise"))
    # Duplicate detection: identical normalised titles, or high shingle overlap.
    related: set[tuple[Path, Path]] = set()
    for path in files:
        for target in outgoing[path]:
            related.add((path, target))
            related.add((target, path))
    by_title: dict[str, list[Path]] = defaultdict(list)
    for path in files:
        key = normalised_title(vault.title(path))
        if key:
            by_title[key].append(path)
    pairs: dict[tuple[Path, Path], str] = {}
    for group in by_title.values():
        group = sorted(group, key=vault.rel)
        for left_index, left in enumerate(group):
            for right in group[left_index + 1 :]:
                if (left, right) not in related:
                    pairs[(left, right)] = "same-title"
    # Ignore the leading H1, which mirrors the title and is compared above.
    shingle_sets = {path: shingles(TOKEN_RE.findall(re.sub(r"\A\s*# [^\n]*\n", "", vault.body(path)).lower())) for path in files}
    posting: dict[str, list[Path]] = defaultdict(list)
    for path in sorted(files, key=vault.rel):
        if len(shingle_sets[path]) >= 8:
            for item in shingle_sets[path]:
                posting[item].append(path)
    candidates: set[tuple[Path, Path]] = set()
    for members in posting.values():
        if len(members) > 50:
            continue
        for left_index, left in enumerate(members):
            for right in members[left_index + 1 :]:
                candidates.add((left, right) if vault.rel(left) < vault.rel(right) else (right, left))
    for left, right in sorted(candidates, key=lambda pair: (vault.rel(pair[0]), vault.rel(pair[1]))):
        if (left, right) in related or (left, right) in pairs:
            continue
        a, b = shingle_sets[left], shingle_sets[right]
        union = len(a | b)
        if union and len(a & b) / union >= threshold:
            pairs[(left, right)] = f"body-overlap={len(a & b) / union:.2f}"
    for (left, right), reason in sorted(pairs.items(), key=lambda item: (vault.rel(item[0][0]), vault.rel(item[0][1]))):
        if left in file_set and right in file_set:
            findings.append(("memory-doctor", vault.rel(left), vault.title(left), "likely-duplicate", f"{reason}~{vault.rel(right)}", "merge-or-supersede"))
    return findings


# ------------------------------------------------------------ code anchors

def git(source_root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(source_root), *arguments],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, timeout=20, check=False,
    )


def anchor_findings(vault: Vault, now: dt.datetime, source_root: str) -> list[tuple[str, str, str, str, str, str]]:
    findings = []
    root = Path(source_root) if source_root else None
    git_ok = False
    if root is not None and root.is_dir():
        try:
            git_ok = git(root, "rev-parse", "--is-inside-work-tree").returncode == 0
        except (OSError, subprocess.SubprocessError):
            git_ok = False
    for path in vault.semantic_files():
        if not vault.eligible(path, now, include_cold=True):
            continue
        anchors = ref_list(vault.meta(path).get("brain_code_anchors"))
        if not anchors:
            continue
        rel = vault.rel(path)
        title = vault.title(path)
        for anchor in anchors:
            match = ANCHOR_RE.fullmatch(anchor.strip())
            if not match:
                findings.append(("code-anchor", rel, title, "invalid-anchor", f"anchor={anchor}", "fix-anchor"))
                continue
            anchored_path, commit = match.group("path"), match.group("commit")
            safe, error = okf.LifecycleResolver._safe_ref(anchored_path)
            if error:
                findings.append(("code-anchor", rel, title, "invalid-anchor", f"anchor={anchor}", "fix-anchor"))
                continue
            if not git_ok:
                findings.append(("code-anchor", rel, title, "unverifiable", f"no-git-source-root~{anchor}", "check-source-root"))
                continue
            try:
                if git(root, "cat-file", "-e", f"{commit}^{{commit}}").returncode != 0:
                    findings.append(("code-anchor", rel, title, "unknown-commit", f"anchor={anchor}", "reverify"))
                    continue
                exists = git(root, "cat-file", "-e", f"HEAD:{safe}").returncode == 0
                if not exists:
                    findings.append(("code-drift", rel, title, "reverify", f"anchored-path-missing~{anchor}", "reverify"))
                    continue
                changed = git(root, "diff", "--quiet", commit, "HEAD", "--", safe).returncode
            except (OSError, subprocess.SubprocessError):
                findings.append(("code-anchor", rel, title, "unverifiable", f"git-unavailable~{anchor}", "check-source-root"))
                continue
            if changed == 1:
                findings.append(("code-drift", rel, title, "reverify", f"anchored-file-changed~{anchor}", "reverify"))
            elif changed != 0:
                findings.append(("code-anchor", rel, title, "unverifiable", f"git-diff-failed~{anchor}", "check-source-root"))
    return findings


# ------------------------------------------------- FSRS-style stability

def fsrs_retrievability(elapsed_days: float, stability: float) -> float:
    return (1.0 + FSRS_FACTOR * max(elapsed_days, 0.0) / max(stability, 0.01)) ** FSRS_DECAY


def fsrs_interval(stability: float) -> float:
    days = stability / FSRS_FACTOR * (FSRS_RETENTION ** (1.0 / FSRS_DECAY) - 1.0)
    return min(max(days, FSRS_MIN_DAYS), FSRS_MAX_DAYS)


def fsrs_success(stability: float, retrievability: float, hard: bool = False) -> float:
    w = FSRS_W
    growth = math.exp(w[8]) * (11.0 - FSRS_DIFFICULTY) * stability ** (-w[9]) * (math.exp(w[10] * (1.0 - retrievability)) - 1.0)
    if hard:
        growth *= w[15]
    return min(stability * (1.0 + growth), FSRS_MAX_DAYS * 4)


def fsrs_lapse(stability: float, retrievability: float) -> float:
    w = FSRS_W
    value = w[11] * FSRS_DIFFICULTY ** (-w[12]) * ((stability + 1.0) ** w[13] - 1.0) * math.exp(w[14] * (1.0 - retrievability))
    return max(min(value, stability), 0.1)


def verification_times(metadata: dict[str, Any]) -> list[dt.datetime]:
    times: list[dt.datetime] = []
    verified = metadata.get("verified")
    events = verified if isinstance(verified, list) else ([verified] if isinstance(verified, dict) else [])
    for event in events:
        if isinstance(event, dict):
            parsed = parse_time(event.get("at"))
            if parsed:
                times.append(parsed)
    for field in ("brain_last_verified_at", "last_validated_at"):
        parsed = parse_time(metadata.get(field))
        if parsed:
            times.append(parsed)
    return times


def contradiction_times(vault: Vault) -> dict[str, list[dt.datetime]]:
    result: dict[str, list[dt.datetime]] = defaultdict(list)
    for _, metadata, _ in vault.frontmatter_dir("review"):
        kind = clean(metadata.get("brain_review_kind"))
        if kind not in ("reconsolidation", "conflict"):
            continue
        if clean(metadata.get("brain_review_state")) == "rejected":
            continue
        when = parse_time(metadata.get("brain_created_at")) or parse_time(metadata.get("timestamp"))
        if when is None:
            continue
        for field in ("brain_recalled_ref", "brain_version_of", "brain_conflicts"):
            for ref in ref_list(metadata.get(field)):
                target = vault.resolver.canonical_ref(ref)
                if target is not None:
                    rel = vault.rel(target)
                    if when not in result[rel]:
                        result[rel].append(when)
    return result


def stability_rows(vault: Vault, now: dt.datetime) -> list[dict[str, Any]]:
    contradictions = contradiction_times(vault)
    useful_times: dict[str, list[tuple[dt.datetime, bool]]] = defaultdict(list)
    for _, usefulness, refs, when in feedback_rows(vault):
        if when is None or usefulness not in ("useful", "partial"):
            continue
        for ref in refs:
            useful_times[ref].append((when, usefulness == "partial"))
    rows = []
    for path in vault.semantic_files():
        if not vault.eligible(path, now, include_cold=True):
            continue
        metadata = vault.meta(path)
        rel = vault.rel(path)
        start = record_created(metadata)
        events: list[tuple[dt.datetime, str]] = []
        events.extend((when, "verified") for when in verification_times(metadata))
        events.extend((when, "useful-hard" if hard else "useful") for when, hard in useful_times.get(rel, []))
        events.extend((when, "contradicted") for when in contradictions.get(rel, []))
        events = sorted({(when, kind) for when, kind in events if when <= now})
        if start is None and events:
            start = events[0][0]
        if start is None:
            continue
        stability = FSRS_W[2]
        last = start
        counts = {"verified": 0, "useful": 0, "contradicted": 0}
        for when, kind in events:
            if when < start:
                continue
            elapsed = (when - last).total_seconds() / 86400.0
            retrievability = fsrs_retrievability(elapsed, stability)
            if kind == "contradicted":
                stability = fsrs_lapse(stability, retrievability)
                counts["contradicted"] += 1
            else:
                stability = fsrs_success(stability, retrievability, hard=(kind == "useful-hard"))
                counts["verified" if kind == "verified" else "useful"] += 1
            last = when
        interval = fsrs_interval(stability)
        next_review = last + dt.timedelta(days=interval)
        elapsed_now = (now - last).total_seconds() / 86400.0
        stale_after = clean(metadata.get("stale_after"))
        suggested = next_review.date().isoformat()
        last_kind = events[-1][1] if events else "created"
        rows.append({
            "ref": rel, "title": vault.title(path), "stability_days": round(stability, 3),
            "retrievability": round(fsrs_retrievability(elapsed_now, stability), 4),
            "last_review": iso(last), "next_review": iso(next_review), "stale_after": stale_after or None,
            "suggested_stale_after": suggested, "last_event": last_kind,
            "verified_events": counts["verified"], "useful_events": counts["useful"],
            "contradictions": counts["contradicted"],
            "state": "due" if next_review <= now else "scheduled",
        })
    return rows


def stability_findings(vault: Vault, now: dt.datetime) -> list[tuple[str, str, str, str, str, str]]:
    findings = []
    today = now.date().isoformat()
    for row in stability_rows(vault, now):
        has_evidence = row["verified_events"] + row["useful_events"] + row["contradictions"] > 0
        if not has_evidence:
            continue
        stale_after = row["stale_after"] or ""
        if row["last_event"] == "contradicted" and (not stale_after or row["suggested_stale_after"] < stale_after):
            findings.append(("spaced-review", row["ref"], row["title"], "review-sooner", f"contradicted~next-review={row['suggested_stale_after']}", "reverify"))
        elif row["state"] == "due" and (not stale_after or stale_after > today):
            findings.append(("spaced-review", row["ref"], row["title"], "due", f"next-review={row['suggested_stale_after']}~stability={row['stability_days']}d", "reverify"))
    return findings


def command_stability(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    now = now_from(args.now)
    rows = stability_rows(vault, now)
    if args.ref:
        rows = [row for row in rows if row["ref"] == args.ref or Path(row["ref"]).stem == args.ref]
    if args.json:
        print(json.dumps({"status": "ok", "derived": True, "model": "fsrs-4.5-default-weights", "desired_retention": FSRS_RETENTION, "now": iso(now), "records": rows}, ensure_ascii=False, separators=(",", ":")))
        return 0
    print("ref\tstability_days\tretrievability\tlast_review\tnext_review\tstale_after\tsuggested_stale_after\tstate\tevents\ttitle")
    for row in rows:
        events = f"verified={row['verified_events']},useful={row['useful_events']},contradicted={row['contradictions']}"
        print(f"{row['ref']}\t{row['stability_days']}\t{row['retrievability']}\t{row['last_review']}\t{row['next_review']}\t{row['stale_after'] or 'none'}\t{row['suggested_stale_after']}\t{row['state']}\t{events}\t{clean(row['title'])}")
    return 0


# ---------------------------------------------------------- co-use links

def coaccess_pairs(vault: Vault, now: dt.datetime, min_count: int) -> list[tuple[str, str, int, list[str]]]:
    counts: dict[tuple[str, str], list[str]] = defaultdict(list)
    for name, usefulness, refs, _ in feedback_rows(vault):
        if usefulness != "useful":
            continue
        unique = sorted(set(refs))
        for left_index, left in enumerate(unique):
            for right in unique[left_index + 1 :]:
                counts[(left, right)].append(name)
    existing: set[tuple[str, str]] = set()
    for _, metadata, _ in vault.frontmatter_dir("projections"):
        if metadata.get("type") == "AssociativeProjection" and clean(metadata.get("brain_projection_state")) == "active":
            pair = tuple(sorted((clean(metadata.get("brain_association_a")), clean(metadata.get("brain_association_b")))))
            existing.add(pair)  # type: ignore[arg-type]
    rows = []
    for (left, right), feedback in sorted(counts.items()):
        if len(feedback) < min_count or (left, right) in existing:
            continue
        left_path = vault.resolver.canonical_ref(left)
        right_path = vault.resolver.canonical_ref(right)
        if left_path is None or right_path is None:
            continue
        if not vault.eligible(left_path, now, include_cold=True) or not vault.eligible(right_path, now, include_cold=True):
            continue
        rows.append((left, right, len(feedback), sorted(feedback)))
    rows.sort(key=lambda row: (-row[2], row[0], row[1]))
    return rows


def command_coaccess(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    now = now_from(args.now)
    print("ref_a\tref_b\tuseful_packs\tfeedback")
    for left, right, count, feedback in coaccess_pairs(vault, now, max(args.min_count, 1)):
        print(f"{left}\t{right}\t{count}\t{','.join(feedback)}")
    return 0


# ------------------------------------------------------ review triage

RISK_ORDER = {"high": 0, "medium": 1, "low": 2}


def command_triage(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, "")
    now = now_from(args.now)
    current = [path for path in vault.semantic_files() if vault.eligible(path, now, include_cold=True)]
    by_state_key: dict[str, list[Path]] = defaultdict(list)
    by_topic: dict[str, list[Path]] = defaultdict(list)
    by_title: dict[str, list[Path]] = defaultdict(list)
    for path in current:
        metadata = vault.meta(path)
        key = clean(metadata.get("brain_state_key"))
        if key:
            by_state_key[key].append(path)
        topic = clean(metadata.get("brain_topic_id"))
        if topic:
            by_topic[topic].append(path)
        by_title[normalised_title(vault.title(path))].append(path)
    rows = []
    for path, metadata, body in vault.frontmatter_dir("review"):
        state = clean(metadata.get("brain_review_state"))
        if state not in ("proposed", "needs-validation"):
            continue
        review_id = clean(metadata.get("brain_candidate_id")) or path.stem
        kind = clean(metadata.get("brain_review_kind")) or "candidate"
        title = clean(metadata.get("title")) or review_id
        risk = clean(metadata.get("brain_risk")) or "medium"
        bucket, reason = "novel", "no-matching-concept"
        replaces = set()
        for field in ("brain_supersedes", "brain_version_of"):
            for ref in ref_list(metadata.get(field)):
                target = vault.resolver.canonical_ref(ref)
                if target is not None:
                    replaces.add(target)
        key = clean(metadata.get("brain_state_key"))
        topic = clean(metadata.get("brain_topic_id"))
        if kind in ("conflict", "reconsolidation", "redaction"):
            bucket, reason = "conflict", f"review-kind={kind}"
        elif ref_list(metadata.get("brain_conflicts")):
            bucket, reason = "conflict", "declares-conflicts"
        elif re.search(r"(?im)^\s*(contradicts|reconsolidates)\s*:", body):
            bucket, reason = "conflict", "contradiction-marker"
        elif key and by_state_key.get(key):
            holders = by_state_key[key]
            if all(holder in replaces for holder in holders):
                bucket, reason = "fit", f"orderly-update-of-state-key={key}"
            else:
                bucket, reason = "conflict", f"clashes-with-current-state-key={key}"
        elif topic and by_topic.get(topic):
            bucket, reason = "fit", f"extends-topic={topic}"
        elif normalised_title(title) and by_title.get(normalised_title(title)):
            bucket, reason = "fit", "matches-existing-title"
        elif replaces:
            bucket, reason = "fit", "declares-replacement"
        when = parse_time(metadata.get("timestamp")) or parse_time(metadata.get("brain_created_at"))
        rows.append((bucket, risk, iso(when), review_id, state, kind, reason, clean(metadata.get("brain_confidence")) or "0.0", title))
    order = {"conflict": 0, "novel": 1, "fit": 2}
    rows.sort(key=lambda row: (order[row[0]], RISK_ORDER.get(row[1], 1), row[2], row[3]))
    print("id\tstate\tkind\ttriage\tbatch\treason\tconfidence\ttitle")
    for bucket, risk, _, review_id, state, kind, reason, confidence, title in rows:
        batch = {"conflict": "review-first", "novel": "standard", "fit": "low-risk-batch"}[bucket]
        if bucket == "fit" and risk == "high":
            batch = "standard"
        print(f"{review_id}\t{state}\t{kind}\t{bucket}\t{batch}\t{reason}\t{confidence}\t{clean(title)}")
    return 0


# ------------------------------------------------------------ intentions

def state_fingerprint(vault: Vault, key: str, now: dt.datetime) -> str:
    holders = []
    for path in vault.semantic_files():
        if clean(vault.meta(path).get("brain_state_key")) != key:
            continue
        if not vault.eligible(path, now, include_cold=True):
            continue
        holders.append(f"{vault.rel(path)}:{hashlib.sha256(path.read_bytes()).hexdigest()}")
    if not holders:
        return "none"
    return hashlib.sha256("\n".join(sorted(holders)).encode()).hexdigest()[:24]


def intention_due(vault: Vault, metadata: dict[str, Any], now: dt.datetime, task: str, hints: list[str]) -> str:
    kind = clean(metadata.get("brain_trigger_kind"))
    value = clean(metadata.get("brain_trigger_value"))
    if kind == "date":
        when = parse_time(value)
        return f"date-reached~{value}" if when is not None and when <= now else ""
    if kind == "path":
        matched = path_matches(ref_list(value) or [value], hints)
        return f"path-named~{matched}" if matched else ""
    if kind == "keyword":
        words = [item.strip().lower() for item in value.split(",") if item.strip()]
        lowered = task.lower()
        for word in words:
            if re.search(r"(?<![a-z0-9])" + re.escape(word) + r"(?![a-z0-9])", lowered):
                return f"keyword-named~{word}"
        task_stems = {keyword_stem(token) for token in re.findall(r"[a-z0-9]+", lowered)}
        for word in words:
            if re.fullmatch(r"[a-z0-9]+", word) and len(keyword_stem(word)) >= 5 and keyword_stem(word) in task_stems:
                return f"keyword-stem~{word}"
        return ""
    if kind == "state":
        baseline = clean(metadata.get("brain_trigger_baseline"))
        current = state_fingerprint(vault, value, now)
        return f"state-changed~{value}" if baseline and current != baseline else ""
    return ""


def command_intentions(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    now = now_from(args.now)
    hints = hints_from(args.task or "", args.hint_path or [])
    rows = []
    for path, metadata, body in vault.frontmatter_dir("intentions"):
        if metadata.get("type") != "Intention":
            continue
        status = clean(metadata.get("brain_intention_status")) or "open"
        if args.status != "all" and status != args.status:
            continue
        scope = ref_list(metadata.get("brain_principal"))
        if scope and (not args.principal or args.principal not in scope):
            continue
        due = intention_due(vault, metadata, now, args.task or "", hints) if status == "open" else ""
        if args.due_only and not due:
            continue
        rows.append({
            "id": clean(metadata.get("brain_intention_id")) or path.stem,
            "status": status, "due": bool(due), "reason": due or "-",
            "trigger_kind": clean(metadata.get("brain_trigger_kind")),
            "trigger_value": clean(metadata.get("brain_trigger_value")),
            "action": clean(metadata.get("brain_intention_action")) or clean(metadata.get("title")),
            "created_at": clean(metadata.get("brain_created_at")),
            "path": f"intentions/{path.name}",
        })
    rows.sort(key=lambda row: (not row["due"], row["created_at"], row["id"]))
    if args.json:
        print(json.dumps({"status": "ok", "now": iso(now), "intentions": rows}, ensure_ascii=False, separators=(",", ":")))
        return 0
    print("id\tstatus\tdue\treason\ttrigger\taction\tpath")
    for row in rows:
        print(f"{row['id']}\t{row['status']}\t{'true' if row['due'] else 'false'}\t{row['reason']}\t{row['trigger_kind']}:{clean(row['trigger_value'])}\t{clean(row['action'])}\t{row['path']}")
    return 0


def command_state_fingerprint(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, "")
    print(state_fingerprint(vault, args.key, now_from(args.now)))
    return 0


# ------------------------------------------------------ lifecycle notices

def _one_line(text: str) -> str:
    return re.sub(r"\s+", " ", text or "").strip()


def lifecycle_notices(vault: Vault, now: dt.datetime, task: str = "", limit: int = 6) -> list[dict[str, Any]]:
    """Active corrections (records that supersede another) and retractions.

    These are newer than the documents they correct, so they are surfaced on
    their own instead of competing lexically with the task: a correction that
    does not share words with the task is exactly the one an agent misses.
    Hidden or unresolvable targets are skipped rather than disclosed.
    """
    resolver = vault.resolver
    notices: list[dict[str, Any]] = []
    for path in vault.semantic_files():
        if not vault.eligible(path, now):
            continue
        metadata = vault.meta(path)
        targets = []
        for ref in ref_list(metadata.get("brain_supersedes")):
            target = resolver.canonical_ref(ref)
            if target is None or target == path or not resolver.visible(target, strict_principal=True):
                continue
            targets.append(target)
        if not targets:
            continue
        when = parse_time(metadata.get("brain_observed_at")) or record_created(metadata)
        replaced = []
        for target in targets:
            target_meta = vault.meta(target)
            observed = parse_time(target_meta.get("brain_observed_at")) or record_created(target_meta)
            replaced.append(vault.title(target) + (f" ({observed.date().isoformat()})" if observed else ""))
        notices.append({
            "kind": "correction", "date": iso(when) if when else "", "ref": vault.rel(path),
            "title": vault.title(path), "text": _one_line(lead_sentences(vault.body(path), 280)),
            "replaces": "; ".join(replaced),
        })
    retraction_dir = vault.root / "okf" / "retractions"
    if retraction_dir.is_dir():
        for path in sorted(retraction_dir.glob("*.md")):
            if path.is_symlink() or not path.is_file():
                continue
            try:
                metadata, body = okf.split_frontmatter(path)
            except okf.OkfError:
                continue
            ref = clean(metadata.get("brain_retracts"))
            target = resolver.canonical_ref(ref) if ref else None
            if target is None or not resolver.visible(target, strict_principal=True):
                continue
            generated = metadata.get("generated")
            when = parse_time(generated.get("at")) if isinstance(generated, dict) else None
            if when is not None and when > now:
                continue
            notices.append({
                "kind": "retraction", "date": iso(when) if when else "", "ref": vault.rel(target),
                "title": vault.title(target), "text": _one_line(lead_sentences(body, 280)), "replaces": "",
            })
    terms = {keyword_stem(term) for term in re.findall(r"[a-z0-9]+", (task or "").lower()) if len(term) > 2}

    def overlap(item: dict[str, Any]) -> int:
        words = {keyword_stem(term) for term in re.findall(r"[a-z0-9]+", " ".join((item["title"], item["text"], item["replaces"])).lower())}
        return len(terms & words)

    # Most task-relevant first, then newest first; ties by ref for stability.
    notices.sort(key=lambda item: item["ref"])
    notices.sort(key=lambda item: item["date"], reverse=True)
    notices.sort(key=overlap, reverse=True)
    return notices[: max(limit, 0)]


def notice_line(item: dict[str, Any]) -> str:
    date = f" ({item['date'][:10]})" if item.get("date") else ""
    if item["kind"] == "correction":
        line = f"Correction{date} — {item['title']}: {item['text']}"
        if item["replaces"]:
            line += f" Replaces: {item['replaces']}."
        return line + f" [{item['ref']}]"
    return f"Retraction{date} — {item['title']} is retracted: {item['text']} [{item['ref']}]"


def command_notices(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    now = now_from(args.now)
    items = lifecycle_notices(vault, now, args.task or "", args.limit)
    if args.json:
        print(json.dumps({"status": "ok", "now": iso(now), "notices": items}, ensure_ascii=False, separators=(",", ":")))
        return 0
    for item in items:
        print(_one_line(notice_line(item)))
    return 0


# ----------------------------------------------------------- project brief

TRUST_ORDER = {"human-reviewed": 0, "machine-confirmed": 1, "unverified": 2}


def brief_payload(vault: Vault, now: dt.datetime, max_bytes: int, recent_days: int) -> dict[str, Any]:
    durable = []
    recent = []
    stale = 0
    for path in vault.semantic_files():
        if not vault.eligible(path, now):
            continue
        metadata = vault.meta(path)
        freshness = okf.freshness(metadata, now.date())
        if freshness in ("stale", "invalid"):
            stale += 1
            continue
        rel = vault.rel(path)
        entry = {
            "ref": rel, "title": vault.title(path), "summary": lead_sentences(vault.body(path), 180),
            "trust": okf.trust_tier(metadata), "state_key": clean(metadata.get("brain_state_key")),
            "type": clean(metadata.get("type")),
        }
        durable.append(entry)
        changed = max(
            [value for value in (record_created(metadata), *verification_times(metadata)) if value is not None],
            default=None,
        )
        if changed is not None and changed <= now and (now - changed).days < recent_days:
            recent.append(dict(entry, changed_at=iso(changed)))
    retractions = []
    retraction_dir = vault.root / "okf" / "retractions"
    if retraction_dir.is_dir():
        for path in sorted(retraction_dir.glob("*.md")):
            try:
                metadata, retraction_body = okf.split_frontmatter(path)
            except okf.OkfError:
                continue
            generated = metadata.get("generated")
            when = parse_time(generated.get("at")) if isinstance(generated, dict) else None
            if when is not None and when <= now and (now - when).days < recent_days:
                ref = clean(metadata.get("brain_retracts"))
                target = vault.resolver.canonical_ref(ref) if ref else None
                visible = target is not None and vault.resolver.visible(target, strict_principal=True)
                retractions.append({
                    "ref": ref, "changed_at": iso(when),
                    "title": vault.title(target) if visible else "",
                    "reason": _one_line(lead_sentences(retraction_body, 160)) if visible else "",
                })
    durable.sort(key=lambda item: (TRUST_ORDER.get(item["trust"], 3), 0 if item["state_key"] else 1, item["title"].lower(), item["ref"]))
    recent.sort(key=lambda item: (item["changed_at"], item["ref"]), reverse=True)
    retractions.sort(key=lambda item: (item["changed_at"], item["ref"]), reverse=True)
    due = []
    for _, metadata, _ in vault.frontmatter_dir("intentions"):
        if metadata.get("type") != "Intention" or (clean(metadata.get("brain_intention_status")) or "open") != "open":
            continue
        if ref_list(metadata.get("brain_principal")) and vault.principal not in ref_list(metadata.get("brain_principal")):
            continue
        if clean(metadata.get("brain_trigger_kind")) == "date" and intention_due(vault, metadata, now, "", []):
            due.append(clean(metadata.get("brain_intention_action")) or clean(metadata.get("title")))
    notices = lifecycle_notices(vault, now, "", 6)
    noticed = {item["ref"] for item in notices if item["kind"] == "correction"}
    durable = [item for item in durable if item["ref"] not in noticed]
    return {"durable": durable, "recent": recent, "retractions": retractions, "stale_omitted": stale, "due_intentions": sorted(due), "notices": notices}


def render_brief(project_id: str, payload: dict[str, Any], max_bytes: int, recent_days: int, now: dt.datetime) -> tuple[str, int]:
    header = [
        f"LLM-BRAIN PROJECT BRIEF ({project_id}, derived {now.date().isoformat()}, cap {max_bytes} bytes)",
        "Approved memory only; current source, user direction and live proof outrank it, except where memory records a later correction or retraction of that same source. Search or build a pack before relying on details.",
    ]
    lines = list(header)
    budget = max_bytes
    used = utf8_len("\n".join(lines)) + 1
    omitted = 0

    def add(line: str) -> bool:
        nonlocal used
        size = utf8_len(line) + 1
        if used + size > budget:
            return False
        lines.append(line)
        used += size
        return True

    sections: list[tuple[str, list[str]]] = []
    if payload["due_intentions"]:
        sections.append(("Due intentions:", [f"- {item}" for item in payload["due_intentions"]]))
    if payload.get("notices"):
        sections.append(("Corrections and retractions (newer than the documents they correct; a local copy of a corrected or retracted document is the outdated version):",
                         [f"- {notice_line(item)}" for item in payload["notices"]]))
    sections.append(("Durable facts:", [
        f"- {item['title']}: {item['summary']} [{item['trust']}; {item['ref']}]" if item["summary"] else f"- {item['title']} [{item['trust']}; {item['ref']}]"
        for item in payload["durable"]
    ] or ["- none approved yet"]))
    changes = [f"- {item['changed_at'][:10]} {item['title']} ({item['ref']})" for item in payload["recent"]]
    changes += [
        f"- {item['changed_at'][:10]} retracted {item['title'] + ' (' + item['ref'] + ')' if item.get('title') else item['ref']}"
        + (f": {item['reason']}" if item.get("reason") else "")
        for item in payload["retractions"]
    ]
    sections.append((f"Recent changes (last {recent_days} days):", changes or ["- none"]))
    # Reserve roughly 40% of the cap for recent changes so a large durable
    # set cannot crowd them out entirely.
    durable_cap = used + int((budget - used) * 0.6)
    for heading, items in sections:
        if not add(heading):
            omitted += len(items)
            continue
        for index, item in enumerate(items):
            limit_reached = heading == "Durable facts:" and used + utf8_len(item) + 1 > durable_cap
            if limit_reached or not add(item):
                omitted += len(items) - index
                break
    if payload["stale_omitted"]:
        add(f"({payload['stale_omitted']} stale record(s) omitted pending re-verification.)")
    if omitted:
        add(f"({omitted} more item(s) omitted by the size cap.)")
    text = "\n".join(lines) + "\n"
    while utf8_len(text) > max_bytes and len(lines) > 1:
        lines.pop()
        text = "\n".join(lines) + "\n"
    return text, omitted


def command_brief(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    now = now_from(args.now)
    max_bytes = max(args.max_bytes, 256)
    payload = brief_payload(vault, now, max_bytes, args.recent_days)
    text, omitted = render_brief(args.project_id, payload, max_bytes, args.recent_days, now)
    if args.json:
        print(json.dumps({
            "status": "ok", "derived": True, "project_id": args.project_id, "max_bytes": max_bytes,
            "bytes": utf8_len(text), "omitted": omitted, "durable_count": len(payload["durable"]),
            "recent_count": len(payload["recent"]) + len(payload["retractions"]),
            "stale_omitted": payload["stale_omitted"], "brief": text,
        }, ensure_ascii=False, separators=(",", ":")))
    else:
        sys.stdout.write(text)
    return 0


# ------------------------------------------------- usage-aware re-ranking

def command_rerank(args: argparse.Namespace) -> int:
    """Apply opt-in usage boosting plus the diversity guard to a ranked list.

    Input rows are the CLI's ``final_ranked`` TSV (path, score, ...).  The
    guard reserves ``--reserve`` of the first ``--limit`` slots for relevant
    records with no recorded use so popular records cannot starve them
    (retrieval-induced forgetting).  Output keeps the input columns and appends
    a ``usage`` column: boosted, reserved or plain.
    """

    vault = Vault(args.project_dir, args.principal)
    table, _ = usage_table(vault)
    rows = []
    for line in Path(args.ranked).read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        fields = line.split("\t")
        try:
            score = float(fields[1])
        except (IndexError, ValueError):
            score = 0.0
        entry = table.get(fields[0])
        uses = entry["uses"] + entry["rendered"] if entry else 0
        useful = entry["useful"] + 0.5 * entry["partial"] if entry else 0
        not_useful = entry["not_useful"] if entry else 0
        multiplier = 1.0 + 0.1 * math.log1p(uses) + 0.25 * math.log1p(useful) - 0.15 * math.log1p(not_useful)
        multiplier = max(multiplier, 0.5)
        rows.append({"fields": fields, "score": score * multiplier, "rare": (uses + useful + not_useful) == 0, "boosted": multiplier != 1.0})
    rows.sort(key=lambda row: (-row["score"], row["fields"][0]))
    limit = max(args.limit, 1)
    reserve = min(max(args.reserve, 0), limit)
    head, tail = rows[:limit], rows[limit:]
    reserved_paths: set[str] = set()
    rare_in_head = sum(1 for row in head if row["rare"])
    if reserve and rare_in_head < reserve:
        promotable = [row for row in tail if row["rare"] and row["score"] > 0]
        needed = reserve - rare_in_head
        for row in promotable[:needed]:
            # Replace the lowest-ranked popular row in the visible window.
            for index in range(len(head) - 1, -1, -1):
                if not head[index]["rare"] and head[index]["fields"][0] not in reserved_paths:
                    displaced = head.pop(index)
                    tail.insert(0, displaced)
                    break
            else:
                break
            head.append(row)
            tail.remove(row)
            reserved_paths.add(row["fields"][0])
    for row in head + tail:
        fields = list(row["fields"])
        if len(fields) > 1:
            fields[1] = f"{row['score']:.6f}"
        marker = "reserved" if fields[0] in reserved_paths else ("boosted" if row["boosted"] else "plain")
        print("\t".join(fields + [marker]))
    return 0


# ---------------------------------------------- maintenance aggregation

def command_maintenance(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    now = now_from(args.now)
    rows: list[tuple[str, str, str, str, str, str]] = []
    rows.extend(retention_signals(vault, now, args.grace_days, args.idle_days))
    rows.extend(doctor_findings(vault, now, args.max_bytes, args.duplicate_threshold))
    rows.extend(anchor_findings(vault, now, args.source_root))
    rows.extend(stability_findings(vault, now))
    for row in sorted(set(rows)):
        print("\t".join(clean(value).replace("|", "-") for value in row))
    return 0


def command_doctor(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    now = now_from(args.now)
    print("category\tref\ttitle\tstate\treason\trecommendation")
    emit_tsv(sorted(set(doctor_findings(vault, now, args.max_bytes, args.duplicate_threshold))))
    return 0


def command_anchors(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    now = now_from(args.now)
    print("category\tref\ttitle\tstate\treason\trecommendation")
    emit_tsv(sorted(set(anchor_findings(vault, now, args.source_root))))
    return 0


def command_validate_anchor(args: argparse.Namespace) -> int:
    match = ANCHOR_RE.fullmatch(args.anchor.strip())
    if not match:
        return 65
    _, error = okf.LifecycleResolver._safe_ref(match.group("path"))
    return 65 if error else 0


# ------------------------------------------------------------------ parser

def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)

    def base(name: str, func: Any) -> argparse.ArgumentParser:
        command = commands.add_parser(name)
        command.add_argument("--project-dir", required=True)
        command.add_argument("--principal", default="")
        command.add_argument("--now", default="")
        command.set_defaults(func=func)
        return command

    bm25 = commands.add_parser("bm25")
    bm25.add_argument("--project-dir", required=True)
    bm25.add_argument("--paths-file", required=True)
    bm25.add_argument("--query", required=True)
    bm25.add_argument("--hint-path", action="append")
    bm25.set_defaults(func=command_bm25)

    usage = base("usage", command_usage)
    usage.add_argument("--json", action="store_true")

    stability = base("stability", command_stability)
    stability.add_argument("--ref", default="")
    stability.add_argument("--json", action="store_true")

    coaccess = base("coaccess", command_coaccess)
    coaccess.add_argument("--min-count", type=int, default=2)

    base("triage", command_triage)

    intentions = base("intentions", command_intentions)
    intentions.add_argument("--task", default="")
    intentions.add_argument("--hint-path", action="append")
    intentions.add_argument("--status", default="open", choices=("open", "done", "cancelled", "all"))
    intentions.add_argument("--due-only", action="store_true")
    intentions.add_argument("--json", action="store_true")

    fingerprint = base("state-fingerprint", command_state_fingerprint)
    fingerprint.add_argument("--key", required=True)

    brief = base("brief", command_brief)
    brief.add_argument("--project-id", required=True)
    brief.add_argument("--max-bytes", type=int, default=4000)
    brief.add_argument("--recent-days", type=int, default=14)
    brief.add_argument("--json", action="store_true")

    notices = base("notices", command_notices)
    notices.add_argument("--task", default="")
    notices.add_argument("--limit", type=int, default=6)
    notices.add_argument("--json", action="store_true")

    rerank = base("rerank", command_rerank)
    rerank.add_argument("--ranked", required=True)
    rerank.add_argument("--limit", type=int, default=20)
    rerank.add_argument("--reserve", type=int, default=2)

    maintenance = base("maintenance", command_maintenance)
    maintenance.add_argument("--source-root", default="")
    maintenance.add_argument("--grace-days", type=int, default=30)
    maintenance.add_argument("--idle-days", type=int, default=180)
    maintenance.add_argument("--max-bytes", type=int, default=16384)
    maintenance.add_argument("--duplicate-threshold", type=float, default=0.85)

    doctor = base("doctor", command_doctor)
    doctor.add_argument("--max-bytes", type=int, default=16384)
    doctor.add_argument("--duplicate-threshold", type=float, default=0.85)

    anchors = base("anchors", command_anchors)
    anchors.add_argument("--source-root", default="")

    validate_anchor = commands.add_parser("validate-anchor")
    validate_anchor.add_argument("anchor")
    validate_anchor.set_defaults(func=command_validate_anchor)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        return int(args.func(args))
    except okf.OkfError as exc:
        print(f"memory-signals:error {exc}", file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())
