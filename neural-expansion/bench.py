#!/usr/bin/env python3
"""Bounded synthetic graph-preparation benchmark for Neural Expansion."""
import json
import random
import time


def run(size: int) -> dict[str, float | int]:
    rng = random.Random(7)
    nodes = [{"id": f"okf/claims/n{i}.md", "title": f"Synthetic claim {i}",
              "type": "Claim", "status": "stable", "trust": "synthetic",
              "provenance": "fixture://generated", "excerpt": "Synthetic benchmark node."}
             for i in range(size)]
    ids = [n["id"] for n in nodes]
    edges = [{"source": ids[i % size], "relation": "supports", "target": ids[rng.randrange(size)]}
             for i in range(size * 4)]
    start = time.perf_counter()
    by_id = {n["id"]: n for n in nodes}
    adjacency: dict[str, list[dict]] = {key: [] for key in ids}
    for edge in edges:
        if edge["source"] in by_id and edge["target"] in by_id:
            adjacency[edge["source"]].append(edge)
    prep = time.perf_counter() - start
    start = time.perf_counter()
    q = "synthetic claim 42"
    hits = [n for n in nodes if q in (n["id"] + n["title"] + n["excerpt"]).lower()]
    search = time.perf_counter() - start
    start = time.perf_counter()
    encoded = json.dumps({"meta": {"project": "synthetic"}, "nodes": nodes, "edges": edges},
                         separators=(",", ":"))
    serialization = time.perf_counter() - start
    assert hits and len(adjacency) == size
    return {"nodes": size, "edges": len(edges), "payload_bytes": len(encoded.encode()),
            "graph_prep_ms": round(prep * 1000, 3), "search_ms": round(search * 1000, 3),
            "serialize_ms": round(serialization * 1000, 3)}


if __name__ == "__main__":
    for count in (100, 1000, 5000):
        print(json.dumps(run(count), sort_keys=True))
