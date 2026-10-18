#!/usr/bin/env python3
"""LLM-Brain 0.9 helpers: label lineage, cascading invalidation and
working-memory/recall signals.

Read commands are pure functions of the vault files and ``--now``.  The few
write commands (``label-append``, ``working-append``, ``intention-patch``,
``summaries-build``) only ever *append* operational events or rewrite derived
files; the CLI (``bin/llm-brain``) holds the project lock and writes the audit
row around them.  Nothing here edits, promotes or deletes canonical OKF
records: labels live in an append-only ledger beside the vault, so history is
always traceable and a removed label is a new ``unlabel`` event.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import re
import sys
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import okf  # noqa: E402
import memory_signals as ms  # noqa: E402
from memory_signals import Vault, clean, iso, now_from, parse_time, ref_list, record_created  # noqa: E402

LEDGER = Path("lineage") / "labels.tsv"
LEDGER_HEADER = "event_id\trecorded_at\taction\tref\tlabel\ttarget\tactor\treason\tprev"
WORKING = Path("working") / "items.tsv"
WORKING_HEADER = "event_id\trecorded_at\taction\titem_id\tkind\tsession\ttext"
LABEL_RE = re.compile(r"^[a-z][a-z0-9-]{0,40}(?::[A-Za-z0-9._/@+-]{1,160})?$")
OUTCOMES = ("KEEP", "STALE", "REPLACE", "UNKNOWN")
# Labels that mark a point where the decision tree changed.
CHANGE_LABELS = ("superseded-by", "revised", "retired", "retracted", "outcome", "decision-point", "branch")
CONSTRAINT_KINDS = ("prohibition", "non-amplification", "commitment")
STOP = set("the a an and or of to in on for with is are was were be by at as it this that from what which how why when who does do did not".split())


def _sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()


def _one(text: Any, limit: int = 160) -> str:
    value = re.sub(r"\s+", " ", clean(text)).strip().replace("\t", " ")
    return value if len(value) <= limit else value[: limit - 1].rstrip() + "…"


def _created(vault: Vault, path: Path) -> dt.datetime | None:
    return record_created(vault.meta(path))


def _terms(text: str) -> list[str]:
    seen: list[str] = []
    for token in re.findall(r"[a-z0-9]+", (text or "").lower()):
        if len(token) > 2 and token not in STOP and token not in seen:
            seen.append(token)
    return seen


# ------------------------------------------------------------ label ledger

def read_ledger(root: Path) -> list[dict[str, str]]:
    path = root / LEDGER
    rows: list[dict[str, str]] = []
    if not path.is_file() or path.is_symlink():
        return rows
    names = LEDGER_HEADER.split("\t")
    for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines()):
        if number == 0 or not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) != len(names):
            continue
        rows.append(dict(zip(names, fields)))
    return rows


def verify_ledger(rows: list[dict[str, str]]) -> bool:
    prev = "root"
    for row in rows:
        body = "|".join(row[key] for key in ("recorded_at", "action", "ref", "label", "target", "actor", "reason"))
        if row["prev"] != prev or row["event_id"] != _sha(prev + "|" + body)[:16]:
            return False
        prev = row["event_id"]
    return True


def active_labels(vault: Vault) -> dict[str, dict[str, dict[str, str]]]:
    """ref -> label -> latest label event, after unlabel events are applied."""
    result: dict[str, dict[str, dict[str, str]]] = {}
    for row in read_ledger(vault.root):
        bucket = result.setdefault(row["ref"], {})
        if row["action"] == "label":
            bucket[row["label"]] = row
        elif row["action"] == "unlabel":
            bucket.pop(row["label"], None)
    return result


def derived_labels(vault: Vault) -> dict[str, list[tuple[str, str, str]]]:
    """Labels computed from existing lifecycle metadata (never stored).

    Returns ref -> [(label, target, date)].  These make supersession,
    retraction and state keys traceable with the same vocabulary as ledger
    labels without writing anything.
    """
    out: dict[str, list[tuple[str, str, str]]] = {}
    resolver = vault.resolver
    for path in vault.semantic_files():
        if not resolver.visible(path, strict_principal=True):
            continue
        meta = vault.meta(path)
        rel = vault.rel(path)
        when = _created(vault, path)
        stamp = iso(when) if when else ""
        key = clean(meta.get("brain_state_key"))
        if key:
            out.setdefault(rel, []).append((f"state:{key}", "", stamp))
        for field, label in (("brain_supersedes", "superseded-by"), ("brain_version_of", "revised")):
            for ref in ref_list(meta.get(field)):
                target = resolver.canonical_ref(ref)
                if target is None or target == path or not resolver.visible(target, strict_principal=True):
                    continue
                out.setdefault(vault.rel(target), []).append((label, rel, stamp))
                out.setdefault(rel, []).append(("supersedes" if label == "superseded-by" else "revision-of", vault.rel(target), stamp))
    retractions = vault.root / "okf" / "retractions"
    if retractions.is_dir():
        for path in sorted(retractions.glob("*.md")):
            try:
                meta, _ = okf.split_frontmatter(path)
            except okf.OkfError:
                continue
            target = resolver.canonical_ref(clean(meta.get("brain_retracts")))
            if target is None or not resolver.visible(target, strict_principal=True):
                continue
            gen = meta.get("generated")
            when = parse_time(gen.get("at")) if isinstance(gen, dict) else None
            out.setdefault(vault.rel(target), []).append(("retracted", f"okf/retractions/{path.name}", iso(when) if when else ""))
    for path, meta, _ in vault.frontmatter_dir("intentions"):
        if meta.get("type") != "Intention":
            continue
        status = clean(meta.get("brain_intention_status")) or "open"
        if status != "open":
            out.setdefault(f"intentions/{path.name}", []).append((f"intention-{status}", "", clean(meta.get("brain_closed_at"))))
    return out


def labels_for(vault: Vault, ref: str, stored: dict | None = None, derived: dict | None = None) -> list[str]:
    stored = active_labels(vault) if stored is None else stored
    derived = derived_labels(vault) if derived is None else derived
    names = [label for label in stored.get(ref, {})]
    names += [label + (f":{target}" if target and label in ("superseded-by",) else "") for label, target, _ in derived.get(ref, [])]
    names += [label for label, _, _ in derived.get(ref, []) if label == "superseded-by"]
    return sorted(set(names))


def label_matches(names: list[str], wanted: str) -> bool:
    for name in names:
        if name == wanted or name.split(":", 1)[0] == wanted:
            return True
    return False


def command_label_validate(args: argparse.Namespace) -> int:
    label = args.label.strip()
    if not LABEL_RE.fullmatch(label):
        print("invalid label: use name or name:value (lowercase name)", file=sys.stderr)
        return 65
    if label.startswith("outcome:") and label.split(":", 1)[1] not in OUTCOMES:
        print("outcome labels must be outcome:KEEP|STALE|REPLACE|UNKNOWN", file=sys.stderr)
        return 65
    if label.startswith("constraint:") and label.split(":", 1)[1] not in CONSTRAINT_KINDS:
        print("constraint labels must be constraint:prohibition|non-amplification|commitment", file=sys.stderr)
        return 65
    return 0


def resolve_ref(vault: Vault, ref: str) -> str:
    if ref.startswith("intentions/") or ref.startswith("working/"):
        safe, error = okf.LifecycleResolver._safe_ref(ref)
        return "" if error else safe
    target = vault.resolver.canonical_ref(ref)
    if target is None or not vault.resolver.visible(target, strict_principal=False):
        return ""
    return vault.rel(target)


def command_label_append(args: argparse.Namespace) -> int:
    """Append one label/unlabel event (CLI holds the project lock)."""
    vault = Vault(args.project_dir, args.principal)
    ref = resolve_ref(vault, args.ref)
    if not ref:
        print(f"unknown or hidden record: {args.ref}", file=sys.stderr)
        return 66
    target = ""
    if args.target:
        target = resolve_ref(vault, args.target)
        if not target:
            print(f"unknown or hidden target: {args.target}", file=sys.stderr)
            return 66
    if command_label_validate(args):
        return 65
    rows = read_ledger(vault.root)
    if rows and not verify_ledger(rows):
        print("label ledger hash chain is broken; refusing to append", file=sys.stderr)
        return 65
    current = active_labels(vault).get(ref, {})
    if args.action == "label" and args.label in current and current[args.label]["target"] == target:
        print(f"label=unchanged ref={ref} label={args.label} event_id={current[args.label]['event_id']}")
        return 0
    if args.action == "unlabel" and args.label not in current:
        print(f"label {args.label} is not active on {ref}", file=sys.stderr)
        return 65
    prev = rows[-1]["event_id"] if rows else "root"
    now = iso(now_from(args.now))
    fields = [now, args.action, ref, args.label, target, _one(args.actor, 80), _one(args.reason, 300)]
    event_id = _sha(prev + "|" + "|".join(fields))[:16]
    path = vault.root / LEDGER
    path.parent.mkdir(parents=True, exist_ok=True)
    new = not path.exists()
    with path.open("a", encoding="utf-8") as stream:
        if new:
            stream.write(LEDGER_HEADER + "\n")
        stream.write("\t".join([event_id] + fields + [prev]) + "\n")
    print(f"label={args.action} ref={ref} label_name={args.label} target={target or '-'} event_id={event_id}")
    return 0


def command_labels(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    stored = active_labels(vault)
    derived = derived_labels(vault)
    refs = sorted(set(stored) | set(derived))
    if args.ref:
        wanted = resolve_ref(vault, args.ref) or args.ref
        refs = [ref for ref in refs if ref == wanted]
    rows = []
    for ref in refs:
        for label, row in sorted(stored.get(ref, {}).items()):
            rows.append({"ref": ref, "label": label, "target": row["target"], "source": "ledger", "at": row["recorded_at"], "reason": row["reason"], "event_id": row["event_id"]})
        for label, target, at in derived.get(ref, []):
            rows.append({"ref": ref, "label": label, "target": target, "source": "derived", "at": at, "reason": "", "event_id": ""})
    if args.label:
        rows = [row for row in rows if label_matches([row["label"]], args.label)]
    rows.sort(key=lambda row: (row["ref"], row["label"], row["at"]))
    if args.json:
        print(json.dumps({"status": "ok", "ledger_verified": verify_ledger(read_ledger(vault.root)), "labels": rows}, ensure_ascii=False, separators=(",", ":")))
        return 0
    print("ref\tlabel\ttarget\tsource\tat\treason")
    for row in rows:
        print(f"{row['ref']}\t{row['label']}\t{row['target'] or '-'}\t{row['source']}\t{row['at'] or '-'}\t{row['reason'] or '-'}")
    return 0


def command_label_filter(args: argparse.Namespace) -> int:
    """Filter a ranked TSV (path first) by --with / --without labels."""
    vault = Vault(args.project_dir, args.principal)
    stored = active_labels(vault)
    derived = derived_labels(vault)
    for line in Path(args.ranked).read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        ref = line.split("\t", 1)[0]
        names = labels_for(vault, ref, stored, derived)
        if any(not label_matches(names, want) for want in args.with_label or []):
            continue
        if any(label_matches(names, drop) for drop in args.without_label or []):
            continue
        print(line)
    return 0


# ------------------------------------------------------------- lineage view

def _component(vault: Vault, seeds: set[str], stored: dict, derived: dict, depth: int = 6) -> set[str]:
    edges: dict[str, set[str]] = {}

    def link(a: str, b: str) -> None:
        if a and b and a != b:
            edges.setdefault(a, set()).add(b)
            edges.setdefault(b, set()).add(a)

    for ref, items in derived.items():
        for label, target, _ in items:
            if label in ("superseded-by", "supersedes", "revised", "revision-of"):
                link(ref, target)
    for ref, labels in stored.items():
        for row in labels.values():
            link(ref, row["target"])
    for path in vault.semantic_files():
        meta = vault.meta(path)
        for field in ("brain_depends_on", "brain_derived_from"):
            for raw in ref_list(meta.get(field)):
                target = vault.resolver.canonical_ref(raw)
                if target is not None and vault.resolver.visible(target, strict_principal=True):
                    link(vault.rel(path), vault.rel(target))
    seen = set(seeds)
    frontier = set(seeds)
    for _ in range(depth):
        frontier = {n for ref in frontier for n in edges.get(ref, set())} - seen
        if not frontier:
            break
        seen |= frontier
    return {ref for ref in seen if not ref.startswith("okf/retractions/")}


def lineage_events(vault: Vault, refs: set[str], stored: dict, derived: dict) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for ref in sorted(refs):
        path = vault.resolver.canonical_ref(ref)
        title = vault.title(path) if path is not None else ref
        if path is not None:
            when = _created(vault, path)
            events.append({"at": iso(when) if when else "", "ref": ref, "title": title, "event": "recorded", "detail": "", "changed": False, "source": "record"})
        for label, target, at in derived.get(ref, []):
            if label in ("supersedes", "revision-of"):
                other = vault.resolver.canonical_ref(target)
                events.append({"at": at, "ref": ref, "title": title, "event": label, "detail": f"{target} ({vault.title(other) if other else target})", "changed": True, "source": "derived"})
            elif label == "retracted":
                events.append({"at": at, "ref": ref, "title": title, "event": "retracted", "detail": target, "changed": True, "source": "derived"})
        for label, row in stored.get(ref, {}).items():
            name = label.split(":", 1)[0]
            events.append({"at": row["recorded_at"], "ref": ref, "title": title, "event": f"label {label}", "detail": (row["target"] + " — " if row["target"] else "") + row["reason"], "changed": name in CHANGE_LABELS and label != "outcome:KEEP", "source": "ledger", "event_id": row["event_id"]})
    # Removed labels stay visible in the timeline as history.
    for row in read_ledger(vault.root):
        if row["action"] == "unlabel" and row["ref"] in refs:
            events.append({"at": row["recorded_at"], "ref": row["ref"], "title": row["ref"], "event": f"unlabel {row['label']}", "detail": row["reason"], "changed": False, "source": "ledger", "event_id": row["event_id"]})
    events.sort(key=lambda item: (item["at"] or "9999", item["ref"], item["event"]))
    return events


def current_heads(vault: Vault, refs: set[str], derived: dict, stored: dict) -> list[str]:
    heads = []
    for ref in sorted(refs):
        names = [label for label, _, _ in derived.get(ref, [])] + list(stored.get(ref, {}))
        if any(n in ("superseded-by", "retracted") for n in names):
            continue
        if any(n in ("retired", "outcome:STALE", "outcome:REPLACE") for n in names):
            continue
        heads.append(ref)
    return heads


def render_tree(vault: Vault, refs: set[str], derived: dict, stored: dict) -> list[str]:
    children: dict[str, list[str]] = {}
    has_parent: set[str] = set()
    for ref in refs:
        for label, target, _ in derived.get(ref, []):
            if label in ("supersedes", "revision-of") and target in refs:
                children.setdefault(target, []).append(ref)
                has_parent.add(ref)
        for label, row in stored.get(ref, {}).items():
            if label.split(":", 1)[0] in ("superseded-by", "branch") and row["target"] in refs:
                children.setdefault(ref, []).append(row["target"])
                has_parent.add(row["target"])
    lines: list[str] = []

    def walk(ref: str, prefix: str, seen: set[str]) -> None:
        path = vault.resolver.canonical_ref(ref)
        title = vault.title(path) if path is not None else ref
        marks = [label for label in labels_for(vault, ref, stored, derived) if label.split(":", 1)[0] in CHANGE_LABELS + ("constraint",)]
        lines.append(f"{prefix}{title} [{ref}]" + (f" {{{', '.join(marks)}}}" if marks else ""))
        if ref in seen:
            return
        for child in sorted(set(children.get(ref, []))):
            walk(child, prefix + "  └─ ", seen | {ref})

    for root in sorted(ref for ref in refs if ref not in has_parent):
        walk(root, "", set())
    return lines


def command_lineage(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    stored = active_labels(vault)
    derived = derived_labels(vault)
    seeds: set[str] = set()
    if args.ref:
        ref = resolve_ref(vault, args.ref)
        if ref:
            seeds.add(ref)
    if args.decision:
        for ref, labels in stored.items():
            for label in labels:
                if label in (f"decision-point:{args.decision}", f"branch:{args.decision}", f"topic:{args.decision}"):
                    seeds.add(ref)
    if args.topic:
        terms = _terms(args.topic)
        for path in vault.semantic_files():
            if not vault.resolver.visible(path, strict_principal=True):
                continue
            meta = vault.meta(path)
            hay = " ".join([vault.title(path), clean(meta.get("brain_state_key")), " ".join(ref_list(meta.get("tags")))]).lower()
            if terms and all(term in hay for term in terms):
                seeds.add(vault.rel(path))
        for ref, labels in stored.items():
            if any(label.split(":", 1)[-1].lower() == args.topic.lower() for label in labels):
                seeds.add(ref)
    refs = _component(vault, seeds, stored, derived) if seeds else set()
    events = lineage_events(vault, refs, stored, derived)
    heads = current_heads(vault, refs, derived, stored)
    tree = render_tree(vault, refs, derived, stored)
    changes = [item for item in events if item["changed"]]
    if args.json:
        print(json.dumps({"status": "ok" if refs else "empty", "derived": True, "records": sorted(refs), "current": heads,
                          "changes": len(changes), "timeline": events, "tree": tree}, ensure_ascii=False, separators=(",", ":")))
        return 0
    if not refs:
        print("lineage=empty (no visible records match; labels and supersession links seed the tree)")
        return 0
    print(f"LINEAGE ({len(refs)} records, {len(changes)} change point(s); derived, read-only)")
    print("Tree:")
    for line in tree:
        print(f"  {line}")
    print("Current: " + (", ".join(heads) if heads else "none (every branch is superseded, retracted, retired or stale)"))
    print("Timeline (* = decision tree changed here):")
    for item in events:
        mark = "*" if item["changed"] else " "
        detail = f" — {item['detail']}" if item["detail"] else ""
        print(f" {mark} {(item['at'] or 'undated')[:19]}  {item['event']}  {item['ref']}{detail}")
    return 0


# --------------------------------------------- #8 cascading invalidation

def invalidation_plan(vault: Vault, trigger_ref: str, max_depth: int = 3) -> list[dict[str, str]]:
    resolver = vault.resolver
    trigger = resolver.canonical_ref(trigger_ref)
    if trigger is None or not resolver.visible(trigger, strict_principal=True):
        return []
    tmeta = vault.meta(trigger)
    trel = vault.rel(trigger)
    tkey = clean(tmeta.get("brain_state_key"))
    tdate = _created(vault, trigger)
    killed: dict[str, str] = {}
    for raw in ref_list(tmeta.get("brain_supersedes")):
        target = resolver.canonical_ref(raw)
        if target is not None and target != trigger:
            killed[vault.rel(target)] = "explicit supersession"
    if not resolver.effective(trigger):
        killed[trel] = "trigger is retracted or not effective"
    plan: dict[str, dict[str, str]] = {}

    def put(ref: str, outcome: str, reason: str, depth: int) -> None:
        rank = {"REPLACE": 3, "STALE": 2, "UNKNOWN": 1, "KEEP": 0}
        old = plan.get(ref)
        if old is None or rank[outcome] > rank[old["outcome"]]:
            plan[ref] = {"ref": ref, "outcome": outcome, "reason": reason, "depth": str(depth), "trigger": trel}

    for ref, why in killed.items():
        if ref != trel:
            put(ref, "REPLACE", why, 0)
    # Same state key, older, still effective: the later observation implicitly
    # replaces it even without an explicit `supersedes` (STALE Type II).
    for path in vault.semantic_files():
        if path == trigger or not resolver.visible(path, strict_principal=True):
            continue
        meta = vault.meta(path)
        rel = vault.rel(path)
        if tkey and clean(meta.get("brain_state_key")) == tkey and resolver.effective(trigger):
            when = _created(vault, path)
            if when is not None and tdate is not None and when < tdate:
                put(rel, "REPLACE", f"older holder of state {tkey}", 0)
                killed.setdefault(rel, f"implicit: state {tkey}")
            elif when is None or tdate is None:
                put(rel, "UNKNOWN", f"shares state {tkey}; dates unknown", 0)
    # Propagate along dependency topology.
    frontier = set(killed)
    for depth in range(1, max_depth + 1):
        nxt: set[str] = set()
        for path in vault.semantic_files():
            if path == trigger or not resolver.visible(path, strict_principal=True):
                continue
            meta = vault.meta(path)
            rel = vault.rel(path)
            refs_by_field = {field: {vault.rel(t) for raw in ref_list(meta.get(field)) for t in [resolver.canonical_ref(raw)] if t is not None} for field in ("brain_depends_on", "brain_derived_from", "brain_supports", "brain_conflicts")}
            hit_dep = (refs_by_field["brain_depends_on"] | refs_by_field["brain_derived_from"]) & frontier
            if hit_dep:
                put(rel, "STALE", f"depends on invalidated {sorted(hit_dep)[0]}", depth)
                nxt.add(rel)
                continue
            if refs_by_field["brain_supports"] & frontier:
                independent = (len(meta.get("sources")) if isinstance(meta.get("sources"), list) else 0) + len(refs_by_field["brain_supports"] - frontier)
                put(rel, "KEEP" if independent >= 1 else "UNKNOWN", "supports an invalidated record" + ("; has its own sources" if independent >= 1 else "; no independent support"), depth)
            elif refs_by_field["brain_conflicts"] & frontier:
                put(rel, "UNKNOWN", "conflicted with an invalidated record", depth)
        frontier = nxt - set(plan) | nxt
        if not nxt:
            break
    return sorted(plan.values(), key=lambda row: (int(row["depth"]), row["outcome"], row["ref"]))


def command_invalidate(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    rows = invalidation_plan(vault, args.trigger, args.max_depth)
    if args.json:
        print(json.dumps({"status": "ok", "derived": True, "trigger": args.trigger, "plan": rows}, separators=(",", ":")))
        return 0
    print("ref\toutcome\tdepth\treason\ttrigger")
    for row in rows:
        print(f"{row['ref']}\t{row['outcome']}\t{row['depth']}\t{row['reason']}\t{row['trigger']}")
    return 0


# ---------------------------------------------------- #1 recency re-rank

def command_recency(args: argparse.Namespace) -> int:
    """Soft access-recency bias: ×1.5 for just-used, decaying to a ×0.7 floor.

    Nothing is filtered; never-used records sit at the floor together so the
    lexical order among them is unchanged.  Output keeps input columns and
    appends a ``recency`` multiplier column.
    """
    vault = Vault(args.project_dir, args.principal)
    now = now_from(args.now)
    table, _ = ms.usage_table(vault)
    half = max(args.half_life_days, 0.1)
    rows = []
    for line in Path(args.ranked).read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        fields = line.split("\t")
        try:
            score = float(fields[1])
        except (IndexError, ValueError):
            score = 0.0
        last = table.get(fields[0], {}).get("last_used") if fields[0] in table else None
        if last is None:
            mult = args.floor
        else:
            age = max((now - last).total_seconds() / 86400.0, 0.0)
            mult = args.floor + (args.peak - args.floor) * math.pow(0.5, age / half)
        rows.append((score * mult, fields, mult))
    rows.sort(key=lambda row: (-row[0], row[1][0]))
    for score, fields, mult in rows:
        out = list(fields)
        if len(out) > 1:
            out[1] = f"{score:.6f}"
        print("\t".join(out + [f"{mult:.3f}"]))
    return 0


# -------------------------------------------- #2 named-gate abstention

def gate_report(vault: Vault, query: str, now: dt.datetime) -> dict[str, Any]:
    terms = _terms(query)
    counts = {"relevance": 0, "validity": 0, "applicability": 0, "risk": 0}
    examples: dict[str, list[str]] = {key: [] for key in counts}
    matched = eligible = 0
    resolver = vault.resolver
    for path in vault.semantic_files():
        meta = vault.meta(path)
        # 0.10 #9: a record scoped to another principal does not exist for
        # this caller, so its words must not even be matched or counted.
        if (clean(meta.get("brain_sensitivity")) or "internal") == "internal" and not resolver.visible(path, strict_principal=True):
            continue
        hay = (vault.title(path) + " " + vault.body(path) + " " + clean(meta.get("brain_state_key"))).lower()
        if not terms or not any(term in hay for term in terms):
            continue
        matched += 1
        rel = vault.rel(path)
        sensitivity = clean(meta.get("brain_sensitivity")) or "internal"
        gate, reason = "", ""
        if sensitivity != "internal" or clean(meta.get("brain_commitment")) == "quarantine" or "quarantine" in clean(meta.get("brain_review_state")):
            gate, reason = "risk", f"sensitivity {sensitivity}" if sensitivity != "internal" else "quarantined"
        elif not resolver.visible(path, strict_principal=True):
            gate, reason = "applicability", "not visible to this principal"
        elif (vault.root / "okf" / "retractions" / f"{path.stem}.md").is_file():
            gate, reason = "validity", "retracted"
        elif not resolver.effective(path):
            gate, reason = "validity", f"not approved ({clean(meta.get('brain_review_state')) or clean(meta.get('status'))})"
        elif path in vault.superseded():
            gate, reason = "validity", "superseded"
        elif (parse_time(meta.get("brain_valid_to")) or now + dt.timedelta(days=1)) <= now:
            gate, reason = "validity", "validity window ended"
        elif clean(meta.get("brain_loading_temperature")) == "cold":
            gate, reason = "applicability", "cold tier (use --include-cold)"
        elif (parse_time(meta.get("brain_valid_from")) or now) > now:
            gate, reason = "applicability", "not yet valid"
        else:
            eligible += 1
            continue
        counts[gate] += 1
        if len(examples[gate]) < 3:
            # Hidden or risky records are counted, never named.
            examples[gate].append(rel + f" ({reason})" if gate in ("validity",) else reason)
    if matched == 0:
        counts["relevance"] = 1
        examples["relevance"].append("no record shares a content word with the query")
    refused = [gate for gate in ("relevance", "validity", "applicability", "risk") if counts[gate]]
    primary = "none" if eligible else (max(refused, key=lambda g: counts[g]) if refused else "relevance")
    advice = {
        "relevance": "rephrase the query or capture the missing knowledge",
        "validity": "the matching memory is outdated or unapproved; check corrections, lineage or review",
        "applicability": "memory exists but is out of scope (principal, cold tier or validity start)",
        "risk": "matching memory is withheld by sensitivity or quarantine policy",
        "none": "eligible memory exists; widen the limit or check the intent",
    }[primary]
    return {"query_terms": terms, "matched": matched, "eligible": eligible, "gates": counts, "examples": examples, "primary_gate": primary, "advice": advice}


def command_gates(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    report = gate_report(vault, args.query, now_from(args.now))
    if args.json:
        print(json.dumps({"status": "ok", "derived": True, **report}, ensure_ascii=False, separators=(",", ":")))
        return 0
    if args.metadata:
        print(f"abstain_gate={report['primary_gate']}")
        for gate, count in report["gates"].items():
            print(f"abstain_{gate}_count={count}")
        return 0
    print("gate\trefused\texamples")
    for gate in ("relevance", "validity", "applicability", "risk"):
        print(f"{gate}\t{report['gates'][gate]}\t{'; '.join(report['examples'][gate]) or '-'}")
    print(f"primary_gate={report['primary_gate']} eligible={report['eligible']} advice={report['advice']}")
    return 0


# ----------------------------------------- #9 sufficiency-gated recall

def eligible_files(vault: Vault, now: dt.datetime) -> list[Path]:
    return [path for path in vault.semantic_files() if vault.eligible(path, now)]


def bm25_rank(vault: Vault, files: list[Path], query: str) -> list[tuple[str, float]]:
    import contextlib
    import io
    import tempfile
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".paths") as handle:
        handle.write("\n".join(str(p) for p in files))
        name = handle.name
    buffer = io.StringIO()
    try:
        with contextlib.redirect_stdout(buffer):
            ms.command_bm25(argparse.Namespace(project_dir=str(vault.root), paths_file=name, query=query, hint_path=[]))
    finally:
        os.unlink(name)
    rows = []
    for line in buffer.getvalue().splitlines():
        parts = line.split("\t")
        rows.append((parts[0], float(parts[1])))
    return rows


def sufficiency_loop(vault: Vault, query: str, now: dt.datetime, batch: int, maximum: int, target: float) -> dict[str, Any]:
    terms = _terms(query)
    ranked = bm25_rank(vault, eligible_files(vault, now), query)
    taken: list[str] = []
    covered: set[str] = set()
    steps = []
    stop = "exhausted"
    stored = active_labels(vault)
    for start in range(0, min(len(ranked), maximum), max(batch, 1)):
        chunk = [ref for ref, _ in ranked[start:start + batch]][: maximum - len(taken)]
        before = len(covered)
        for ref in chunk:
            path = vault.resolver.canonical_ref(ref)
            text = (vault.title(path) + " " + vault.body(path)).lower() if path else ""
            covered |= {term for term in terms if term in text}
            taken.append(ref)
        coverage = len(covered) / len(terms) if terms else 1.0
        gain = (len(covered) - before) / len(terms) if terms else 0.0
        contradictions = []
        refs = set(taken)
        for ref in taken:
            path = vault.resolver.canonical_ref(ref)
            meta = vault.meta(path) if path else {}
            for raw in ref_list(meta.get("brain_conflicts")):
                other = vault.resolver.canonical_ref(raw)
                if other is not None and vault.rel(other) in refs:
                    contradictions.append(f"{ref}<>{vault.rel(other)}")
            if any(label in ("outcome:UNKNOWN",) for label in stored.get(ref, {})):
                contradictions.append(f"{ref}:outcome-unknown")
        step = {"fetched": len(taken), "sufficiency": round(coverage, 3), "missing": sorted(set(terms) - covered),
                "contradiction": len(contradictions), "continue_utility": round(gain, 3)}
        steps.append(step)
        if coverage >= target and not contradictions:
            stop = "sufficient"
            break
        if start > 0 and gain == 0.0:
            stop = "no-gain"
            break
        if len(taken) >= maximum:
            stop = "budget"
            break
    if not ranked:
        stop = "empty"
    return {"query_terms": terms, "selected": taken, "stop": stop, "steps": steps, "candidates": len(ranked)}


def command_sufficiency(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    result = sufficiency_loop(vault, args.query, now_from(args.now), args.batch, args.max, args.target)
    if args.json:
        print(json.dumps({"status": "ok", "derived": True, **result}, ensure_ascii=False, separators=(",", ":")))
        return 0
    if args.count_only:
        print(len(result["selected"]))
        return 0
    print("step\tfetched\tsufficiency\tmissing\tcontradiction\tcontinue_utility")
    for index, step in enumerate(result["steps"], 1):
        print(f"{index}\t{step['fetched']}\t{step['sufficiency']}\t{','.join(step['missing']) or '-'}\t{step['contradiction']}\t{step['continue_utility']}")
    print(f"stop={result['stop']} selected={','.join(result['selected']) or 'none'}")
    return 0


# -------------------------------------------- #6 folder summary indexes

def summary_text(vault: Vault, folder: Path) -> str:
    rel_folder = folder.relative_to(vault.root).as_posix()
    lines = [f"# {rel_folder} — derived summary index", "",
             "Derived and rebuildable (`llm-brain browse build`). Raw files stay authoritative; open them before relying on details.", ""]
    files = sorted(p for p in folder.glob("*.md") if p.is_file() and not p.is_symlink() and p.name != "README.md")
    subdirs = sorted(p for p in folder.iterdir() if p.is_dir() and not p.is_symlink())
    if subdirs:
        lines.append("## Folders")
        for sub in subdirs:
            count = len(list(sub.rglob("*.md")))
            lines.append(f"- `{sub.name}/` — {count} file(s)")
        lines.append("")
    groups: dict[str, list[str]] = {}
    for path in files:
        try:
            meta, body = okf.split_frontmatter(path)
        except okf.OkfError:
            continue
        resolved = path.resolve()
        if resolved in vault.resolver.file_set and not vault.resolver.visible(resolved, strict_principal=True):
            continue
        if clean(meta.get("brain_sensitivity") or "internal") != "internal" or ref_list(meta.get("brain_principal")):
            continue  # restricted or principal-scoped records are counted only
        if (vault.root / "okf" / "retractions" / path.name).is_file():
            continue  # retracted: forgetting sticks; the tombstone keeps lineage
        when = record_created(meta)
        key = when.strftime("%Y-%m") if when else "undated"
        title = clean(meta.get("title")) or path.stem
        summary = _one(ms.first_sentence(body, 140), 140)
        state = ""
        if resolved in vault.resolver.file_set:
            state = " (superseded)" if resolved in vault.superseded() else ("" if vault.resolver.effective(resolved) else " (not effective)")
        groups.setdefault(key, []).append(f"- [{title}]({path.name}){state}: {summary}" if summary else f"- [{title}]({path.name}){state}")
    for key in sorted(groups, reverse=True):
        lines.append(f"## {key}")
        lines.extend(sorted(groups[key]))
        lines.append("")
    hidden = len(files) - sum(len(v) for v in groups.values())
    if hidden:
        lines.append(f"({hidden} restricted, scoped, retracted or unreadable file(s) not summarised.)")
    return "\n".join(lines).rstrip() + "\n"


def summary_folders(vault: Vault) -> list[Path]:
    out = []
    for top in ("okf", "episodes"):
        base = vault.root / top
        if not base.is_dir() or base.is_symlink():
            continue
        out.append(base)
        out.extend(sorted(p for p in base.rglob("*") if p.is_dir() and not p.is_symlink() and "retractions" not in p.parts))
    return out


def command_summaries(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    target = vault.root / "indexes" / "summaries"
    if args.action == "build":
        target.mkdir(parents=True, exist_ok=True)
        written = 0
        names = set()
        for folder in summary_folders(vault):
            name = folder.relative_to(vault.root).as_posix().replace("/", "__") + ".md"
            names.add(name)
            path = target / name
            text = summary_text(vault, folder)
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                tmp = path.with_suffix(".tmp")
                tmp.write_text(text, encoding="utf-8")
                tmp.replace(path)
                written += 1
        for stale in target.glob("*.md"):
            if stale.name not in names:
                stale.unlink()  # derived only
        print(f"summaries=built folders={len(names)} written={written} dir={target}")
        return 0
    folder = vault.root / (args.folder or "okf")
    safe, error = okf.LifecycleResolver._safe_ref(args.folder or "okf")
    if error or not folder.is_dir():
        print(f"unknown folder: {args.folder}", file=sys.stderr)
        return 66
    sys.stdout.write(summary_text(vault, vault.root / safe))
    return 0


# -------------------------------------- #7 progressive state disclosure

def state_rows(vault: Vault, now: dt.datetime) -> list[dict[str, str]]:
    rows = []
    for path in vault.semantic_files():
        meta = vault.meta(path)
        key = clean(meta.get("brain_state_key"))
        if not key or not vault.eligible(path, now):
            continue
        rows.append({"key": key, "ref": vault.rel(path), "summary": _one(ms.lead_sentences(vault.body(path), 120), 120),
                     "hash": hashlib.sha256(path.read_bytes()).hexdigest()[:12]})
    rows.sort(key=lambda row: (row["key"], row["ref"]))
    return rows


def command_state(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    now = now_from(args.now)
    rows = state_rows(vault, now)
    if args.action == "index":
        previous: dict[str, dict[str, str]] = {}
        if args.since:
            for line in Path(args.since).read_text(encoding="utf-8").splitlines()[1:]:
                parts = line.split("\t")
                if len(parts) >= 4:
                    previous[parts[1]] = {"key": parts[0], "hash": parts[3]}
        print("key\tref\tsummary\thash" + ("\tchange" if args.since else ""))
        seen = set()
        for row in rows:
            seen.add(row["ref"])
            change = ""
            if args.since:
                old = previous.get(row["ref"])
                change = "\tadded" if old is None else ("\tupdated" if old["hash"] != row["hash"] else "\tunchanged")
                if change == "\tunchanged" and args.changes_only:
                    continue
            print(f"{row['key']}\t{row['ref']}\t{row['summary']}\t{row['hash']}{change}")
        if args.since:
            for ref, old in sorted(previous.items()):
                if ref not in seen:
                    print(f"{old['key']}\t{ref}\t-\t{old['hash']}\tremoved")
        return 0
    wanted = args.key
    matches = [row for row in rows if row["key"] == wanted or row["ref"] == wanted]
    if not matches:
        print(f"no current state for {wanted}", file=sys.stderr)
        return 66
    for row in matches:
        path = vault.resolver.canonical_ref(row["ref"])
        print(f"## {row['key']} — {vault.title(path)} [{row['ref']}]\n")
        print(vault.body(path).strip() + "\n")
    return 0


# ------------------------------------------------- #10 working memory

def read_working(root: Path) -> list[dict[str, str]]:
    path = root / WORKING
    names = WORKING_HEADER.split("\t")
    rows = []
    if path.is_file() and not path.is_symlink():
        for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines()):
            fields = line.split("\t")
            if number and len(fields) == len(names):
                rows.append(dict(zip(names, fields)))
    return rows


def open_working(root: Path, session: str = "") -> list[dict[str, str]]:
    items: dict[str, dict[str, str]] = {}
    for row in read_working(root):
        if row["action"] == "add":
            items[row["item_id"]] = dict(row, status="open")
        elif row["item_id"] in items:
            items[row["item_id"]]["status"] = row["action"]
    result = [item for item in items.values() if item["status"] == "open" and (not session or item["session"] in ("", "-", session))]
    return sorted(result, key=lambda item: (item["recorded_at"], item["item_id"]))


def command_working(args: argparse.Namespace) -> int:
    root = Path(args.project_dir).resolve()
    now = iso(now_from(args.now))
    if args.action == "list":
        items = open_working(root, args.session) if args.status == "open" else read_working(root)
        if args.json:
            print(json.dumps({"status": "ok", "items": items}, ensure_ascii=False, separators=(",", ":")))
            return 0
        print("item_id\tkind\tsession\tstatus\trecorded_at\ttext")
        for item in items:
            print(f"{item['item_id']}\t{item['kind']}\t{item['session']}\t{item.get('status', item['action'])}\t{item['recorded_at']}\t{item['text']}")
        return 0
    if args.action == "add":
        if args.kind not in ("todo", "binding", "constraint"):
            print("--kind must be todo, binding or constraint", file=sys.stderr)
            return 64
        item_id = "wm_" + _sha(f"{args.text}|{args.kind}|{args.session}|{now}")[:12]
        fields = [now, "add", item_id, args.kind, _one(args.session, 80) or "-", _one(args.text, 300)]
    else:
        ids = {item["item_id"] for item in open_working(root)}
        if args.item not in ids:
            print(f"working item is not open: {args.item}", file=sys.stderr)
            return 65
        item_id = args.item
        fields = [now, args.action, item_id, "-", "-", _one(args.text or args.action, 300)]
    path = root / WORKING
    path.parent.mkdir(parents=True, exist_ok=True)
    new = not path.exists()
    with path.open("a", encoding="utf-8") as stream:
        if new:
            stream.write(WORKING_HEADER + "\n")
        stream.write("\t".join([_sha("|".join(fields))[:16]] + fields) + "\n")
    print(f"working={args.action} item_id={item_id}")
    return 0


# ------------------------------------------- #4 standing constraints

def constraint_rows(vault: Vault, now: dt.datetime) -> list[dict[str, str]]:
    stored = active_labels(vault)
    rows = []
    for path in vault.semantic_files():
        if not vault.eligible(path, now):
            continue
        rel = vault.rel(path)
        kind = clean(vault.meta(path).get("brain_constraint"))
        for label in stored.get(rel, {}):
            if label.startswith("constraint:"):
                kind = label.split(":", 1)[1]
        if kind in CONSTRAINT_KINDS:
            rows.append({"kind": kind, "ref": rel, "title": vault.title(path), "text": _one(ms.lead_sentences(vault.body(path), 200), 200)})
    for item in open_working(vault.root):
        if item["kind"] == "constraint":
            rows.append({"kind": "prohibition", "ref": f"working/{item['item_id']}", "title": "Working constraint", "text": item["text"]})
    order = {kind: index for index, kind in enumerate(CONSTRAINT_KINDS)}
    rows.sort(key=lambda row: (order.get(row["kind"], 9), row["ref"]))
    return rows


def constraints_due(turn: int, every: int) -> bool:
    return turn > 0 and every > 0 and turn >= every and turn % every == 0


def command_constraints(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    rows = constraint_rows(vault, now_from(args.now))
    due = constraints_due(args.turn, args.every) if args.turn else True
    print(f"kind\tref\ttitle\ttext\t(due={'true' if due else 'false'})")
    if due:
        for row in rows:
            print(f"{row['kind']}\t{row['ref']}\t{row['title']}\t{row['text']}")
    return 0


# ------------------------------------- #5 / #11 intention lifecycle

def intention_phase(meta: dict[str, Any], due: str, now: dt.datetime, revisions: int) -> str:
    status = clean(meta.get("brain_intention_status")) or "open"
    if status in ("done", "cancelled"):
        return f"decided-{status}"
    quiet = parse_time(meta.get("brain_quiet_until"))
    if quiet is not None and quiet > now:
        return "quiet"
    if clean(meta.get("brain_intention_once")).lower() == "true" and clean(meta.get("brain_last_fired_at")):
        return "quiet"
    if due:
        return "filtered-due"
    return "revised" if revisions else "formed"


def patches(root: Path, intention_id: str) -> list[list[str]]:
    path = root / "intentions" / f"{intention_id}.patches.tsv"
    if not path.is_file() or path.is_symlink():
        return []
    return [line.split("\t") for line in path.read_text(encoding="utf-8").splitlines()[1:] if line.strip()]


def command_intention_patch(args: argparse.Namespace) -> int:
    root = Path(args.project_dir).resolve()
    path = root / "intentions" / f"{args.intention_id}.patches.tsv"
    new = not path.exists()
    with path.open("a", encoding="utf-8") as stream:
        if new:
            stream.write("recorded_at\tpatch\told\tnew\treason\n")
        stream.write("\t".join([iso(now_from(args.now)), args.patch, _one(args.old, 200), _one(args.new, 200), _one(args.reason, 200)]) + "\n")
    print(f"intention_patch={args.patch} intention_id={args.intention_id}")
    return 0


def command_board(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    now = now_from(args.now)
    rows = []
    for path, meta, _ in vault.frontmatter_dir("intentions"):
        if meta.get("type") != "Intention":
            continue
        scope = ref_list(meta.get("brain_principal"))
        if scope and vault.principal not in scope:
            continue
        iid = clean(meta.get("brain_intention_id")) or path.stem
        status = clean(meta.get("brain_intention_status")) or "open"
        due = ms.intention_due(vault, meta, now, args.task or "", []) if status == "open" else ""
        revs = len(patches(vault.root, iid))
        rows.append((intention_phase(meta, due, now, revs), iid, f"{clean(meta.get('brain_trigger_kind'))}:{clean(meta.get('brain_trigger_value'))}", revs, clean(meta.get("brain_intention_action"))))
    order = ["filtered-due", "formed", "revised", "quiet", "decided-done", "decided-cancelled"]
    rows.sort(key=lambda row: (order.index(row[0]) if row[0] in order else 9, row[1]))
    print("phase\tid\ttrigger\trevisions\taction")
    for row in rows:
        print("\t".join(str(v) for v in row))
    return 0


def command_observe(args: argparse.Namespace) -> int:
    """Proactively observe hidden state before intentions come due (read-only)."""
    vault = Vault(args.project_dir, args.principal)
    now = now_from(args.now)
    print("id\tdue_in_days\tobservation\tdetail")
    for path, meta, _ in vault.frontmatter_dir("intentions"):
        if meta.get("type") != "Intention" or (clean(meta.get("brain_intention_status")) or "open") != "open":
            continue
        scope = ref_list(meta.get("brain_principal"))
        if scope and vault.principal not in scope:
            continue
        iid = clean(meta.get("brain_intention_id")) or path.stem
        kind = clean(meta.get("brain_trigger_kind"))
        value = clean(meta.get("brain_trigger_value"))
        observe_key = clean(meta.get("brain_intention_observe")) or (value if kind == "state" else "")
        days = "-"
        if kind == "date":
            when = parse_time(value)
            if when is None:
                continue
            delta = (when - now).total_seconds() / 86400.0
            if delta > args.within_days:
                continue
            days = f"{max(delta, 0):.1f}"
        if observe_key:
            fp = ms.state_fingerprint(vault, observe_key, now)
            baseline = clean(meta.get("brain_trigger_baseline"))
            obs = "state-none" if fp == "none" else ("state-changed" if baseline and fp != baseline else "state-unchanged")
            holders = [row["ref"] for row in state_rows(vault, now) if row["key"] == observe_key]
            print(f"{iid}\t{days}\t{obs}\t{observe_key}: {', '.join(holders) or 'no current holder'}")
        elif kind == "date":
            print(f"{iid}\t{days}\tupcoming\t{_one(meta.get('brain_intention_action'), 120)}")
    return 0


def completed_cues(vault: Vault, now: dt.datetime, task: str, days: int = 7) -> list[str]:
    """Done intentions whose cue would fire again: tell the agent not to repeat."""
    lines = []
    for path, meta, _ in vault.frontmatter_dir("intentions"):
        if meta.get("type") != "Intention" or clean(meta.get("brain_intention_status")) != "done":
            continue
        closed = parse_time(meta.get("brain_closed_at"))
        if closed is None or (now - closed).days > days or closed > now:
            continue
        probe = dict(meta, brain_intention_status="open", brain_quiet_until="", brain_last_fired_at="")
        if clean(meta.get("brain_trigger_kind")) == "date" or ms.intention_due(vault, probe, now, task, ms.hints_from(task, [])):
            lines.append(f"- Already done {closed.date().isoformat()}: {clean(meta.get('brain_intention_action'))} (`{clean(meta.get('brain_intention_id')) or path.stem}`) — do not repeat.")
    return sorted(lines)


# --------------------------------------------------- pack extras

def command_pack_extras(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    now = now_from(args.now)
    out: list[str] = []
    if args.turn:
        rows = constraint_rows(vault, now) if constraints_due(args.turn, args.every) else []
        if rows:
            out.append(f"## Standing Constraints — still in force at turn {args.turn}\n")
            out += [f"- {row['kind'].upper()}: {row['title']}: {row['text']} [{row['ref']}]" for row in rows]
            out.append("")
    items = open_working(vault.root, args.session)
    if items:
        out.append("## Working Memory — open, short-horizon (not durable knowledge)\n")
        out += [f"- [{item['kind']}] {item['text']} (`{item['item_id']}`)" for item in items[:12]]
        out.append("")
    ruled = ruled_out_matches(vault, args.task)
    if ruled:
        out.append("## Already Ruled Out — tried before; do not retry without new evidence\n")
        out += ruled
        out.append("")
    done = completed_cues(vault, now, args.task)
    if done:
        out.append("## Completed Intentions — cue matched but already done\n")
        out += done
        out.append("")
    selected = [line.strip() for line in Path(args.selected).read_text(encoding="utf-8").splitlines() if line.strip()] if args.selected else []
    stored = active_labels(vault)
    if selected and stored:
        derived = derived_labels(vault)
        lines = []
        for ref in selected:
            names = [n for n in labels_for(vault, ref, stored, derived) if not n.startswith("state:")]
            if ref in stored and names:
                lines.append(f"- `{ref}`: {', '.join(names)}")
        if lines:
            out.append("## Lineage Labels — see `llm-brain lineage show` for where the decision changed\n")
            out += lines
            out.append("")
    if args.state_index:
        rows = state_rows(vault, now)
        if rows:
            out.append("## State Index — thin; open details with `llm-brain state open PROJECT KEY`\n")
            out += [f"- {row['key']}: {row['summary']} [{row['ref']}]" for row in rows[:40]]
            out.append("")
    if not selected:
        report = gate_report(vault, args.task, now)
        out.append(f"## Recall Gates — nothing selected (primary gate: {report['primary_gate']})\n")
        out += [f"- {gate}: {count} refused" for gate, count in report["gates"].items() if count]
        out.append(f"- Next step: {report['advice']}")
        out.append("")
    sys.stdout.write("\n".join(out) + ("\n" if out else ""))
    return 0


def command_brief_extras(args: argparse.Namespace) -> int:
    root = Path(args.project_dir).resolve()
    items = open_working(root)
    for item in items[:6]:
        print(f"- [{item['kind']}] {item['text']} ({item['item_id']})")
    return 0


# ------------------------------------------------- 0.10: history labels (#2)

def history_state(vault: Vault, path: Path, now: dt.datetime, derived: dict) -> tuple[str, str]:
    """(state, one-line label) for a record as of ``now``; deterministic and small."""
    rel = vault.rel(path)
    entries = derived.get(rel, [])
    for label, target, stamp in entries:
        when = parse_time(stamp)
        if label == "retracted" and (when is None or when <= now):
            return "retracted", f"RETRACTED{(' on ' + when.date().isoformat()) if when else ''} (`{target}`)"
    later = []
    for label, target, stamp in entries:
        when = parse_time(stamp)
        if label in ("superseded-by", "revised") and (when is None or when <= now):
            later.append((when or now, target))
    if later:
        when, target = sorted(later)[-1]
        tpath = vault.resolver.canonical_ref(target)
        title = _one(vault.title(tpath), 80) if tpath is not None else target
        return "historical", f"HISTORICAL, superseded by `{target}` ({title}) on {when.date().isoformat()}"
    meta = vault.meta(path)
    valid_to = parse_time(meta.get("brain_valid_to"))
    if valid_to is not None and valid_to <= now:
        return "expired", f"EXPIRED on {valid_to.date().isoformat()} (valid_to)"
    key = clean(meta.get("brain_state_key"))
    created = _created(vault, path)
    if key and created is not None:
        newer = []
        for other in vault.semantic_files():
            if other == path or clean(vault.meta(other).get("brain_state_key")) != key:
                continue
            if not vault.resolver.effective(other) or not vault.resolver.visible(other, strict_principal=True):
                continue
            when = _created(vault, other)
            if when is not None and created < when <= now:
                newer.append((when, vault.rel(other)))
        if newer:
            when, target = sorted(newer)[-1]
            # A shared state key is a hint, not a supersession: say so.
            return "older-value", f"OLDER VALUE for state `{key}`; newer record `{target}` on {when.date().isoformat()} (not an explicit supersession)"
    return "current", f"CURRENT as of {now.date().isoformat()}"


def command_history_states(args: argparse.Namespace) -> int:
    """Selected refs in observed-time order with their resolver state label."""
    vault = Vault(args.project_dir, args.principal)
    now = now_from(args.now)
    derived = derived_labels(vault)
    refs = [line.strip() for line in Path(args.selected).read_text(encoding="utf-8").splitlines() if line.strip()]
    rows = []
    for index, ref in enumerate(refs):
        path = vault.resolver.canonical_ref(ref)
        if path is None:
            rows.append((dt.datetime.max.replace(tzinfo=dt.timezone.utc), index, ref, "", "unknown"))
            continue
        state, label = history_state(vault, path, now, derived)
        created = _created(vault, path) or dt.datetime.max.replace(tzinfo=dt.timezone.utc)
        rows.append((created, index, ref, label, state))
    for created, _, ref, label, state in sorted(rows, key=lambda row: (row[0], row[1])):
        observed = "" if created.year == dt.MAXYEAR else iso(created)
        print(f"{ref}\t{observed}\t{state}\t{label}")
    return 0


# --------------------------------------------- 0.10: session handover (#3)

HANDOVER_LIMIT = 8


def handover_changes(vault: Vault, since: dt.datetime, now: dt.datetime, limit: int = HANDOVER_LIMIT) -> list[str]:
    """Approved changes visible to this principal since ``since``: new or
    re-verified records, supersessions and retractions.  Newest first."""
    events: list[tuple[dt.datetime, str]] = []
    seen: set[str] = set()
    derived = derived_labels(vault)
    for ref, entries in derived.items():
        for label, target, stamp in entries:
            when = parse_time(stamp)
            if when is None or not (since < when <= now):
                continue
            path = vault.resolver.canonical_ref(ref)
            title = _one(vault.title(path), 70) if path is not None else ref
            if label == "superseded-by":
                events.append((when, f"- {when.date().isoformat()} superseded: {title} → `{target}`"))
                seen.add(target)
            elif label == "retracted":
                events.append((when, f"- {when.date().isoformat()} retracted: {title} (`{ref}`)"))
    for path in vault.semantic_files():
        if not vault.eligible(path, now, include_cold=True):
            continue
        rel = vault.rel(path)
        if rel in seen:
            continue
        meta = vault.meta(path)
        times = [record_created(meta), parse_time(meta.get("brain_reviewed_at")), *ms.verification_times(meta)]
        changed = max([t for t in times if t is not None and since < t <= now], default=None)
        if changed is not None:
            events.append((changed, f"- {changed.date().isoformat()} new or re-verified: {_one(vault.title(path), 70)} (`{rel}`)"))
    events.sort(key=lambda item: (item[0], item[1]), reverse=True)
    lines = [line for _, line in events[:limit]]
    if len(events) > limit:
        lines.append(f"- … {len(events) - limit} more; run `llm-brain lineage show` or search for detail")
    return lines


def _touches(text: str) -> set[str]:
    found = {"path:" + match.group(1).strip("./") for match in ms.PATH_HINT_RE.finditer(text or "")}
    found |= {"state:" + match.group(1) for match in re.finditer(r"\bstate[:=]\s*([A-Za-z0-9_.-]+)", text or "")}
    return found


def handover_collisions(vault: Vault, session: str = "", limit: int = 6) -> list[str]:
    """Open work from other sessions/agents, flagging shared paths or state keys."""
    owners: dict[str, set[str]] = {}
    other: list[str] = []
    for item in open_working(vault.root):
        owner = item.get("session") or "-"
        for key in _touches(item.get("text", "")):
            owners.setdefault(key, set()).add(owner)
        if session and owner not in ("-", session):
            other.append(f"- [{owner}] {item['text']} (`{item['item_id']}`)")
    for path, meta, _ in vault.frontmatter_dir("intentions"):
        if meta.get("type") != "Intention" or (clean(meta.get("brain_intention_status")) or "open") != "open":
            continue
        scoped = ref_list(meta.get("brain_principal"))
        if scoped and vault.principal not in scoped:
            continue
        kind, value = clean(meta.get("brain_trigger_kind")), clean(meta.get("brain_trigger_value"))
        key = {"path": "path:" + value.strip("./"), "state": "state:" + value}.get(kind)
        if key:
            owners.setdefault(key, set()).add("intention:" + (clean(meta.get("brain_intention_id")) or path.stem))
    lines = [line for line in other[:limit]]
    for key in sorted(owners):
        if len(owners[key]) >= 2:
            lines.append(f"- COLLISION on `{key.split(':', 1)[1]}`: {', '.join(sorted(owners[key]))} — coordinate before editing")
    return lines[: limit + 4]


def command_handover(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    now = now_from(args.now)
    since = parse_time(args.since) if args.since else None
    if args.since and since is None:
        print("--since must be an ISO-8601 datetime with timezone", file=sys.stderr)
        return 64
    payload = {
        "status": "ok", "derived": True, "since": iso(since) if since else None,
        "changes": handover_changes(vault, since, now) if since else [],
        "others": handover_collisions(vault, args.session),
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
        return 0
    if since:
        print(f"Since your last session ({since.date().isoformat()}):")
        print("\n".join(payload["changes"]) or "- no approved changes")
    if payload["others"]:
        print("Other agents' open work here:")
        print("\n".join(payload["others"]))
    return 0


# ------------------------------------------- 0.10: already ruled out (#4)

RULED = Path("ruled-out") / "items.tsv"
RULED_HEADER = "event_id\trecorded_at\taction\titem_id\tprincipal\tscope\tapproach\treason\tevidence"


def read_ruled(root: Path) -> list[dict[str, str]]:
    path = root / RULED
    names = RULED_HEADER.split("\t")
    rows = []
    if path.is_file() and not path.is_symlink():
        for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines()):
            fields = line.split("\t")
            if number and len(fields) == len(names):
                rows.append(dict(zip(names, fields)))
    return rows


def open_ruled(vault: Vault) -> list[dict[str, str]]:
    """Active ruled-out items visible to the principal (reopen events applied)."""
    items: dict[str, dict[str, str]] = {}
    for row in read_ruled(vault.root):
        if row["action"] == "add":
            items[row["item_id"]] = dict(row)
        elif row["action"] == "reopen":
            items.pop(row["item_id"], None)
    visible = []
    for item in items.values():
        scope = item.get("principal", "-")
        if scope not in ("", "-") and scope != vault.principal:
            continue
        visible.append(item)
    return sorted(visible, key=lambda item: (item["recorded_at"], item["item_id"]))


def ruled_out_matches(vault: Vault, task: str, limit: int = 5) -> list[str]:
    wanted = set(_terms(task))
    if not wanted:
        return []
    scored = []
    for item in open_ruled(vault):
        terms = set(_terms(item["scope"] + " " + item["approach"]))
        overlap = len(wanted & terms)
        if terms and overlap >= min(2, len(terms)):
            evidence = f"; evidence `{item['evidence']}`" if item["evidence"] not in ("", "-") else ""
            scored.append((overlap, item["recorded_at"], f"- {item['approach']} — {item['reason']} ({item['recorded_at'][:10]}; `{item['item_id']}`{evidence})"))
    stored = active_labels(vault)
    for ref, labels in stored.items():
        if not any(name == "ruled-out" or name.startswith("ruled-out:") for name in labels):
            continue
        path = vault.resolver.canonical_ref(ref)
        if path is None or not vault.resolver.visible(path, strict_principal=True):
            continue
        terms = set(_terms(vault.title(path)))
        overlap = len(wanted & terms)
        if terms and overlap >= min(2, len(terms)):
            event = next(row for name, row in labels.items() if name.split(":", 1)[0] == "ruled-out")
            scored.append((overlap, event["recorded_at"], f"- {_one(vault.title(path), 100)} — {_one(event['reason'], 160)} (`{ref}`)"))
    scored.sort(key=lambda item: (-item[0], item[1]))
    return [line for _, _, line in scored[:limit]]


def command_ruled_out(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    now = iso(now_from(args.now))
    if args.action == "list":
        items = open_ruled(vault)
        if args.task:
            print("\n".join(ruled_out_matches(vault, args.task, args.limit)))
            return 0
        if args.json:
            print(json.dumps({"status": "ok", "items": items}, ensure_ascii=False, separators=(",", ":")))
            return 0
        print("item_id\trecorded_at\tscope\tapproach\treason\tevidence")
        for item in items:
            print(f"{item['item_id']}\t{item['recorded_at']}\t{item['scope']}\t{item['approach']}\t{item['reason']}\t{item['evidence']}")
        return 0
    if args.action == "add":
        if not args.approach.strip() or not args.reason.strip():
            print("ruled-out add needs --approach and --reason", file=sys.stderr)
            return 64
        item_id = "ro_" + _sha(f"{args.scope}|{args.approach}|{args.principal}")[:12]
        if any(item["item_id"] == item_id for item in open_ruled(vault)):
            print(f"ruled-out=unchanged item_id={item_id}")
            return 0
        fields = [now, "add", item_id, _one(args.principal, 80) or "-", _one(args.scope, 200) or "-",
                  _one(args.approach, 240), _one(args.reason, 300), _one(args.evidence, 200) or "-"]
    else:
        if args.item not in {item["item_id"] for item in open_ruled(vault)}:
            print(f"ruled-out item is not active: {args.item}", file=sys.stderr)
            return 65
        item_id = args.item
        fields = [now, "reopen", item_id, _one(args.principal, 80) or "-", "-", "-", _one(args.reason or "reopened", 300), "-"]
    path = vault.root / RULED
    path.parent.mkdir(parents=True, exist_ok=True)
    new = not path.exists()
    with path.open("a", encoding="utf-8") as stream:
        if new:
            stream.write(RULED_HEADER + "\n")
        stream.write("\t".join([_sha("|".join(fields))[:16]] + fields) + "\n")
    print(f"ruled-out={args.action} item_id={item_id}")
    return 0


def command_recall_extras(args: argparse.Namespace) -> int:
    """Small add-on for bridge recall (Hermes/MCP): ruled-out approaches only."""
    vault = Vault(args.project_dir, args.principal)
    lines = ruled_out_matches(vault, args.task, 4)
    if lines:
        print("\n### Already ruled out — do not retry without new evidence\n")
        print("\n".join(lines))
    return 0


# ------------------------------------------- 0.10: forgotten saves (#5)

def forgotten_report(vault: Vault, now: dt.datetime, days: int = 30, limit: int = 20) -> dict[str, Any]:
    """Saved-but-never-recalled records and requests with no update in ``days``.

    "Never recalled" needs usage evidence: retrieval receipts are opt-in
    (``--receipt`` or ``LLM_BRAIN_RECEIPTS=1``).  Without any receipts the
    report says so instead of calling every record forgotten.
    """
    table, receipts = ms.usage_table(vault)
    never: list[dict[str, str]] = []
    if receipts:
        for path in vault.semantic_files():
            if not vault.eligible(path, now, include_cold=True):
                continue
            rel = vault.rel(path)
            entry = table.get(rel)
            if entry and (entry["uses"] or entry["rendered"]):
                continue
            created = _created(vault, path)
            if created is not None and (now - created).days < days:
                continue
            never.append({"ref": rel, "title": _one(vault.title(path), 100), "saved": iso(created) if created else ""})
    stale: list[dict[str, str]] = []
    for path, meta, _ in vault.frontmatter_dir("intentions"):
        if meta.get("type") != "Intention" or (clean(meta.get("brain_intention_status")) or "open") != "open":
            continue
        scoped = ref_list(meta.get("brain_principal"))
        if scoped and vault.principal not in scoped:
            continue
        iid = clean(meta.get("brain_intention_id")) or path.stem
        times = [parse_time(meta.get("brain_created_at")), parse_time(meta.get("brain_last_fired_at"))]
        times += [parse_time(row[0]) for row in patches(vault.root, iid) if row]
        last = max([t for t in times if t is not None], default=None)
        if last is not None and (now - last).days >= days:
            stale.append({"id": iid, "kind": "intention", "text": _one(meta.get("brain_intention_action"), 120), "last_update": iso(last)})
    for item in open_working(vault.root):
        last = parse_time(item.get("recorded_at"))
        if last is not None and (now - last).days >= days:
            stale.append({"id": item["item_id"], "kind": "working", "text": _one(item.get("text"), 120), "last_update": iso(last)})
    never.sort(key=lambda row: (row["saved"], row["ref"]))
    stale.sort(key=lambda row: (row["last_update"], row["id"]))
    return {
        "status": "ok", "derived": True, "days": days, "receipts": receipts,
        "usage_evidence": "receipts" if receipts else "none (receipts are opt-in: --receipt or LLM_BRAIN_RECEIPTS=1)",
        "never_recalled_count": len(never), "never_recalled": never[:limit],
        "stale_requests_count": len(stale), "stale_requests": stale[:limit],
    }


def command_forgotten(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    report = forgotten_report(vault, now_from(args.now), args.days, args.limit)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, separators=(",", ":")))
        return 0
    print(f"forgotten=ok days={args.days} receipts={report['receipts']} never_recalled={report['never_recalled_count']} stale_requests={report['stale_requests_count']}")
    if not report["receipts"]:
        print(f"usage evidence: {report['usage_evidence']}")
    for row in report["never_recalled"]:
        print(f"never-recalled\t{row['ref']}\t{row['saved'][:10]}\t{row['title']}")
    for row in report["stale_requests"]:
        print(f"stale-{row['kind']}\t{row['id']}\t{row['last_update'][:10]}\t{row['text']}")
    return 0


# ------------------------------------- 0.10: silent-failure health (#6)

RESERVED_BODY_KEYS = re.compile(r"^(brain_[a-z_]+|verified|generated)\s*:", re.M)
HUMAN_CLAIM = re.compile(r"\b(human[- ]verified|verified by (?:a )?human|human[- ]approved)\b", re.I)
HEALTH_WEIGHTS = {
    "broken-frontmatter": (10, 40), "smuggled-frontmatter": (10, 30), "unproven-human-verification": (8, 24),
    "dropped-host-config": (15, 30), "mass-rewrite": (10, 10), "near-duplicate-name": (2, 20),
    "state-key-near-collision": (3, 15),
}


def _norm_name(text: str) -> str:
    text = re.sub(r"(?i)[ _-]*(copy|final|new|old|\(\d+\)|v\d+)$", "", text)
    return re.sub(r"[^a-z0-9]", "", text.lower())


def _close(a: str, b: str) -> bool:
    import difflib
    return a == b or (min(len(a), len(b)) >= 8 and difflib.SequenceMatcher(None, a, b).ratio() >= 0.92)


def health_findings(root: Path, host_configs: list[str]) -> list[tuple[str, str, str, str]]:
    findings: list[tuple[str, str, str, str]] = []
    # Records live in okf/<kind>/; okf/log.md and okf/index.md are generated maps.
    files = sorted(p for p in (root / "okf").glob("*/**/*.md") if p.is_file() and not p.is_symlink()) if (root / "okf").is_dir() else []
    parsed: list[tuple[Path, dict[str, Any], str]] = []
    for path in files:
        rel = path.relative_to(root).as_posix()
        try:
            meta, body = okf.split_frontmatter(path)
        except okf.OkfError as exc:
            findings.append(("broken-frontmatter", rel, _one(str(exc), 120), "fix the YAML header; the record is invisible to recall"))
            continue
        parsed.append((path, meta, body))
        # A second '---' block in the body that carries reserved keys looks
        # like frontmatter to naive readers and can smuggle authority.
        for block in re.findall(r"(?ms)^---[ \t]*\n(.*?)^---[ \t]*$", body):
            keys = RESERVED_BODY_KEYS.findall(block)
            if keys:
                findings.append(("smuggled-frontmatter", rel, "body block sets " + ",".join(sorted(set(keys))[:4]), "remove the body block or move the fields into the real header"))
                break
        generated = meta.get("generated") if isinstance(meta.get("generated"), dict) else {}
        verified = meta.get("verified") if isinstance(meta.get("verified"), dict) else {}
        author = clean(generated.get("by"))
        human_author = author.startswith("human:")
        reviewed_by = clean(meta.get("brain_reviewed_by"))
        if not human_author and not reviewed_by.startswith("human:"):
            if clean(verified.get("by")).startswith("human:"):
                findings.append(("unproven-human-verification", rel, f"verified.by={clean(verified.get('by'))} but written by {author or 'unknown'}", "confirm with the person or drop the claim"))
            elif HUMAN_CLAIM.search(body):
                findings.append(("unproven-human-verification", rel, f"body claims human verification; written by {author or 'unknown'}", "confirm with the person or drop the claim"))
    # Records already linked by a lifecycle relation (v1 -> v2) are versions, not duplicates.
    linked: set[tuple[str, str]] = set()
    for path, meta, _ in parsed:
        for field in ms.RELATION_FIELDS:
            for ref in ref_list(meta.get(field)):
                target = ref if ref.startswith("okf/") else f"{path.parent.relative_to(root).as_posix()}/{ref.removesuffix('.md')}.md"
                rel = path.relative_to(root).as_posix()
                linked.add((rel, target))
                linked.add((target, rel))
    # Near-name duplicate files in the same folder.
    by_folder: dict[Path, list[Path]] = {}
    for path in files:
        by_folder.setdefault(path.parent, []).append(path)
    for folder, members in sorted(by_folder.items()):
        names = [(path, _norm_name(path.stem)) for path in members]
        buckets: dict[str, list[tuple[Path, str]]] = {}
        for path, name in names:
            buckets.setdefault(name[:5], []).append((path, name))
        for bucket in buckets.values():
            if len(bucket) > 200:
                continue
            for index, (left, a) in enumerate(bucket):
                for right, b2 in bucket[index + 1:]:
                    pair = (left.relative_to(root).as_posix(), right.relative_to(root).as_posix())
                    if a and _close(a, b2) and pair not in linked:
                        findings.append(("near-duplicate-name", left.relative_to(root).as_posix(), f"~{right.relative_to(root).as_posix()}", "merge or supersede one of them"))
    # Distinct state keys that are almost the same key.
    keys = sorted({clean(meta.get("brain_state_key")) for _, meta, _ in parsed if clean(meta.get("brain_state_key"))})
    normalised = [(key, re.sub(r"[^a-z0-9]", "", key.lower())) for key in keys]
    for index, (a, na) in enumerate(normalised):
        for b2, nb in normalised[index + 1:]:
            if na == nb or (min(len(na), len(nb)) >= 6 and _close(na, nb)):
                findings.append(("state-key-near-collision", f"state:{a}", f"~state:{b2}", "use one state key so updates resolve"))
    # Mass rewrite: most canonical files share one modification minute.
    if len(files) >= 20:
        minutes: dict[int, int] = {}
        for path in files:
            minute = int(path.stat().st_mtime // 60)
            minutes[minute] = minutes.get(minute, 0) + 1
        minute, count = max(minutes.items(), key=lambda item: (item[1], item[0]))
        if count >= 20 and count >= 0.8 * len(files):
            when = dt.datetime.fromtimestamp(minute * 60, dt.timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
            findings.append(("mass-rewrite", "okf/", f"{count}/{len(files)} files modified at {when}", "check for a sync or tool that rewrote the vault; do not trust mtimes"))
    for config in host_configs:
        path = Path(config).expanduser()
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if "llm-brain" not in text and "llm_brain" not in text:
            findings.append(("dropped-host-config", str(path), "host config no longer declares llm-brain (MCP, hook or plugin)", "re-run the host install or re-add the llm-brain entry"))
    return findings


def health_score(findings: list[tuple[str, str, str, str]]) -> int:
    penalty: dict[str, int] = {}
    for category, *_ in findings:
        weight, cap = HEALTH_WEIGHTS.get(category, (2, 10))
        penalty[category] = min(cap, penalty.get(category, 0) + weight)
    return max(0, 100 - sum(penalty.values()))


def default_host_configs() -> list[str]:
    home = Path(os.environ.get("HOME", "~")).expanduser()
    hermes = Path(os.environ.get("HERMES_HOME", str(home / ".hermes")))
    return [str(hermes / "config.yaml"), str(home / ".codex" / "config.toml"), str(home / ".claude" / "settings.json"), str(home / ".gemini" / "settings.json")]


def command_health(args: argparse.Namespace) -> int:
    root = Path(args.project_dir).resolve()
    hosts = list(args.host_config or [])
    if args.hosts == "auto":
        hosts += default_host_configs()
    findings = sorted(set(health_findings(root, hosts)))
    score = health_score(findings)
    if args.json:
        print(json.dumps({"status": "ok", "derived": True, "score": score, "findings": [
            {"category": c, "ref": r, "detail": d, "recommendation": a} for c, r, d, a in findings]}, ensure_ascii=False, separators=(",", ":")))
    else:
        print("category\tref\tdetail\trecommendation")
        for row in findings:
            print("\t".join(row))
        print(f"health_score={score}")
    return 0 if args.fail_under is None or score >= args.fail_under else 1


# ------------------------------------------- 0.10: capture tags (#7)

CAPTURE_TAGS = ("fact", "hypothetical", "proposal")
HYPOTHETICAL_RE = re.compile(r"\b(what if|suppose|supposing|hypothetical(?:ly)?|imagine|imagining|in a simulation|simulated (?:run|result|outcome)s?|would happen if|assuming (?:that|we)|if we were to|thought experiment)\b", re.I)
PROPOSAL_RE = re.compile(r"\b(i (?:suggest|propose|recommend)|we (?:could|might) (?:try|use|switch|add|move)|we should consider|let'?s (?:try|use|switch|add|move|go with)|shall we|how about|proposal:|proposed plan|draft plan|one option is|option [0-9a-c]\b|consider (?:using|switching|adding|moving))", re.I)


def capture_tag(meta: dict[str, Any], body: str) -> tuple[str, str]:
    """Deterministic fact/hypothetical/proposal tag for a capture candidate."""
    declared = clean(meta.get("brain_capture_tag")).lower()
    if declared in CAPTURE_TAGS:
        return declared, "declared"
    if clean(meta.get("brain_grounding")).lower() == "unacknowledged":
        return "proposal", "grounding:unacknowledged"
    statement = ""
    match = re.search(r"^Candidate statement:\s*(.+)$", body or "", re.M)
    text = f"{clean(meta.get('title'))}\n{match.group(1) if match else (body or '')[:600]}"
    hit = HYPOTHETICAL_RE.search(text)
    if hit:
        return "hypothetical", f"cue:{hit.group(1).lower()}"
    hit = PROPOSAL_RE.search(text)
    if hit:
        return "proposal", f"cue:{hit.group(1).lower()}"
    return "fact", "default"


def command_capture_tag(args: argparse.Namespace) -> int:
    try:
        meta, body = okf.split_frontmatter(Path(args.file))
    except okf.OkfError as exc:
        print(f"capture-tag: {exc}", file=sys.stderr)
        return 65
    tag, why = capture_tag(meta, body)
    print(f"{tag}\t{why}")
    return 0


# ------------------------------------------- 0.10: sticky forgetting (#10)

def forget_neighbours(vault: Vault, ref: str, threshold: float = 0.5) -> list[tuple[str, str]]:
    """Records from which a retracted record could be inferred: relation links
    in either direction, association partners, a shared state key, or a body
    that restates most of the target.  Visible records only."""
    target = vault.resolver.canonical_ref(ref)
    if target is None:
        return []
    trel = vault.rel(target)
    tmeta = vault.meta(target)
    tkey = clean(tmeta.get("brain_state_key"))
    tshingles = ms.shingles(ms.TOKEN_RE.findall(re.sub(r"\A\s*# [^\n]*\n", "", vault.body(target)).lower()))
    out: dict[str, str] = {}
    for field in ms.RELATION_FIELDS:
        for linked in ref_list(tmeta.get(field)):
            path = vault.resolver.canonical_ref(linked)
            if path is not None and path != target and vault.resolver.visible(path, strict_principal=True):
                out.setdefault(vault.rel(path), f"linked-by-{field.removeprefix('brain_')}")
    for path in vault.semantic_files():
        if path == target or not vault.resolver.visible(path, strict_principal=True):
            continue
        rel = vault.rel(path)
        meta = vault.meta(path)
        for field in ms.RELATION_FIELDS:
            if any(vault.resolver.canonical_ref(item) == target for item in ref_list(meta.get(field))):
                out.setdefault(rel, f"links-via-{field.removeprefix('brain_')}")
        if tkey and clean(meta.get("brain_state_key")) == tkey:
            out.setdefault(rel, f"same-state-key:{tkey}")
        if len(tshingles) >= 4:
            other = ms.shingles(ms.TOKEN_RE.findall(re.sub(r"\A\s*# [^\n]*\n", "", vault.body(path)).lower()))
            if other and len(tshingles & other) / len(tshingles) >= threshold:
                out.setdefault(rel, f"restates-{len(tshingles & other) * 100 // len(tshingles)}pct")
    for _, meta, _ in vault.frontmatter_dir("projections"):
        if meta.get("type") != "AssociativeProjection" or clean(meta.get("brain_projection_state")) != "active":
            continue
        a, b2 = clean(meta.get("brain_association_a")), clean(meta.get("brain_association_b"))
        other = b2 if a == trel else a if b2 == trel else ""
        path = vault.resolver.canonical_ref(other) if other else None
        if path is not None and vault.resolver.visible(path, strict_principal=True):
            out.setdefault(vault.rel(path), "association")
    return sorted(out.items())


def command_forget_neighbours(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    for rel, why in forget_neighbours(vault, args.ref):
        print(f"{rel}\t{why}")
    return 0


# ------------------------------------------------- #11 careful belief updates

BELIEF_MIN_SUPPORT = 2  # a fact with this many independent sources is "well supported"


def _source_key(meta: dict[str, Any], fallback: str) -> str:
    for field in ("brain_source_ref", "brain_provenance"):
        value = clean(meta.get(field))
        if value:
            return value
    return fallback


def belief_support(vault: Vault, target: Path) -> list[str]:
    """Independent sources behind an effective fact: its own source, every
    effective record that supports it (distinct sources only), and a human
    verification.  Deterministic, frontmatter only."""
    trel = vault.rel(target)
    tmeta = vault.meta(target)
    keys = {_source_key(tmeta, trel)}
    verified = tmeta.get("verified")
    if isinstance(verified, dict) and str(verified.get("by", "")).startswith("human:"):
        keys.add("human-verification")
    superseded = vault.superseded()
    for path in vault.semantic_files():
        if path == target or path in superseded or not vault.resolver.effective(path):
            continue
        meta = vault.meta(path)
        if any(vault.resolver.canonical_ref(item) == target for item in ref_list(meta.get("brain_supports"))):
            keys.add(_source_key(meta, vault.rel(path)))
    return sorted(keys)


def belief_check(vault: Vault, review: Path) -> dict[str, Any]:
    """Would promoting this review item overwrite a well-supported fact on the
    strength of fewer independent sources?  Challengers are the item itself
    plus open review items that supersede or re-version the same target."""
    meta, _ = okf.split_frontmatter(review)
    out: dict[str, Any] = {"verdict": "ok", "target": "", "support": 0, "challengers": 0, "needed": 0, "corroborating": []}
    targets = []
    for field in ("brain_supersedes", "brain_version_of"):
        for ref in ref_list(meta.get(field)):
            path = vault.resolver.canonical_ref(ref)
            if path is not None and vault.resolver.effective(path) and path not in vault.superseded():
                targets.append(path)
    if not targets:
        return out
    try:
        minimum = max(1, int(os.environ.get("LLM_BRAIN_BELIEF_MIN_SUPPORT", BELIEF_MIN_SUPPORT)))
    except ValueError:
        minimum = BELIEF_MIN_SUPPORT
    worst: dict[str, Any] | None = None
    for target in targets:
        support = belief_support(vault, target)
        keys = {_source_key(meta, review.name)}
        corroborating = []
        for other in sorted((vault.root / "review").glob("*.md")):
            if other == review:
                continue
            try:
                ometa, _ = okf.split_frontmatter(other)
            except okf.OkfError:
                continue
            if clean(ometa.get("brain_review_state")) not in {"proposed", "needs-validation"}:
                continue
            if clean(ometa.get("brain_review_kind")) not in {"claim", "procedure", "reference"}:
                continue
            refs = ref_list(ometa.get("brain_supersedes")) + ref_list(ometa.get("brain_version_of"))
            if any(vault.resolver.canonical_ref(item) == target for item in refs):
                key = _source_key(ometa, other.name)
                if key not in keys:
                    keys.add(key)
                    corroborating.append(other.stem)
        row = {"target": vault.rel(target), "support": len(support), "challengers": len(keys),
               "needed": len(support), "corroborating": corroborating,
               "verdict": "hold" if len(support) >= minimum and len(keys) < len(support) else "ok"}
        if worst is None or (row["verdict"] == "hold" and worst["verdict"] != "hold"):
            worst = row
    return worst or out


def command_belief_check(args: argparse.Namespace) -> int:
    vault = Vault(args.project_dir, args.principal)
    row = belief_check(vault, Path(args.review))
    if args.json:
        print(json.dumps(row, sort_keys=True))
    else:
        print("\t".join([row["verdict"], row["target"], str(row["support"]), str(row["challengers"]), str(row["needed"]), ",".join(row["corroborating"])]))
    return 0


# --------------------------------------------------------------- parser

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

    lv = commands.add_parser("label-validate")
    lv.add_argument("label")
    lv.set_defaults(func=command_label_validate)
    la = base("label-append", command_label_append)
    la.add_argument("--action", choices=("label", "unlabel"), required=True)
    la.add_argument("--ref", required=True)
    la.add_argument("--label", required=True)
    la.add_argument("--target", default="")
    la.add_argument("--actor", default="operator")
    la.add_argument("--reason", required=True)
    ll = base("labels", command_labels)
    ll.add_argument("--ref", default="")
    ll.add_argument("--label", default="")
    ll.add_argument("--json", action="store_true")
    lf = base("label-filter", command_label_filter)
    lf.add_argument("--ranked", required=True)
    lf.add_argument("--with-label", action="append")
    lf.add_argument("--without-label", action="append")
    ln = base("lineage", command_lineage)
    ln.add_argument("--ref", default="")
    ln.add_argument("--topic", default="")
    ln.add_argument("--decision", default="")
    ln.add_argument("--json", action="store_true")
    inv = base("invalidate", command_invalidate)
    inv.add_argument("--trigger", required=True)
    inv.add_argument("--max-depth", type=int, default=3)
    inv.add_argument("--json", action="store_true")
    rc = base("recency", command_recency)
    rc.add_argument("--ranked", required=True)
    rc.add_argument("--half-life-days", type=float, default=7.0)
    rc.add_argument("--peak", type=float, default=1.5)
    rc.add_argument("--floor", type=float, default=0.7)
    gt = base("gates", command_gates)
    gt.add_argument("--query", required=True)
    gt.add_argument("--json", action="store_true")
    gt.add_argument("--metadata", action="store_true")
    sf = base("sufficiency", command_sufficiency)
    sf.add_argument("--query", required=True)
    sf.add_argument("--batch", type=int, default=3)
    sf.add_argument("--max", type=int, default=15)
    sf.add_argument("--target", type=float, default=0.8)
    sf.add_argument("--json", action="store_true")
    sf.add_argument("--count-only", action="store_true")
    sm = base("summaries", command_summaries)
    sm.add_argument("--action", choices=("build", "show"), required=True)
    sm.add_argument("--folder", default="")
    st = base("state", command_state)
    st.add_argument("--action", choices=("index", "open"), required=True)
    st.add_argument("--key", default="")
    st.add_argument("--since", default="")
    st.add_argument("--changes-only", action="store_true")
    wk = base("working", command_working)
    wk.add_argument("--action", choices=("add", "list", "done", "drop"), required=True)
    wk.add_argument("--text", default="")
    wk.add_argument("--kind", default="todo")
    wk.add_argument("--session", default="")
    wk.add_argument("--item", default="")
    wk.add_argument("--status", default="open", choices=("open", "all"))
    wk.add_argument("--json", action="store_true")
    cs = base("constraints", command_constraints)
    cs.add_argument("--turn", type=int, default=0)
    cs.add_argument("--every", type=int, default=8)
    ip = base("intention-patch", command_intention_patch)
    ip.add_argument("--intention-id", required=True)
    ip.add_argument("--patch", choices=("reschedule", "override", "cancel", "quiet", "decide"), required=True)
    ip.add_argument("--old", default="")
    ip.add_argument("--new", default="")
    ip.add_argument("--reason", default="")
    bd = base("board", command_board)
    bd.add_argument("--task", default="")
    ob = base("observe", command_observe)
    ob.add_argument("--within-days", type=float, default=7.0)
    pe = base("pack-extras", command_pack_extras)
    pe.add_argument("--task", default="")
    pe.add_argument("--selected", default="")
    pe.add_argument("--turn", type=int, default=0)
    pe.add_argument("--every", type=int, default=8)
    pe.add_argument("--session", default="")
    pe.add_argument("--state-index", action="store_true")
    base("brief-extras", command_brief_extras)
    ro = base("ruled-out", command_ruled_out)
    ro.add_argument("--action", choices=("add", "reopen", "list"), required=True)
    ro.add_argument("--approach", default="")
    ro.add_argument("--reason", default="")
    ro.add_argument("--scope", default="")
    ro.add_argument("--evidence", default="")
    ro.add_argument("--item", default="")
    ro.add_argument("--task", default="")
    ro.add_argument("--limit", type=int, default=5)
    ro.add_argument("--json", action="store_true")
    rx = base("recall-extras", command_recall_extras)
    rx.add_argument("--task", default="")
    fg = base("forgotten", command_forgotten)
    fg.add_argument("--days", type=int, default=30)
    fg.add_argument("--limit", type=int, default=20)
    fg.add_argument("--json", action="store_true")
    hl = base("health", command_health)
    hl.add_argument("--host-config", action="append")
    hl.add_argument("--hosts", choices=("none", "auto"), default="none")
    hl.add_argument("--fail-under", type=int, default=None)
    hl.add_argument("--json", action="store_true")
    ct = commands.add_parser("capture-tag")
    ct.add_argument("--file", required=True)
    ct.set_defaults(func=command_capture_tag)
    bc = base("belief-check", command_belief_check)
    bc.add_argument("--review", required=True)
    bc.add_argument("--json", action="store_true")
    fn = base("forget-neighbours", command_forget_neighbours)
    fn.add_argument("--ref", required=True)
    ho = base("handover", command_handover)
    ho.add_argument("--since", default="")
    ho.add_argument("--session", default="")
    ho.add_argument("--json", action="store_true")
    hs = base("history-states", command_history_states)
    hs.add_argument("--selected", required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        return int(args.func(args))
    except okf.OkfError as exc:
        print(f"memory-lineage:error {exc}", file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())
