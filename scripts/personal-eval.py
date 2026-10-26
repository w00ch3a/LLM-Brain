#!/usr/bin/env python3
"""Personal eval kit: does this brain surface the memory *you* need?

Works only on a private copy of a brain.  The source brain is opened
read-only (copied, never written); a read-only snapshot is mined and a
second, disposable working copy is used for index and pack builds.  Both
copies are deleted at the end.

Mining (deterministic, no model):

* corrections: approved canonical records that supersede another record
  (``brain_supersedes``) or whose text reads as a correction;
* decisions: approved canonical records whose text records a decision;
* sessions: episodes that read as a correction or decision.  Each is matched
  to the canonical record(s) that cite its episode id; a session with no
  canonical record is counted as ``unpromoted`` (a memory gap), not scored.

For each mined target a later follow-up query is written from the record's
distinctive terms (or taken from ``--queries FILE``: ``target_hash<TAB>query``),
off-topic filler records that share query words are added to the working
copy, and ``pack build`` is run.  A case hits when the target record is in
the pack; the rank and the number of filler records ranked above it are
scored.

Output is hashes and scores only: ``results.tsv`` and ``summary.json``.
No record text, title, id, query or path from the brain is written or
printed; targets are ``sha256(project_id/rel)[:16]``.  Restricted, secret
and principal-scoped records are never targets.

Usage:
  personal-eval.py --brain ROOT --project PROJECT_ID --output DIR
                   [--filler N] [--limit N] [--seed N] [--queries FILE]
                   [--cli PATH] [--budget-tokens N]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

sys.dont_write_bytecode = True

FORMAT = "memthena.personal-eval"
FORMAT_VERSION = 1
CANONICAL_DIRS = ("claims", "procedures", "references", "topics")
COPY_SKIP = {".locks", "indexes", "context-packs", "cache", ".cache", "__pycache__"}
CORRECTION = re.compile(r"\b(correction|corrected|correcting|actually|instead|no longer|supersed\w*|deprecated|was wrong|not .{1,40} but)\b", re.I)
DECISION = re.compile(r"\b(decision|decided|decide|we chose|chose to|going with|agreed|settled on)\b", re.I)
CUE_WORDS = {"correction", "corrected", "correcting", "actually", "instead", "longer", "superseded", "supersedes",
             "deprecated", "wrong", "decision", "decided", "decide", "chose", "going", "agreed", "settled"}
STOP = {
    "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "for", "with", "is", "are", "was", "were", "be",
    "been", "it", "its", "this", "that", "these", "those", "as", "at", "by", "from", "we", "our", "you", "your",
    "they", "their", "he", "she", "i", "not", "no", "yes", "do", "does", "did", "so", "if", "then", "than", "into",
    "about", "after", "before", "will", "would", "should", "can", "could", "may", "might", "must", "has", "have",
    "had", "all", "any", "each", "every", "more", "most", "other", "some", "such", "only", "own", "same", "too",
    "very", "just", "also", "use", "used", "using", "now", "new", "old", "now", "when", "what", "which", "who",
}
SKIP_SENSITIVITY = {"restricted", "secret", "confidential"}
FILLER_WORDS = (
    "lantern orchard pebble violet harbor quartz meadow cobalt saffron tundra ember willow canyon "
    "falcon marble cedar thistle prism glacier juniper basalt amber lagoon sparrow"
).split()
TOKEN = re.compile(r"[a-z0-9][a-z0-9_-]{2,}")


class Refused(Exception):
    pass


def hid(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def split_frontmatter(text: str) -> tuple[dict[str, str], str]:
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---", 4)
    if end < 0:
        return {}, text
    meta: dict[str, str] = {}
    for line in text[4:end].splitlines():
        if ":" in line and not line.startswith((" ", "\t", "-")):
            key, value = line.split(":", 1)
            meta[key.strip()] = value.strip().strip('"').strip("'")
    body = text[end + 4:]
    return meta, body.split("\n", 1)[1] if "\n" in body else ""


def tokens(text: str) -> list[str]:
    return [t for t in TOKEN.findall(text.lower()) if t not in STOP and not t.isdigit()]


def tree_fingerprint(root: Path) -> str:
    """Cheap change detector for the source: paths, sizes and mtimes."""
    digest = hashlib.sha256()
    for directory, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if d != ".locks")
        for name in sorted(filenames):
            path = Path(directory) / name
            try:
                st = path.lstat()
            except OSError:
                continue
            digest.update(f"{path.relative_to(root)}\0{st.st_size}\0{st.st_mtime_ns}\n".encode())
    return digest.hexdigest()


def copy_brain(src: Path, dest: Path) -> None:
    """Copy the brain, leaving derived folders (indexes, packs, caches) empty."""
    skipped: list[Path] = []

    def ignore(directory: str, names: list[str]) -> set[str]:
        hit = {n for n in names if n in COPY_SKIP and (Path(directory) / n).is_dir()}
        skipped.extend(Path(directory, n).relative_to(src) for n in hit)
        return hit

    shutil.copytree(src, dest, symlinks=True, ignore=ignore)
    for rel in skipped:
        (dest / rel).mkdir(parents=True, exist_ok=True)


def make_read_only(root: Path) -> None:
    for directory, dirnames, filenames in os.walk(root, topdown=False):
        for name in filenames:
            p = Path(directory) / name
            if not p.is_symlink():
                p.chmod(p.stat().st_mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))
        d = Path(directory)
        d.chmod(d.stat().st_mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))


def make_writable(root: Path) -> None:
    for directory, _dirnames, filenames in os.walk(root):
        d = Path(directory)
        d.chmod(d.stat().st_mode | stat.S_IWUSR)
        for name in filenames:
            p = Path(directory) / name
            if not p.is_symlink():
                p.chmod(p.stat().st_mode | stat.S_IWUSR)


def is_target_safe(meta: dict[str, str]) -> bool:
    if meta.get("brain_review_state", "approved") != "approved":
        return False
    if meta.get("brain_sensitivity", "internal").lower() in SKIP_SENSITIVITY:
        return False
    if meta.get("brain_principal") or meta.get("brain_audience"):
        return False
    return True


def mine(project: Path) -> tuple[list[dict], int, Counter]:
    """Return (targets, unpromoted_sessions, document_frequency)."""
    canon: list[tuple[str, dict[str, str], str, str]] = []
    df: Counter = Counter()
    for folder in CANONICAL_DIRS:
        base = project / "okf" / folder
        if not base.is_dir():
            continue
        for path in sorted(base.glob("*.md")):
            if path.name in ("index.md", "log.md") or path.is_symlink():
                continue
            raw = path.read_text(encoding="utf-8", errors="replace")
            meta, body = split_frontmatter(raw)
            rel = path.relative_to(project).as_posix()
            canon.append((rel, meta, body, raw))
            df.update(set(tokens(meta.get("title", "") + " " + body)))
    targets: dict[str, dict] = {}
    for rel, meta, body, _raw in canon:
        if not is_target_safe(meta):
            continue
        text = meta.get("title", "") + "\n" + body
        kind = ""
        if meta.get("brain_supersedes") or CORRECTION.search(text):
            kind = "correction"
        elif DECISION.search(text):
            kind = "decision"
        if kind:
            targets[rel] = {"rel": rel, "kind": kind, "origin": "record", "meta": meta, "body": body}
    unpromoted = 0
    episodes = project / "episodes"
    if episodes.is_dir():
        for path in sorted(episodes.rglob("*.md")):
            if path.name in ("index.md", "log.md") or path.is_symlink():
                continue
            meta, body = split_frontmatter(path.read_text(encoding="utf-8", errors="replace"))
            if meta.get("brain_sensitivity", "internal").lower() in SKIP_SENSITIVITY:
                continue
            kind = "correction" if CORRECTION.search(body) else ("decision" if DECISION.search(body) else "")
            if not kind:
                continue
            episode_id = meta.get("brain_episode_id") or path.stem
            linked = [c for c in canon if episode_id in c[3] and is_target_safe(c[1])]
            if not linked:
                unpromoted += 1
                continue
            for rel, cmeta, cbody, _raw in linked:
                targets.setdefault(rel, {"rel": rel, "kind": kind, "origin": "session", "meta": cmeta, "body": cbody})
    return list(targets.values()), unpromoted, df


def follow_up_query(target: dict, df: Counter, total: int) -> str:
    counts = Counter(t for t in tokens(target["meta"].get("title", "") + " " + target["body"]) if t not in CUE_WORDS)
    ranked = sorted(counts, key=lambda t: (-(counts[t] * math.log((1 + total) / (1 + df.get(t, 0)))), t))
    words = ranked[:3]
    if not words:
        return ""
    if target["kind"] == "decision":
        return "follow up: what did we decide about " + " ".join(words)
    return "follow up: what is the current " + " ".join(words)


def write_filler(project: Path, project_id: str, queries: list[str], count: int, rng: random.Random) -> set[str]:
    base = project / "okf" / "claims"
    base.mkdir(parents=True, exist_ok=True)
    words = sorted({w for q in queries for w in tokens(q) if w not in {"follow", "current", "decide"}})
    rels: set[str] = set()
    for n in range(count):
        shared = rng.choice(words) if words else rng.choice(FILLER_WORDS)
        noise = " ".join(rng.sample(FILLER_WORDS, 6))
        rid = f"pe_filler_{n:04d}"
        text = (
            "---\ntype: Claim\n"
            f"title: \"Filler {n} {shared} {noise.split()[0]}\"\nstatus: stable\n"
            "generated: {by: process:personal-eval, at: 2026-01-01T00:00:00Z}\n"
            "sources: [{resource: source://personal-eval-filler}]\n"
            f"brain_project_id: {project_id}\nbrain_claim_id: {rid}\nbrain_review_state: approved\n"
            "brain_confidence: 0.5\nbrain_risk: low\nbrain_sensitivity: internal\n"
            "brain_source_authority: repository\nbrain_provenance: process://personal-eval\nbrain_schema_version: 3\n"
            f"---\n# Filler {n}\n\nUnrelated note: {shared} {noise}.\n"
        )
        (base / f"{rid}.md").write_text(text, encoding="utf-8")
        rels.add(f"okf/claims/{rid}.md")
    return rels


EXPANSION = re.compile(r"^Expansion: <code>([^<]+)</code>", re.M)


def run_cli(cli: Path, root: Path, env: dict[str, str], *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([str(cli), "--root", str(root), *args], env=env, capture_output=True, text=True, timeout=600)


def child_env(root: Path, cache: Path) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith(("LLM_BRAIN_", "MEMTHENA_"))}
    env["LLM_BRAIN_ROOT"] = str(root)
    env["LLM_BRAIN_CACHE_DIR"] = str(cache)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


def inside(child: Path, parent: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Personal eval on a private copy of a brain (hashes and scores only).")
    parser.add_argument("--brain", required=True, help="brain root to copy (never written)")
    parser.add_argument("--project", required=True, help="project id inside the brain")
    parser.add_argument("--output", required=True, help="report directory (outside the brain)")
    parser.add_argument("--filler", type=int, default=20)
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--budget-tokens", type=int, default=1200)
    parser.add_argument("--queries", help="optional TSV: target_hash<TAB>follow-up query")
    parser.add_argument("--cli", default=str(Path(__file__).resolve().parent.parent / "bin" / "llm-brain"))
    args = parser.parse_args(argv)
    try:
        return run(args)
    except Refused as exc:
        print(f"memthena: personal-eval refused: {exc}", file=sys.stderr)
        return 65


def run(args: argparse.Namespace) -> int:
    src = Path(args.brain).resolve()
    out = Path(args.output).resolve()
    cli = Path(args.cli).resolve()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.project):
        raise Refused("project id must be a plain id")
    if not (src / "registry").is_dir() or not (src / "projects" / args.project).is_dir():
        raise Refused("brain root or project not found")
    if inside(out, src) or inside(src, out):
        raise Refused("output must be outside the brain")
    if args.filler < 0 or args.limit < 1:
        raise Refused("--filler must be >= 0 and --limit >= 1")
    before = tree_fingerprint(src)
    scratch = Path(tempfile.mkdtemp(prefix="memthena-personal-eval."))
    try:
        snapshot = scratch / "snapshot"
        copy_brain(src, snapshot)
        make_read_only(snapshot)
        targets, unpromoted, df = mine(snapshot / "projects" / args.project)
        total_docs = sum(1 for _ in (snapshot / "projects" / args.project / "okf").rglob("*.md")) if (snapshot / "projects" / args.project / "okf").is_dir() else 0
        targets.sort(key=lambda t: hid(f"{args.project}/{t['rel']}"))
        targets = targets[: args.limit]
        overrides: dict[str, str] = {}
        if args.queries:
            for line in Path(args.queries).read_text(encoding="utf-8").splitlines():
                if "\t" in line and not line.startswith("#"):
                    key, query = line.split("\t", 1)
                    overrides[key.strip()] = query.strip()
        cases = []
        for target in targets:
            tid = hid(f"{args.project}/{target['rel']}")
            query = overrides.get(tid) or follow_up_query(target, df, total_docs)
            if query:
                cases.append({"id": tid, "rel": target["rel"], "kind": target["kind"], "origin": target["origin"], "query": query})
        work = scratch / "work"
        shutil.copytree(snapshot, work, symlinks=True)
        make_writable(work)
        project = work / "projects" / args.project
        rng = random.Random(args.seed)
        filler = write_filler(project, args.project, [c["query"] for c in cases], args.filler, rng)
        env = child_env(work, scratch / "cache")
        built = run_cli(cli, work, env, "index", "build", args.project)
        if built.returncode != 0:
            raise Refused("index build failed on the working copy")
        rows = []
        for case in cases:
            result = run_cli(cli, work, env, "pack", "build", args.project, "--task", case["query"], "--budget-tokens", str(args.budget_tokens))
            pack_file = ""
            for token in result.stdout.split():
                if token.startswith("file="):
                    pack_file = token[5:]
            rels = EXPANSION.findall(Path(pack_file).read_text(encoding="utf-8")) if result.returncode == 0 and pack_file and Path(pack_file).is_file() else []
            rank = rels.index(case["rel"]) + 1 if case["rel"] in rels else 0
            above = sum(1 for r in rels[: (rank - 1 if rank else len(rels))] if r in filler)
            rows.append({
                "case": hid(case["id"] + "|" + case["query"]),
                "target": case["id"],
                "kind": case["kind"],
                "origin": case["origin"],
                "hit": bool(rank),
                "rank": rank,
                "filler_above": above,
                "pack_records": len(rels),
                "pack_ok": result.returncode == 0,
            })
    finally:
        if scratch.exists():
            make_writable(scratch)
            shutil.rmtree(scratch, ignore_errors=True)
    after = tree_fingerprint(src)
    out.mkdir(parents=True, exist_ok=True)
    with (out / "results.tsv").open("w", encoding="utf-8") as fh:
        fh.write("case\ttarget\tkind\torigin\thit\trank\tfiller_above\tpack_records\tpack_ok\n")
        for r in rows:
            fh.write(f"{r['case']}\t{r['target']}\t{r['kind']}\t{r['origin']}\t{str(r['hit']).lower()}\t{r['rank']}\t{r['filler_above']}\t{r['pack_records']}\t{str(r['pack_ok']).lower()}\n")
    hits = sum(r["hit"] for r in rows)
    by_kind = {}
    for kind in ("correction", "decision"):
        sub = [r for r in rows if r["kind"] == kind]
        by_kind[kind] = {"cases": len(sub), "hits": sum(r["hit"] for r in sub)}
    summary = {
        "format": FORMAT,
        "format_version": FORMAT_VERSION,
        "project": hid(args.project),
        "cases": len(rows),
        "hits": hits,
        "hit_rate": round(hits / len(rows), 4) if rows else 0.0,
        "mrr": round(sum(1 / r["rank"] for r in rows if r["rank"]) / len(rows), 4) if rows else 0.0,
        "filler_records": len(filler),
        "filler_above_target_total": sum(r["filler_above"] for r in rows),
        "by_kind": by_kind,
        "unpromoted_sessions": unpromoted,
        "pack_failures": sum(not r["pack_ok"] for r in rows),
        "query_overrides": sum(1 for c in rows if c["target"] in overrides),
        "seed": args.seed,
        "source_unchanged": before == after,
    }
    (out / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"personal-eval=ok cases={len(rows)} hits={hits} hit_rate={summary['hit_rate']} mrr={summary['mrr']} unpromoted_sessions={unpromoted} source_unchanged={str(before == after).lower()} output={out}")
    return 0 if before == after else 70


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
