import csv
import hashlib
import json
import re
import shutil
import stat
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path


ADAPTER = Path(__file__).resolve().parents[1] / "adapter"
sys.path.insert(0, str(ADAPTER))
import session_bridge
from session_bridge import ReadOnlySessionBridge, SessionBridgeError, safe_script_json
from export_graph import ExportError, VIEWER_SNAPSHOT_FORMAT, build_core_snapshot_export
from snapshot_to_html import LocalSnapshotError, build_local_snapshot_html


DOC_HEADER = "path\thash\ttype\ttitle\tstate\tstatus\ttrust\tfreshness\tsensitivity\ttemperature\ttopic_id\tgenerated_at\tstale_after\tsources\truntime"
MANIFEST_HEADER = "path\thash\tschema\tembedder"
GENERATION = "bridge-fixture-generation"


def write_synthetic_project(root: Path) -> None:
    generation_dir = root / "indexes" / "generations" / GENERATION
    generation_dir.mkdir(parents=True)
    (root / "indexes" / "current").write_text(GENERATION + "\n", encoding="ascii")
    documents = {
        "okf/claims/alice.md": (
            "---\ntype: Claim\ntitle: Alice visible\nstatus: stable\nbrain_principal: alice\n"
            "---\nSynthetic text for Alice.\n"
        ).encode(),
        "okf/claims/bob.md": (
            "---\ntype: Claim\ntitle: Bob private label\nstatus: stable\nbrain_audience: bob\n"
            "---\nSynthetic text for Bob.\n"
        ).encode(),
        "okf/claims/open.md": (
            "---\ntype: Decision\ntitle: Unscoped internal\nstatus: stable\n"
            "---\nSynthetic unscoped text.\n"
        ).encode(),
    }
    docs_rows = []
    manifest_rows = []
    bound_files = {}
    for relative, raw in documents.items():
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw)
        digest = hashlib.sha256(raw).hexdigest()
        docs_rows.append([relative, digest, "Claim", relative.rsplit("/", 1)[-1], "current", "stable", "unverified", "fresh", "internal", "warm", "", "", "", "", ""])
        manifest_rows.append([relative, digest, "3", "none"])

    def tsv(header, rows):
        from io import StringIO
        stream = StringIO(newline="")
        writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
        writer.writerow(header.split("\t"))
        writer.writerows(rows)
        return stream.getvalue().encode()

    assets = {
        "documents.tsv": tsv(DOC_HEADER, docs_rows),
        "manifest.tsv": tsv(MANIFEST_HEADER, manifest_rows),
        "graph.tsv": tsv("source\trelation\ttarget", [
            ("okf/claims/alice.md", "supports", "okf/claims/open.md"),
            ("okf/claims/alice.md", "links_to", "okf/claims/bob.md"),
        ]),
    }
    for name, raw in assets.items():
        (generation_dir / name).write_bytes(raw)
        bound_files[name] = hashlib.sha256(raw).hexdigest()
    (generation_dir / "snapshot.json").write_text(
        json.dumps({"generation": GENERATION, "files": bound_files}, sort_keys=True),
        encoding="utf-8",
    )


def write_core_snapshot_package(project_root: Path, package: Path) -> None:
    generation_dir = project_root / "indexes" / "generations" / GENERATION
    package_generation = package / "indexes" / "generations" / GENERATION
    package_generation.mkdir(parents=True)
    (package / "indexes").mkdir(exist_ok=True)
    (package / "indexes" / "current").write_text(GENERATION + "\n", encoding="ascii")
    files = {}
    for name in ("documents.tsv", "graph.tsv", "manifest.tsv"):
        raw = (generation_dir / name).read_bytes()
        (package_generation / name).write_bytes(raw)
        files[name] = hashlib.sha256(raw).hexdigest()
    for document in project_root.glob("okf/**/*.md"):
        relative = document.relative_to(project_root).as_posix()
        raw = document.read_bytes()
        destination = package_generation / "documents" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(raw)
        files["documents/" + relative] = hashlib.sha256(raw).hexdigest()
    (package_generation / "snapshot.json").write_text(
        json.dumps({"generation": GENERATION, "files": files}, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )
    (package / "viewer-snapshot.json").write_text(
        json.dumps({
            "format": VIEWER_SNAPSHOT_FORMAT,
            "version": 1,
            "project_id": project_root.name,
            "generation": GENERATION,
        }, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )


@contextmanager
def synthetic_core_stager(project_root: Path):
    package = project_root / "exports" / "viewer-snapshots" / "synthetic-bridge-fixture"
    package.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    write_core_snapshot_package(project_root, package)
    try:
        yield package
    finally:
        shutil.rmtree(package, ignore_errors=False)


class ReadOnlySessionBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "synthetic-project"
        self.root.mkdir()
        write_synthetic_project(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_trusted_session_consumes_core_package_inside_host_staging_context(self):
        before = {
            path.relative_to(self.root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in self.root.rglob("*") if path.is_file()
        }
        calls = {"principal": 0, "project": 0, "stager": []}

        def principal():
            calls["principal"] += 1
            return "alice"

        def project():
            calls["project"] += 1
            return self.root

        @contextmanager
        def stager(path):
            calls["stager"].append(("enter", path))
            try:
                with synthetic_core_stager(path) as package:
                    self.assertEqual(package.stat().st_dev, path.stat().st_dev)
                    yield package
            finally:
                calls["stager"].append(("exit", path))

        bridge = ReadOnlySessionBridge(
            authenticated_principal=principal,
            authorized_project_root=project,
            snapshot_package_stager=stager,
        )
        payload = bridge.projection()

        node_ids = {node["id"] for node in payload["nodes"]}
        self.assertEqual(node_ids, {"okf/claims/alice.md", "okf/claims/open.md"})
        self.assertEqual(payload["edges"], [{
            "source": "okf/claims/alice.md",
            "relation": "supports",
            "target": "okf/claims/open.md",
        }])
        rendered = json.dumps(payload)
        self.assertNotIn("Bob private label", rendered)
        self.assertNotIn("okf/claims/bob.md", rendered)
        self.assertNotIn("hash", rendered)
        self.assertEqual(calls["principal"], 1)
        self.assertEqual(calls["project"], 1)
        self.assertEqual(calls["stager"], [("enter", self.root), ("exit", self.root)])
        self.assertEqual(before, {
            path.relative_to(self.root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in self.root.rglob("*") if path.is_file()
        })
        self.assertFalse((self.root / "exports/viewer-snapshots/synthetic-bridge-fixture").exists())

    def test_missing_principal_fails_before_resolving_project(self):
        calls = []
        bridge = ReadOnlySessionBridge(
            authenticated_principal=lambda: None,
            authorized_project_root=lambda: calls.append("project") or self.root,
            snapshot_package_stager=lambda _path: calls.append("stager"),
        )
        with self.assertRaisesRegex(SessionBridgeError, "authenticated principal required"):
            bridge.projection()
        self.assertEqual(calls, [])

    def test_principal_cannot_be_overridden_as_a_projection_argument(self):
        bridge = ReadOnlySessionBridge(
            authenticated_principal=lambda: "alice",
            authorized_project_root=lambda: self.root,
            snapshot_package_stager=lambda _path: _empty_guard(),
        )
        with self.assertRaises(TypeError):
            bridge.projection(principal="bob")

    def test_malformed_principal_fails_closed(self):
        bridge = ReadOnlySessionBridge(
            authenticated_principal=lambda: " alice ",
            authorized_project_root=lambda: self.root,
            snapshot_package_stager=lambda _path: _empty_guard(),
        )
        with self.assertRaisesRegex(SessionBridgeError, "authenticated principal required"):
            bridge.projection()

    def test_json_script_payload_escapes_html_script_boundaries(self):
        encoded = safe_script_json({"title": "</script><script>alert(1)</script> "})
        self.assertNotIn("<", encoded)
        self.assertNotIn("</script", encoded.lower())
        self.assertIn("\\u003c/script\\u003e", encoded)
        self.assertIn("\\u2028", encoded)

    def test_core_snapshot_marker_binds_project_and_pointer_generation(self):
        with synthetic_core_stager(self.root) as package:
            self.assertTrue(build_core_snapshot_export(package, "alice", self.root.name)["nodes"])
            with self.assertRaises(ExportError):
                build_core_snapshot_export(package, "alice", "another-project")
            marker_path = package / "viewer-snapshot.json"
            marker = json.loads(marker_path.read_text(encoding="utf-8"))
            marker["generation"] = "another-generation"
            marker_path.write_text(json.dumps(marker), encoding="utf-8")
            with self.assertRaises(ExportError):
                build_core_snapshot_export(package, "alice", self.root.name)


class LocalSnapshotHtmlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.vault = self.base / "vault"
        self.project = self.vault / "projects" / "demo"
        self.project.mkdir(parents=True)
        write_synthetic_project(self.project)
        self.output = self.base / "neural-expansion.html"

    def tearDown(self):
        self.temp.cleanup()

    def test_cli_snapshot_filters_before_html_and_writes_owner_only(self):
        before = {
            path.relative_to(self.vault).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in self.vault.rglob("*") if path.is_file()
        }
        result = build_local_snapshot_html(self.vault, "demo", "alice", self.output)
        html = result.read_text(encoding="utf-8")
        fixture = json.loads(re.search(
            r'<script type="application/json" id="synthetic-fixture">(.*?)</script>',
            html,
            re.DOTALL,
        ).group(1))
        self.assertEqual({node["id"] for node in fixture["nodes"]}, {
            "okf/claims/alice.md", "okf/claims/open.md",
        })
        self.assertEqual(fixture["edges"], [{
            "source": "okf/claims/alice.md",
            "relation": "supports",
            "target": "okf/claims/open.md",
        }])
        self.assertNotIn("Bob private label", html)
        self.assertNotIn("okf/claims/bob.md", html)
        self.assertIn("LOCAL SNAPSHOT · PRINCIPAL-FILTERED", html)
        self.assertEqual(stat.S_IMODE(result.stat().st_mode), 0o600)
        self.assertFalse(re.search(r"<script\b[^>]*\bsrc=", html, re.IGNORECASE))
        after = {
            path.relative_to(self.vault).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in self.vault.rglob("*") if path.is_file()
        }
        self.assertEqual(before, after)

    def test_output_must_be_new_and_outside_vault(self):
        with self.assertRaisesRegex(LocalSnapshotError, "outside the vault"):
            build_local_snapshot_html(self.vault, "demo", "alice", self.vault / "neural-expansion.html")
        self.assertFalse((self.vault / "neural-expansion.html").exists())

    def test_active_writer_lock_refuses_snapshot_without_touching_vault(self):
        lock = self.vault / ".locks" / "project-demo.lock"
        lock.mkdir(parents=True)
        with self.assertRaisesRegex(LocalSnapshotError, "writer is active"):
            build_local_snapshot_html(self.vault, "demo", "alice", self.output)
        self.assertTrue(lock.is_dir())
        self.assertFalse(self.output.exists())


@contextmanager
def _empty_guard():
    yield


if __name__ == "__main__":
    unittest.main()
