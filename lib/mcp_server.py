#!/usr/bin/env python3
"""Minimal stdio MCP server for LLM-Brain.

The server is a thin, stdlib-only adapter over the ``llm-brain`` CLI.  Every
tool shells out to an existing command, so review gates, locks, audit and
secret scanning stay in exactly one place.  Writes are limited to
``brain_capture``, which only records source custody, an episode and a
*proposed* review item; nothing becomes approved memory without review.
``--read-only`` removes the capture tool entirely.

Transport: newline-delimited JSON-RPC 2.0 over stdin/stdout.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True

SERVER_NAME = "llm-brain"
PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")
MAX_TEXT = 65536
PROJECT_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
TOOL_TIMEOUT = 120


def text_property(description: str) -> dict[str, Any]:
    return {"type": "string", "description": description}


PROJECT_PROPS = {
    "project_id": text_property("LLM-Brain project id. Optional when source_root (or the server working directory) maps to exactly one existing project."),
    "source_root": text_property("Repository or workspace path used to resolve the project. Defaults to the server working directory."),
    "principal": text_property("Optional principal for visibility filtering."),
}


def tool(name: str, description: str, properties: dict[str, Any], required: list[str], read_only: bool) -> dict[str, Any]:
    return {
        "name": name,
        "description": description,
        "inputSchema": {"type": "object", "properties": {**PROJECT_PROPS, **properties}, "required": required, "additionalProperties": False},
        "annotations": {"readOnlyHint": read_only, "destructiveHint": False, "idempotentHint": read_only, "openWorldHint": False},
    }


def tool_definitions(read_only: bool) -> list[dict[str, Any]]:
    tools = [
        tool("brain_search", "Search approved project memory (BM25F lexical by default). Returns ranked TSV rows.", {
            "query": text_property("Search text."),
            "limit": {"type": "integer", "minimum": 1, "maximum": 50, "description": "Maximum rows (default 8)."},
            "paths": {"type": "array", "items": {"type": "string"}, "description": "Relative file paths the task touches; boosts concepts whose brain_paths match."},
        }, ["query"], True),
        tool("brain_pack_build", "Build a budgeted, cited context pack for a task. Due intentions appear first. Writes only a derived pack file.", {
            "task": text_property("Task description."),
            "budget_tokens": {"type": "integer", "minimum": 1, "maximum": 32000, "description": "Approximate token budget (default 1200)."},
            "paths": {"type": "array", "items": {"type": "string"}, "description": "Relative file paths the task touches."},
        }, ["task"], False),
        tool("brain_recall", "Bridge recall: approved memory plus captured evidence, rendered as bounded markdown in JSON.", {
            "query": text_property("Recall question."),
            "budget_tokens": {"type": "integer", "minimum": 1, "maximum": 32000, "description": "Approximate token budget (default 4000)."},
        }, ["query"], True),
        tool("brain_status", "Read-only maintenance status for the project (health, findings and advisory signals).", {}, [], True),
        tool("brain_brief", "Size-capped project brief: durable approved facts, due intentions and recent changes.", {
            "max_bytes": {"type": "integer", "minimum": 256, "maximum": 16000, "description": "Byte cap (default 4000)."},
        }, [], True),
    ]
    if not read_only:
        tools.append(tool("brain_capture", "Capture a note as source custody plus a PROPOSED review item. Never approves memory; secrets are blocked by the scanner.", {
            "title": text_property("Short title for the note."),
            "text": text_property("Note body (markdown)."),
        }, ["text"], False))
    return tools


class ToolError(Exception):
    pass


class BrainError(Exception):
    pass


def pin_brain(root: str) -> Path:
    """Validate the one brain (vault root) this process may touch.

    On a shared host the brain must be a real directory owned by the server's
    OS user and not writable by group or others; anything else could let a
    second person read or plant memories.
    """
    path = Path(root)
    if not path.is_absolute():
        raise BrainError("brain root must be absolute")
    if path.is_symlink():
        raise BrainError("brain root must not be a symlink")
    try:
        info = path.stat()
    except OSError as error:
        raise BrainError("brain root is unavailable") from error
    if not path.is_dir():
        raise BrainError("brain root is not a directory")
    if hasattr(os, "getuid") and info.st_uid != os.getuid():
        raise BrainError("brain root is owned by another OS user")
    if info.st_mode & 0o022:
        raise BrainError("brain root is writable by group or others; run: chmod 700 BRAIN")
    if info.st_mode & 0o077:
        print("llm-brain mcp: warning: brain root is readable by other OS users; run: chmod 700 BRAIN", file=sys.stderr)
    return path.resolve()


class Server:
    def __init__(self, cli: str, root: str, read_only: bool, cwd: str, project_id: str = "") -> None:
        self.cli = cli
        self.root = str(pin_brain(root))
        self.read_only = read_only
        self.cwd = cwd
        self.pinned_project = project_id
        # Child processes see only this brain.  Scratch files live in a fresh
        # owner-only (0700) directory per server process, never a shared cache.
        self.scratch = Path(tempfile.mkdtemp(prefix="llm-brain-mcp-"))
        os.chmod(self.scratch, 0o700)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("LLM_BRAIN_ROOT")}
        self.env["LLM_BRAIN_ROOT"] = self.root
        self.env["TMPDIR"] = str(self.scratch)
        self.env["PYTHONDONTWRITEBYTECODE"] = "1"

    def run_cli(self, *arguments: str) -> str:
        command = [self.cli, "--root", self.root, *arguments]
        try:
            completed = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=TOOL_TIMEOUT, cwd=self.cwd, env=self.env)
        except subprocess.TimeoutExpired as error:
            raise ToolError("llm-brain command timed out") from error
        if completed.returncode != 0:
            message = (completed.stderr or completed.stdout).strip().splitlines()
            raise ToolError(message[-1] if message else f"llm-brain exited {completed.returncode}")
        return completed.stdout

    @staticmethod
    def text_arg(arguments: dict[str, Any], key: str, required: bool = False) -> str:
        value = arguments.get(key, "")
        if value is None:
            value = ""
        if not isinstance(value, str):
            raise ToolError(f"{key} must be a string")
        if required and not value.strip():
            raise ToolError(f"{key} is required")
        if len(value.encode("utf-8")) > MAX_TEXT:
            raise ToolError(f"{key} exceeds 64 KiB")
        return value

    @staticmethod
    def line_arg(arguments: dict[str, Any], key: str, required: bool = False) -> str:
        value = Server.text_arg(arguments, key, required)
        if "\n" in value or "\r" in value:
            raise ToolError(f"{key} must be a single line")
        return value.strip()

    @staticmethod
    def int_arg(arguments: dict[str, Any], key: str, default: int, low: int, high: int) -> int:
        value = arguments.get(key, default)
        if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
            raise ToolError(f"{key} must be an integer between {low} and {high}")
        return value

    @staticmethod
    def paths_arg(arguments: dict[str, Any]) -> list[str]:
        values = arguments.get("paths", []) or []
        if not isinstance(values, list) or len(values) > 32:
            raise ToolError("paths must be a list of at most 32 relative paths")
        result = []
        for value in values:
            if not isinstance(value, str) or not value or "\n" in value or value.startswith("/") or ".." in value.split("/"):
                raise ToolError("paths must be relative paths inside the project")
            result.append(value)
        return result

    def source_root(self, arguments: dict[str, Any]) -> str:
        root = self.line_arg(arguments, "source_root") or self.cwd
        if not Path(root).is_dir():
            raise ToolError("source_root is not a directory")
        return root

    def project(self, arguments: dict[str, Any]) -> str:
        project_id = self.line_arg(arguments, "project_id")
        if self.pinned_project:
            if project_id and project_id != self.pinned_project:
                raise ToolError("this server is pinned to a different project")
            return self.pinned_project
        if project_id:
            if not PROJECT_ID_RE.fullmatch(project_id):
                raise ToolError("invalid project_id")
            return project_id
        detected = dict(line.split("=", 1) for line in self.run_cli("--cwd", self.source_root(arguments), "detect").splitlines() if "=" in line)
        if detected.get("scope") != "existing-project" or not detected.get("project_id"):
            raise ToolError("no existing LLM-Brain project for this source root; pass project_id")
        return detected["project_id"]

    def principal(self, arguments: dict[str, Any]) -> list[str]:
        principal = self.line_arg(arguments, "principal")
        return ["--principal", principal] if principal else []

    def call(self, name: str, arguments: dict[str, Any]) -> str:
        if name == "brain_search":
            command = ["search", self.project(arguments), self.line_arg(arguments, "query", True), "--limit", str(self.int_arg(arguments, "limit", 8, 1, 50))]
            for path in self.paths_arg(arguments):
                command += ["--path", path]
            return self.run_cli(*command, *self.principal(arguments))
        if name == "brain_pack_build":
            command = ["pack", "build", self.project(arguments), "--task", self.line_arg(arguments, "task", True), "--agent", "mcp", "--budget-tokens", str(self.int_arg(arguments, "budget_tokens", 1200, 1, 32000))]
            for path in self.paths_arg(arguments):
                command += ["--path", path]
            output = self.run_cli(*command, *self.principal(arguments))
            fields = dict(part.split("=", 1) for part in output.split() if "=" in part)
            pack_file = fields.get("file", "")
            if pack_file and Path(pack_file).is_file():
                return output + "\n" + Path(pack_file).read_text(encoding="utf-8")
            return output
        if name == "brain_recall":
            query = self.text_arg(arguments, "query", True)
            with tempfile.TemporaryDirectory(prefix="llm-brain-mcp.", dir=self.scratch) as scratch:
                query_file = Path(scratch) / "query.txt"
                query_file.write_text(query + "\n", encoding="utf-8")
                command = ["bridge", "recall", "--source-root", self.source_root(arguments), "--query-file", str(query_file), "--budget-tokens", str(self.int_arg(arguments, "budget_tokens", 4000, 1, 32000))]
                project_id = self.line_arg(arguments, "project_id")
                if project_id:
                    command += ["--project-id", project_id]
                else:
                    command += ["--project-id", self.project(arguments)]
                return self.run_cli(*command, *self.principal(arguments))
        if name == "brain_status":
            return self.run_cli("maintenance", "status", self.project(arguments), *self.principal(arguments))
        if name == "brain_brief":
            return self.run_cli("brief", self.project(arguments), "--max-bytes", str(self.int_arg(arguments, "max_bytes", 4000, 256, 16000)), *self.principal(arguments))
        if name == "brain_capture" and not self.read_only:
            text = self.text_arg(arguments, "text", True)
            title = self.line_arg(arguments, "title") or "MCP capture"
            project_id = self.project(arguments)
            with tempfile.TemporaryDirectory(prefix="llm-brain-mcp.", dir=self.scratch) as scratch:
                record = Path(scratch) / "mcp-capture.md"
                record.write_text(f"---\ntype: MCPCapture\ntitle: {json.dumps(title)}\n---\n# {title}\n\n{text}\n", encoding="utf-8")
                return self.run_cli("bridge", "capture", "--source-root", self.source_root(arguments), "--project-id", project_id, "--record", str(record))
        raise ToolError(f"unknown tool: {name}")

    def handle(self, message: dict[str, Any]) -> dict[str, Any] | None:
        method = message.get("method")
        request_id = message.get("id")
        params = message.get("params") or {}
        if request_id is None:
            return None  # notification (e.g. notifications/initialized)
        if method == "initialize":
            requested = params.get("protocolVersion")
            version = requested if requested in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0]
            return result(request_id, {
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": SERVER_NAME, "version": server_version()},
                "instructions": "Approved LLM-Brain memory is advisory: current source, user direction and live proof outrank it. Captures only create proposed review items.",
            })
        if method == "ping":
            return result(request_id, {})
        if method == "tools/list":
            return result(request_id, {"tools": tool_definitions(self.read_only)})
        if method == "tools/call":
            name = params.get("name")
            arguments = params.get("arguments") or {}
            if not isinstance(name, str) or not isinstance(arguments, dict):
                return error(request_id, -32602, "invalid tools/call params")
            definitions = {entry["name"]: entry for entry in tool_definitions(self.read_only)}
            if name not in definitions:
                return error(request_id, -32602, f"unknown tool: {name}")
            unknown = set(arguments) - set(definitions[name]["inputSchema"]["properties"])
            if unknown:
                # e.g. "root" or "brain": a client can never redirect this server.
                return error(request_id, -32602, "unknown arguments: " + ", ".join(sorted(unknown)))
            try:
                text = self.call(name, arguments)
                return result(request_id, {"content": [{"type": "text", "text": text}], "isError": False})
            except ToolError as failure:
                return result(request_id, {"content": [{"type": "text", "text": f"error: {failure}"}], "isError": True})
        return error(request_id, -32601, f"method not found: {method}")


def server_version() -> str:
    for candidate in (Path(__file__).resolve().parent.parent / "VERSION", Path(__file__).resolve().parent / "VERSION"):
        if candidate.is_file():
            return candidate.read_text(encoding="utf-8").strip()
    return "unknown"


def result(request_id: Any, payload: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": payload}


def error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True)
    parser.add_argument("--root", required=True, help="the one brain (vault root) this process serves")
    parser.add_argument("--project-id", default="", help="optionally pin every tool to one project")
    parser.add_argument("--read-only", action="store_true")
    parser.add_argument("--cwd", default=os.getcwd())
    args = parser.parse_args()
    cli = str(Path(args.cli).resolve())
    try:
        server = Server(cli, args.root, args.read_only, str(Path(args.cwd).resolve()), args.project_id)
    except BrainError as failure:
        print(f"llm-brain mcp: {failure}", file=sys.stderr)
        return 2
    try:
        return serve(server)
    finally:
        shutil.rmtree(server.scratch, ignore_errors=True)


def serve(server: "Server") -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            response: dict[str, Any] | None = error(None, -32700, "parse error")
        else:
            if not isinstance(message, dict):
                response = error(None, -32600, "invalid request")
            else:
                response = server.handle(message)
        if response is not None:
            sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
