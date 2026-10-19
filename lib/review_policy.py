#!/usr/bin/env python3
"""Tiered review policy and backlog sweep for LLM-Brain (0.11).

Reads and edits only ``PROJECT/review/*.md`` (maxdepth 1) of one project at a
time; the caller (bin/llm-brain) holds the project lock.  Every change is
labelled, written to a per-run manifest with the prior bytes (except for
secret-matched files, whose secret spans are never copied) and recorded as a
hash-chained ``audit.v2.tsv`` row identical in format to ``audit_v2``.

Output is counts and opaque ids only: no titles, bodies or secret values.
Review text is untrusted data; nothing in a body can change its tier.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import math
import os
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

SECRET = re.compile(
    r'-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-(proj-)?[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}'
    r'|xox[baprs]-[A-Za-z0-9-]{10,}|(api[_-]?key|secret|password|token)[ \t\f\v]*[:=][ \t\f\v]*"?[A-Za-z0-9_./+=-]{16,}',
    re.I,
)
# Same scaffold lines that `migrate apply` supersedes (is_scaffold_content).
SCAFFOLD = re.compile(
    r'^Candidate statement: source .* was ingested into episodic memory|^Candidate statement: source context for '
    r'|^Review whether this episode contains a reusable workflow before promotion\.',
    re.M,
)
# Held whatever their confidence: security and operations topics.  Strong
# terms anywhere in the file hold; weaker operations words hold only when they
# are the topic (title, tags or labels), so "deploy" in a sentence is no veto.
HOLD_ANYWHERE = re.compile(r'security|authenticat|credential|secret|password|private key|\bssh\b')
HOLD_TOPIC = re.compile(r'production|deploy|migration|infrastructure|firewall|\bauth\b|\bskill\b|adapter')
PERSONAL_TOPIC = re.compile(r'health|clinical|medical|medication|privacy|private life|legal|lawyer|finance|financial|payment|tax\b|bank')
TRUSTED = {"human-directive", "repository", "runtime-proof", "approved-canonical"}
CANDIDATE_AUTHORITY = TRUSTED | {"source", "provider"}
OPEN_STATES = {"proposed", "needs-validation", "draft"}
RUN_ID = re.compile(r'^sweep_[0-9]{8}T[0-9]{6}Z_[0-9a-f]{6}$|^closeout_[0-9]{8}T[0-9]{6}Z_[0-9a-f]{6}$')
TIERS = ("CLOSE-custody", "CLOSE-legacy", "CLOSE-duplicate", "AUTO-cooloff", "AUTO-private", "PARK", "HOLD", "FLAG-secret", "FLAG-redaction", "WAIT")
# tier -> (new state, reason) for the tiers the sweep writes itself.
ACTIONS = {
    "CLOSE-custody": ("captured", "custody-marker"),
    "CLOSE-legacy": ("superseded", "legacy-scaffold"),
    "CLOSE-duplicate": ("superseded", "duplicate"),
    "PARK": ("parked", None),
    "FLAG-secret": ("needs-validation", "redacted-secret"),
}


class Settings:
    def __init__(self, env: Dict[str, str]):
        self.policy = env.get("LLM_BRAIN_REVIEW_POLICY", "tiered")
        if self.policy not in ("tiered", "strict"):
            raise SystemExit("LLM_BRAIN_REVIEW_POLICY must be tiered or strict")
        self.cooloff_hours = _number(env, "LLM_BRAIN_REVIEW_COOLOFF_HOURS", 24.0, 0, 24 * 365)
        self.min_confidence = _number(env, "LLM_BRAIN_REVIEW_MIN_CONFIDENCE", 0.80, 0.5, 1.0)
        self.park_days = _number(env, "LLM_BRAIN_REVIEW_PARK_DAYS", 90.0, 1, 3650)
        self.personal = env.get("LLM_BRAIN_REVIEW_PERSONAL", "private")
        if self.personal not in ("private", "hold"):
            raise SystemExit("LLM_BRAIN_REVIEW_PERSONAL must be private or hold")


def _number(env: Dict[str, str], key: str, default: float, low: float, high: float) -> float:
    raw = env.get(key, "")
    if raw == "":
        return default
    try:
        value = float(raw)
    except ValueError:
        raise SystemExit(f"{key} must be a number")
    if not (low <= value <= high) or math.isnan(value):
        raise SystemExit(f"{key} must be between {low:g} and {high:g}")
    return value


def now_utc() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def split_frontmatter(text: str) -> Tuple[Optional[List[str]], str]:
    """Mirror frontmatter_field: header starts at line 1 == '---' and ends at the next line == '---'."""
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return None, text
    for index in range(1, len(lines)):
        if lines[index] == "---":
            return lines[1:index], "\n".join(lines[index + 1:])
    return None, text


def parse_header(header: List[str]) -> Tuple[Dict[str, str], bool]:
    meta: Dict[str, str] = {}
    duplicate = False
    for line in header:
        colon = line.find(":")
        if colon <= 0:
            continue
        key = line[:colon]
        value = line[colon + 1:].strip()
        if value.startswith('"'):
            value = value[1:]
        if value.endswith('"'):
            value = value[:-1]
        if key in meta:
            duplicate = duplicate or key.startswith("brain_") or key in ("type", "title")
            continue  # first occurrence wins, as in frontmatter_field
        meta[key] = value
    return meta, duplicate


def set_fields(text: str, fields: List[Tuple[str, str]]) -> str:
    """Same semantics as set_frontmatter_field applied in order."""
    for key, value in fields:
        if "\n" in value or "\r" in value or "\t" in value:
            raise ValueError("invalid scalar value")
        lines = text.split("\n")
        out = [lines[0]]
        in_header, seen = True, False
        for line in lines[1:]:
            if in_header and line == "---":
                if not seen:
                    out.append(f"{key}: {value}")
                out.append(line)
                in_header = False
                continue
            if in_header and line.startswith(key + ":"):
                out.append(f"{key}: {value}")
                seen = True
                continue
            out.append(line)
        text = "\n".join(out)
    return text


def age_days(stamp: str, now: _dt.datetime) -> Optional[float]:
    try:
        moment = _dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=_dt.timezone.utc)
    return (now - moment).total_seconds() / 86400.0


class Project:
    def __init__(self, project_dir: Path):
        self.dir = project_dir
        self._episodes: Optional[Dict[str, Dict[str, str]]] = None
        self._canonical: Optional[set] = None

    def episodes(self) -> Dict[str, Dict[str, str]]:
        if self._episodes is None:
            self._episodes = {}
            base = self.dir / "episodes"
            if base.is_dir():
                for path in base.rglob("*.md"):
                    if path.is_symlink():
                        continue
                    try:
                        head = path.read_text(encoding="utf-8", errors="replace")[:4096]
                    except OSError:
                        continue
                    header, _ = split_frontmatter(head)
                    if header is None:
                        continue
                    meta, _ = parse_header(header)
                    if meta.get("brain_episode_id"):
                        self._episodes.setdefault(meta["brain_episode_id"], meta)
        return self._episodes

    def canonical(self) -> set:
        if self._canonical is None:
            self._canonical = set()
            for sub in ("claims", "computations", "procedures", "references", "topics"):
                base = self.dir / "okf" / sub
                if base.is_dir():
                    for path in base.glob("*.md"):
                        if not (self.dir / "okf" / "retractions" / path.name).exists():
                            self._canonical.add(f"{sub}/{path.stem}")
        return self._canonical

    def provenance_resolves(self, meta: Dict[str, str]) -> bool:
        provenance = meta.get("brain_provenance", "")
        authority = meta.get("brain_source_authority", "")
        if provenance.startswith("episode://"):
            episode = self.episodes().get(provenance[len("episode://"):])
            if not episode:
                return False
            ref = episode.get("brain_source_ref", "")
            expected = episode.get("brain_source_hash_sha256") or episode.get("brain_source_hash", "")
            if not ref.startswith("sources/") or ".." in ref:
                return False
            source = self.dir / ref
            sidecar = Path(str(source) + ".sha256")
            if not source.is_file() or not sidecar.is_file():
                return False
            try:
                actual = sha256_bytes(source.read_bytes())
                recorded = sidecar.read_text(encoding="utf-8").split()[0]
            except (OSError, IndexError):
                return False
            return actual == expected and recorded == expected
        if provenance.startswith("okf://"):
            return provenance[len("okf://"):] in self.canonical()
        if provenance.startswith(("human://", "runtime://")):
            return authority in ("human-directive", "runtime-proof")
        return False


class Item:
    def __init__(self, path: Path, raw: bytes):
        self.path = path
        self.id = path.stem
        self.raw = raw
        self.text = raw.decode("utf-8", errors="replace")
        header, self.body = split_frontmatter(self.text)
        self.valid = header is not None
        self.meta, self.duplicate_keys = parse_header(header or [])
        self.state = self.meta.get("brain_review_state") or self.meta.get("review_state") or "none"
        self.kind = self.meta.get("brain_review_kind") or "none"
        normal = re.sub(r"^#.*$", "", self.body, flags=re.M)
        self.body_hash = sha256_bytes(re.sub(r"\s+", " ", normal).strip().lower().encode())

    def topic_text(self) -> str:
        parts = [self.meta.get(key, "") for key in ("title", "brain_topic", "brain_topic_labels", "brain_labels", "brain_tags", "tags")]
        return " ".join(parts).lower()


def classify(item: Item, project: Project, settings: Settings, now: _dt.datetime, first_body: Dict[str, str]) -> Tuple[str, str]:
    """Return (tier, reason).  Order matters: protections run before any close or promotion."""
    meta = item.meta
    if not item.valid or item.duplicate_keys:
        return "HOLD", "malformed-frontmatter"
    if SECRET.search(item.text):
        return "FLAG-secret", "secret-like"
    kind = item.kind
    if kind == "redaction":
        return "FLAG-redaction", "redaction"
    if kind == "source-ingest":
        return "CLOSE-custody", "custody-marker"
    if kind in ("claim", "procedure") and SCAFFOLD.search(item.body):
        return "CLOSE-legacy", "legacy-scaffold"
    if kind not in ("claim", "procedure", "reference"):
        return "HOLD", "kind-" + re.sub(r"[^a-z0-9-]", "-", kind.lower())[:32]
    first = first_body.get(item.body_hash)
    if first and first != item.id:
        return "CLOSE-duplicate", "duplicate"
    tag = meta.get("brain_capture_tag", "")
    if tag in ("hypothetical", "proposal"):
        return "PARK", "tag-" + tag
    if meta.get("brain_supersedes") or meta.get("brain_version_of"):
        return "HOLD", "supersession"
    if meta.get("brain_conflicts"):
        return "HOLD", "conflict"
    if meta.get("brain_review_reason", "").startswith("belief-hold"):
        return "HOLD", "belief-outlier"
    sensitivity = meta.get("brain_sensitivity") or meta.get("sensitivity") or "internal"
    if sensitivity == "restricted":
        return "HOLD", "restricted"
    lowered = item.text.lower()
    if HOLD_ANYWHERE.search(lowered) or HOLD_TOPIC.search(item.topic_text()):
        return "HOLD", "security-or-ops-topic"
    origin = meta.get("brain_authority_origin", "")
    authority = meta.get("brain_source_authority", "")
    if origin == "external-observation":
        return "HOLD", "external-origin"
    if origin == "provider" and authority in TRUSTED:
        return "HOLD", "authority-uplift"
    age = age_days(meta.get("brain_received_at") or meta.get("timestamp", ""), now)
    unverifiable = (
        authority not in CANDIDATE_AUTHORITY
        or not meta.get("brain_provider_id")
        or not meta.get("brain_provider_version")
        or not project.provenance_resolves(meta)
    )
    if unverifiable:
        return "PARK", "unverifiable"
    try:
        confidence = float(meta.get("brain_confidence") or meta.get("confidence") or "nan")
    except ValueError:
        confidence = float("nan")
    risk = meta.get("brain_risk", "")
    rule_match = (
        tag == "fact"
        and confidence == confidence and confidence >= settings.min_confidence
        and risk in ("low", "medium")
        and sensitivity in ("public", "internal")
    )
    if not rule_match:
        if age is not None and age >= settings.park_days:
            return "PARK", "no-rule-match-aged"
        return "WAIT", "no-rule-match"
    if age is None or age * 24 < settings.cooloff_hours:
        return "WAIT", "cooloff"
    if PERSONAL_TOPIC.search(item.topic_text()) or PERSONAL_TOPIC.search(lowered):
        if settings.personal == "private":
            return "AUTO-private", "personal-topic"
        return "HOLD", "personal-topic"
    return "AUTO-cooloff", "auto-cooloff"


def load_items(project: Project) -> List[Item]:
    review = project.dir / "review"
    items: List[Item] = []
    if not review.is_dir() or review.is_symlink():
        return items
    for path in sorted(review.glob("*.md")):
        if path.is_symlink() or not path.is_file():
            continue
        try:
            items.append(Item(path, path.read_bytes()))
        except OSError:
            continue
    return items


def plan(project: Project, settings: Settings, since: Optional[str] = None) -> List[Tuple[Item, str, str]]:
    now = _dt.datetime.now(_dt.timezone.utc)
    items = [item for item in load_items(project) if item.state in OPEN_STATES]
    if since:
        items = [item for item in items if (item.meta.get("brain_received_at") or item.meta.get("timestamp", "")) >= since]
    first_body: Dict[str, str] = {}
    for item in sorted(items, key=lambda value: value.id):
        if item.kind in ("claim", "procedure", "reference") and not SCAFFOLD.search(item.body) and item.body.strip():
            first_body.setdefault(item.body_hash, item.id)
    return [(item, *classify(item, project, settings, now, first_body)) for item in items]


def audit_row(project_dir: Path, actor: str, action: str, object_id: str, old: str, new: str, content_hash: str, details: str) -> None:
    for value in (actor, action, object_id, old, new, content_hash, details):
        if any(ch in value for ch in "\n\r\t"):
            raise ValueError("invalid audit scalar")
    audit = project_dir / "audit.v2.tsv"
    if not audit.exists():
        audit.write_text("timestamp\tactor\taction\tproject_id\tobject_id\told_state\tnew_state\tcontent_hash\tdetails\tprev_hash\tevent_hash\n", encoding="utf-8")
    prev = ""
    with audit.open("rb") as stream:
        stream.seek(0, os.SEEK_END)
        size = stream.tell()
        stream.seek(max(0, size - 65536))
        tail = stream.read().decode("utf-8", errors="replace").rstrip("\n").split("\n")
    if tail:
        fields = tail[-1].split("\t")
        if len(fields) >= 11 and fields[10] != "event_hash":
            prev = fields[10]
    timestamp = now_utc()
    project_id = project_dir.name
    payload = f"{timestamp}|{actor}|{action}|{project_id}|{object_id}|{old}|{new}|{content_hash}|{details}|{prev}"
    event = sha256_bytes(payload.encode())
    with audit.open("a", encoding="utf-8") as stream:
        stream.write("\t".join((timestamp, actor, action, project_id, object_id, old, new, content_hash, details, prev, event)) + "\n")


def redact(text: str) -> Tuple[str, int]:
    count = 0

    def repl(match: "re.Match[str]") -> str:
        nonlocal count
        count += 1
        return f"[redacted sha256:{sha256_bytes(match.group(0).encode())[:12]}]"

    return SECRET.sub(repl, text), count


def atomic_write(path: Path, data: bytes) -> None:
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
    with open(tmp, "wb") as stream:
        stream.write(data)
    os.replace(tmp, path)


def run_dir(project_dir: Path, run_id: str) -> Path:
    return project_dir / "migrations" / "review-sweep" / run_id


def apply(project: Project, settings: Settings, run_id: str, actor: str, since: Optional[str], promote_list: Optional[Path]) -> Dict[str, int]:
    counts = {tier: 0 for tier in TIERS}
    planned = plan(project, settings, since)
    directory = run_dir(project.dir, run_id)
    manifest_rows: List[str] = []
    promotions: List[str] = []
    stamp = now_utc()
    for item, tier, reason in planned:
        counts[tier] += 1
        if tier in ("HOLD", "WAIT", "FLAG-redaction"):
            continue
        if not directory.exists():
            (directory / "prior").mkdir(parents=True, exist_ok=True)
        prior_hash = sha256_bytes(item.raw)
        if tier in ("AUTO-cooloff", "AUTO-private"):
            (directory / "prior" / f"{item.id}.md").write_bytes(item.raw)
            manifest_rows.append("\t".join(("promote-pending", item.id, tier, reason, item.state, "approved", prior_hash, "")))
            promotions.append(f"{item.id}\t{tier}")
            continue
        new_state, fixed_reason = ACTIONS[tier]
        text = item.text
        backup = True
        if tier == "FLAG-secret":
            text, _ = redact(text)
            backup = False  # never keep a second copy of a secret
        fields = [
            ("brain_review_state", new_state),
            ("brain_reviewed_by", f"policy:{tier}"),
            ("brain_review_reason", fixed_reason or reason),
            ("brain_reviewed_at", stamp),
            ("brain_prev_state", item.state),
            ("brain_review_sweep_run", run_id),
        ]
        if tier == "CLOSE-duplicate":
            fields.append(("brain_duplicate_of", f"review://{first_duplicate(planned, item)}"))
        new = set_fields(text, fields).encode("utf-8")
        if backup:
            (directory / "prior" / f"{item.id}.md").write_bytes(item.raw)
        atomic_write(item.path, new)
        new_hash = sha256_bytes(new)
        manifest_rows.append("\t".join(("edit" if backup else "redact", item.id, tier, fixed_reason or reason, item.state, new_state, prior_hash, new_hash)))
        audit_row(project.dir, actor, "review-sweep", item.id, item.state, new_state, new_hash, f"tier={tier} run={run_id}")
    if manifest_rows:
        with (directory / "manifest.tsv").open("a", encoding="utf-8") as stream:
            if stream.tell() == 0:
                stream.write("action\treview_id\ttier\treason\tprev_state\tnew_state\tprev_sha256\tnew_sha256\n")
            stream.write("\n".join(manifest_rows) + "\n")
    if promote_list is not None:
        promote_list.write_text("".join(f"{row}\n" for row in promotions), encoding="utf-8")
    return counts


def first_duplicate(planned: List[Tuple[Item, str, str]], item: Item) -> str:
    ids = sorted(other.id for other, _, _ in planned if other.body_hash == item.body_hash)
    return ids[0]


def record_promotion(project: Project, run_id: str, review_id: str, tier: str, canonical_rel: str, actor: str) -> None:
    """Called by bash after promote_review_locked succeeded: label the review and canonical records."""
    directory = run_dir(project.dir, run_id)
    review = project.dir / "review" / f"{review_id}.md"
    canonical = project.dir / canonical_rel
    if not canonical.resolve().is_relative_to(project.dir.resolve() / "okf"):
        raise SystemExit("canonical outside project okf/")
    stamp = now_utc()
    review_text = review.read_text(encoding="utf-8")
    prev_state = (directory / "prior" / f"{review_id}.md").read_text(encoding="utf-8", errors="replace")
    prev_meta, _ = parse_header(split_frontmatter(prev_state)[0] or [])
    review_text = set_fields(review_text, [
        ("brain_reviewed_by", f"policy:{tier}"),
        ("brain_review_reason", tier.lower()),
        ("brain_reviewed_at", stamp),
        ("brain_prev_state", prev_meta.get("brain_review_state", "proposed")),
        ("brain_review_sweep_run", run_id),
    ])
    atomic_write(review, review_text.encode("utf-8"))
    if tier == "AUTO-private":
        fields = [("brain_sensitivity", "private")]
        owner = os.environ.get("LLM_BRAIN_OWNER_PRINCIPAL", "")
        if owner and re.fullmatch(r"[A-Za-z0-9._:@-]{1,128}", owner):
            fields.append(("brain_principal", owner))
        atomic_write(canonical, set_fields(canonical.read_text(encoding="utf-8"), fields).encode("utf-8"))
    review_hash = sha256_bytes(review.read_bytes())
    with (directory / "manifest.tsv").open("a", encoding="utf-8") as stream:
        stream.write("\t".join(("promote", review_id, tier, tier.lower(), prev_meta.get("brain_review_state", "proposed"), "approved", sha256_bytes((directory / "prior" / f"{review_id}.md").read_bytes()), review_hash)) + "\t" + canonical_rel + "\n")
    audit_row(project.dir, actor, "review-sweep", review_id, prev_meta.get("brain_review_state", "proposed"), "approved", sha256_bytes(canonical.read_bytes()), f"tier={tier} run={run_id}")


def undo(project: Project, run_id: str, actor: str) -> Dict[str, int]:
    counts = {"restored": 0, "unredacted-labels": 0, "retracted": 0, "skipped-changed": 0, "skipped-missing": 0}
    directory = run_dir(project.dir, run_id)
    manifest = directory / "manifest.tsv"
    if not manifest.is_file():
        return counts
    rows = [line.split("\t") for line in manifest.read_text(encoding="utf-8").splitlines()[1:] if line]
    done_marker = directory / "undone"
    if done_marker.exists():
        raise SystemExit("review sweep run already undone")
    for row in reversed(rows):
        action, review_id = row[0], row[1]
        if action == "promote-pending":
            continue
        review = project.dir / "review" / f"{review_id}.md"
        if not review.is_file():
            counts["skipped-missing"] += 1
            continue
        current = review.read_bytes()
        if sha256_bytes(current) != row[7]:
            counts["skipped-changed"] += 1
            continue
        if action in ("edit", "promote"):
            prior = (directory / "prior" / f"{review_id}.md").read_bytes()
            atomic_write(review, prior)
            counts["restored"] += 1
            if action == "promote" and len(row) > 8:
                canonical = project.dir / row[8]
                retraction = project.dir / "okf" / "retractions" / f"{review_id}.md"
                if canonical.is_file() and not retraction.exists():
                    retraction.parent.mkdir(parents=True, exist_ok=True)
                    atomic_write(retraction, (
                        "---\ntype: Retraction\n"
                        f"brain_project_id: {project.dir.name}\nbrain_retracts: {review_id}\n"
                        "brain_review_state: superseded\nbrain_review_reason: review-sweep-undo\n"
                        f"brain_review_sweep_run: {run_id}\nbrain_schema_version: 3\ntimestamp: \"{now_utc()}\"\n---\n"
                        f"# Review sweep undo for {review_id}\n\nUndo of policy promotion run {run_id}; the canonical file is kept for audit.\n"
                    ).encode("utf-8"))
                    counts["retracted"] += 1
            audit_row(project.dir, actor, "review-sweep-undo", review_id, row[5], row[4], sha256_bytes(prior), f"run={run_id}")
        elif action == "redact":
            text = current.decode("utf-8")
            meta, _ = parse_header(split_frontmatter(text)[0] or [])
            text = set_fields(text, [("brain_review_state", row[4]), ("brain_review_reason", "review-sweep-undo-redaction-kept")])
            atomic_write(review, text.encode("utf-8"))
            counts["unredacted-labels"] += 1
            audit_row(project.dir, actor, "review-sweep-undo", review_id, row[5], row[4], sha256_bytes(text.encode()), f"run={run_id} redaction=kept")
    done_marker.write_text(f"undone_at={now_utc()}\n", encoding="utf-8")
    return counts


def project_dir_checked(root: Path, project: str) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9._-]+", project) or project in (".", "..") or ".." in project:
        raise SystemExit("invalid project id")
    root = root.resolve()
    path = root / "projects" / project
    if path.is_symlink() or not path.is_dir():
        raise SystemExit("missing or symlinked project")
    if path.resolve().parent != (root / "projects"):
        raise SystemExit("project outside root")
    return path


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(prog="review_policy.py")
    parser.add_argument("command", choices=("dry-run", "apply", "record-promotion", "undo", "classify"))
    parser.add_argument("--root", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--run-id", default="")
    parser.add_argument("--actor", default="policy:review-sweep")
    parser.add_argument("--since", default="")
    parser.add_argument("--promote-list", default="")
    parser.add_argument("--review-id", default="")
    parser.add_argument("--tier", default="")
    parser.add_argument("--canonical", default="")
    args = parser.parse_args(argv)
    settings = Settings(dict(os.environ))
    project = Project(project_dir_checked(Path(args.root), args.project))
    if args.command in ("apply", "record-promotion", "undo") and not RUN_ID.match(args.run_id):
        raise SystemExit("invalid run id")
    if args.command == "classify":
        # ids and tiers only (no titles or text), for tests and triage.
        for item, tier, reason in plan(project, settings, args.since or None):
            print(f"{item.id}\t{tier}\t{reason}")
        return 0
    if args.command == "dry-run":
        counts = {tier: 0 for tier in TIERS}
        reasons: Dict[str, int] = {}
        for _, tier, reason in plan(project, settings, args.since or None):
            counts[tier] += 1
            reasons[f"{tier}|{reason}"] = reasons.get(f"{tier}|{reason}", 0) + 1
        print("counts\t" + "\t".join(f"{tier}={counts[tier]}" for tier in TIERS))
        print("reasons\t" + "\t".join(f"{key}={value}" for key, value in sorted(reasons.items())))
        return 0
    if args.command == "apply":
        counts = apply(project, settings, args.run_id, args.actor, args.since or None, Path(args.promote_list) if args.promote_list else None)
        print("counts\t" + "\t".join(f"{tier}={counts[tier]}" for tier in TIERS))
        return 0
    if args.command == "record-promotion":
        record_promotion(project, args.run_id, args.review_id, args.tier, args.canonical, args.actor)
        return 0
    counts = undo(project, args.run_id, args.actor)
    print("undo\t" + "\t".join(f"{key}={value}" for key, value in counts.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
