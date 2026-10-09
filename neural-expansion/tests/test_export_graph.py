import csv
import hashlib
import json
import os
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "adapter"))
from export_graph import ExportError, _open_directory, _read_at, build_export
import snapshot_producer
from snapshot_producer import build_snapshot


DOC_HEADER = "path\thash\ttype\ttitle\tstate\tstatus\ttrust\tfreshness\tsensitivity\ttemperature\ttopic_id\tgenerated_at\tstale_after\tsources\truntime"
MANIFEST_HEADER = "path\thash\tschema\tembedder"
GEN = "fixture-generation-1"


def _doc(title, status="stable", *, scope="", sensitivity="internal", review="", body="Synthetic content."):
    scoped = f"\nbrain_principal: {scope}" if scope else ""
    sens = f"\nbrain_sensitivity: {sensitivity}" if sensitivity != "internal" else ""
    review_line = f"\nbrain_review_state: {review}" if review else ""
    return (f"---\ntype: Claim\ntitle: {title}\nstatus: {status}{scoped}{sens}{review_line}\n---\n{body}\n").encode()


class ExportGraphTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.package = Path(self.temp.name) / "snapshot"
        self.gen_dir = self.package / "indexes" / "generations" / GEN
        self.doc_dir = self.gen_dir / "documents"
        self.gen_dir.mkdir(parents=True)
        (self.package / "indexes").mkdir(exist_ok=True)
        (self.package / "indexes" / "current").write_text(GEN + "\n")
        self.docs = {
            "okf/claims/open.md": _doc("Open record"),
            "okf/claims/scoped.md": _doc("Scoped record", scope="alice"),
            "okf/claims/hidden.md": _doc("Hidden record", scope="bob"),
            "okf/claims/deprecated.md": _doc("Deprecated record", "deprecated"),
            "okf/claims/draft.md": _doc("Draft record", "draft"),
            "okf/claims/retracted.md": _doc("Retracted record"),
        }
        self.edges = [
            ("okf/claims/open.md", "supports", "okf/claims/scoped.md"),
            ("okf/claims/scoped.md", "links_to", "okf/claims/hidden.md"),
            ("okf/claims/open.md", "links_to", "okf/missing/unknown.md"),
            ("okf/claims/open.md", "supports", "okf/claims/deprecated.md"),
        ]
        self.write_package()

    def tearDown(self):
        self.temp.cleanup()

    def write_package(self):
        files = {}
        doc_rows = []
        manifest_rows = []
        for rel, raw in self.docs.items():
            target = self.doc_dir / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
            digest = hashlib.sha256(raw).hexdigest()
            files[f"documents/{rel}"] = digest
            doc_rows.append([rel, digest, "Claim", "fixture", "current", "stable", "unverified", "fresh", "internal", "warm", "", "", "", "", ""])
            manifest_rows.append([rel, digest, "3", "none"])
        tombstone = self.doc_dir / "okf" / "retractions" / "retracted.md"
        tombstone.parent.mkdir(parents=True, exist_ok=True)
        tombstone.write_text("---\ntype: Retraction\n---\nsynthetic tombstone\n")
        files["documents/okf/retractions/retracted.md"] = hashlib.sha256(tombstone.read_bytes()).hexdigest()

        def tsv(header, rows):
            from io import StringIO
            stream = StringIO(newline="")
            writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
            writer.writerow(header.split("\t"))
            writer.writerows(rows)
            return stream.getvalue().encode()

        (self.gen_dir / "documents.tsv").write_bytes(tsv(DOC_HEADER, doc_rows))
        (self.gen_dir / "manifest.tsv").write_bytes(tsv(MANIFEST_HEADER, manifest_rows))
        (self.gen_dir / "graph.tsv").write_bytes(tsv("source\trelation\ttarget", self.edges))
        for rel in ("documents.tsv", "manifest.tsv", "graph.tsv"):
            files[rel] = hashlib.sha256((self.gen_dir / rel).read_bytes()).hexdigest()
        (self.gen_dir / "snapshot.json").write_text(json.dumps({"generation": GEN, "files": files}, sort_keys=True))

    def test_visibility_filters_nodes_and_edges_before_export(self):
        result = build_export(self.package, "alice")
        ids = {node["id"] for node in result["nodes"]}
        self.assertEqual(ids, {"okf/claims/open.md", "okf/claims/scoped.md"})
        self.assertEqual(result["edges"], [{"source": "okf/claims/open.md", "relation": "supports", "target": "okf/claims/scoped.md"}])
        output = json.dumps(result)
        self.assertNotIn("hidden.md", output)
        self.assertNotIn("deprecated.md", output)
        self.assertNotIn("retracted.md", output)
        self.assertFalse(any("hash" in key for node in result["nodes"] for key in node))

    def test_principal_is_mandatory(self):
        with self.assertRaises(ExportError):
            build_export(self.package, "")

    def test_malformed_visibility_metadata_fails_closed(self):
        self.docs["okf/claims/scoped.md"] = (
            b"---\ntype: Claim\ntitle: Malformed scope\nstatus: stable\nbrain_audience: [alice, 7]\n---\nsecret\n"
        )
        self.write_package()
        result = build_export(self.package, "alice")
        self.assertNotIn("okf/claims/scoped.md", {node["id"] for node in result["nodes"]})

    def test_missing_generation_and_mixed_generation_fail_closed(self):
        (self.package / "indexes" / "current").write_text("missing-generation\n")
        with self.assertRaises(ExportError):
            build_export(self.package, "alice")
        (self.package / "indexes" / "current").write_text(GEN + "\n")
        snap = json.loads((self.gen_dir / "snapshot.json").read_text())
        snap["generation"] = "another-generation"
        (self.gen_dir / "snapshot.json").write_text(json.dumps(snap))
        with self.assertRaises(ExportError):
            build_export(self.package, "alice")

    def test_malformed_link_and_traversal_path_fail_closed(self):
        self.edges.append(("okf/claims/open.md", "links_to", "../secret.md"))
        self.write_package()
        with self.assertRaises(ExportError):
            build_export(self.package, "alice")

    def test_malicious_label_is_plain_json_text(self):
        self.docs["okf/claims/open.md"] = _doc('<img src=x onerror="alert(1)">')
        self.write_package()
        result = build_export(self.package, "alice")
        label = next(node["title"] for node in result["nodes"] if node["id"].endswith("open.md"))
        self.assertEqual(label, '<img src=x onerror="alert(1)">')
        self.assertIn("escapeHTML", (Path(__file__).parents[1] / "viewer.js").read_text())

    def test_stale_document_hash_fails_closed(self):
        target = self.doc_dir / "okf/claims/open.md"
        target.write_bytes(target.read_bytes() + b" changed")
        with self.assertRaises(ExportError):
            build_export(self.package, "alice")

    def test_unresolved_targets_are_dropped(self):
        result = build_export(self.package, "alice")
        self.assertTrue(all(edge["target"] in {node["id"] for node in result["nodes"]} for edge in result["edges"]))

    def test_descriptor_read_rejects_symlink_replacement_race(self):
        pointer = self.package / "indexes" / "current"
        backup = pointer.with_suffix(".saved")
        root_fd = _open_directory(self.package)
        original_open = os.open
        raced = False

        def replace_before_open(path, flags, *args, **kwargs):
            nonlocal raced
            if path == "current" and kwargs.get("dir_fd") is not None and not raced:
                raced = True
                pointer.rename(backup)
                pointer.symlink_to(backup.name)
            return original_open(path, flags, *args, **kwargs)

        try:
            os.open = replace_before_open
            with self.assertRaises(ExportError):
                _read_at(root_fd, "indexes/current", [0])
        finally:
            os.open = original_open
            os.close(root_fd)
            pointer.unlink(missing_ok=True)
            backup.rename(pointer)
        self.assertTrue(raced)


class ActualIndexProducerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "synthetic-vault"
        self.output = Path(self.temp.name) / "viewer-snapshot"
        self.generation = "synthetic-generation-42"
        self.generation_dir = self.root / "indexes" / "generations" / self.generation
        self.generation_dir.mkdir(parents=True)
        (self.root / "indexes" / "current").write_text(self.generation + "\n")
        self.documents = {
            "okf/claims/alice-visible.md": (
                "---\ntype: Claim\ntitle: Visible\nstatus: stable\n"
                "brain_principal: alice\nsources:\n  - resource: okf/claims/bob-hidden.md\n"
                "  - resource: https://user:secret@example.invalid/private\n"
                "---\nSynthetic visible record.\n"
            ).encode(),
            "okf/claims/bob-hidden.md": (
                b"---\ntype: Claim\ntitle: Hidden Bob\nstatus: stable\nbrain_principal: bob\n---\nSynthetic secret.\n"
            ),
            "okf/claims/retracted.md": (
                b"---\ntype: Claim\ntitle: Retracted\nstatus: stable\n---\nSynthetic old record.\n"
            ),
        }
        self._write_index()

    def tearDown(self):
        self.temp.cleanup()

    def _write_index(self):
        from io import StringIO
        def tsv(header, rows):
            stream = StringIO(newline="")
            writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
            writer.writerow(header.split("\t"))
            writer.writerows(rows)
            return stream.getvalue().encode()
        doc_rows = []
        manifest_rows = []
        for rel, raw in self.documents.items():
            target = self.root / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
            digest = hashlib.sha256(raw).hexdigest()
            doc_rows.append([rel, digest, "Claim", rel.rsplit("/", 1)[-1], "current", "stable", "unverified", "fresh", "internal", "warm", "", "", "", "", ""])
            manifest_rows.append([rel, digest, "3", "none"])
        retraction = self.root / "okf/retractions/retracted.md"
        retraction.parent.mkdir(parents=True, exist_ok=True)
        retraction.write_text("---\ntype: Retraction\n---\nSynthetic tombstone.\n")
        graph_rows = [
            ("okf/claims/alice-visible.md", "supports", "okf/claims/bob-hidden.md"),
            ("okf/claims/alice-visible.md", "provenance", "human://synthetic-source"),
            ("okf/claims/alice-visible.md", "links_to", "okf/claims/retracted.md"),
        ]
        (self.generation_dir / "documents.tsv").write_bytes(tsv(DOC_HEADER, doc_rows))
        (self.generation_dir / "manifest.tsv").write_bytes(tsv(MANIFEST_HEADER, manifest_rows))
        (self.generation_dir / "graph.tsv").write_bytes(tsv("source\trelation\ttarget", graph_rows))

    def test_actual_format_producer_packages_one_generation_and_filters_leaks(self):
        package = build_snapshot(self.root, self.output)
        result = build_export(package, "alice")
        self.assertEqual({node["id"] for node in result["nodes"]}, {"okf/claims/alice-visible.md"})
        self.assertEqual(result["nodes"][0]["provenance"], "")
        rendered = json.dumps(result)
        self.assertNotIn("bob-hidden", rendered)
        self.assertNotIn("user:secret", rendered)
        self.assertNotIn("human://synthetic-source", rendered)
        self.assertEqual(result["edges"], [])
        self.assertTrue((package / "indexes/generations" / self.generation / "documents/okf/retractions/retracted.md").is_file())

    def test_actual_format_source_hash_mismatch_aborts_package(self):
        path = self.root / "okf/claims/bob-hidden.md"
        path.write_bytes(path.read_bytes() + b" mutated")
        with self.assertRaises(ExportError):
            build_snapshot(self.root, self.output)
        self.assertFalse(self.output.exists())

    def test_new_tombstone_after_initial_absent_read_aborts_publication(self):
        original_read = snapshot_producer._read_at
        injected = False

        def add_tombstone_after_absence(root_fd, relative, total, *, optional=False):
            nonlocal injected
            value = original_read(root_fd, relative, total, optional=optional)
            if relative == "okf/retractions/alice-visible.md" and value is None and not injected:
                injected = True
                target = self.root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("---\ntype: Retraction\n---\nSynthetic late tombstone.\n")
            return value

        with patch.object(snapshot_producer, "_read_at", side_effect=add_tombstone_after_absence):
            with self.assertRaises(ExportError):
                build_snapshot(self.root, self.output)
        self.assertTrue(injected)
        self.assertFalse(self.output.exists())

    def test_removed_tombstone_after_initial_read_aborts_publication(self):
        original_read = snapshot_producer._read_at
        removed = False

        def remove_tombstone_after_read(root_fd, relative, total, *, optional=False):
            nonlocal removed
            value = original_read(root_fd, relative, total, optional=optional)
            if relative == "okf/retractions/retracted.md" and value is not None and not removed:
                removed = True
                (self.root / relative).unlink()
            return value

        with patch.object(snapshot_producer, "_read_at", side_effect=remove_tombstone_after_read):
            with self.assertRaises(ExportError):
                build_snapshot(self.root, self.output)
        self.assertTrue(removed)
        self.assertFalse(self.output.exists())

    def test_destination_inside_source_is_rejected_without_writes(self):
        destination = self.root / "exports" / "snapshot"
        destination.parent.mkdir()
        with self.assertRaises(ExportError):
            build_snapshot(self.root, destination)
        self.assertEqual(list(destination.parent.iterdir()), [])

    def test_destination_via_symlinked_ancestor_into_source_is_rejected(self):
        inside = self.root / "exports"
        inside.mkdir()
        alias = Path(self.temp.name) / "source-alias"
        alias.symlink_to(inside, target_is_directory=True)
        destination = alias / "snapshot"
        with self.assertRaises(ExportError):
            build_snapshot(self.root, destination)
        self.assertEqual(list(inside.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
