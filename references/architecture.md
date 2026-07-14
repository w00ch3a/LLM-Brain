# LLM-Brain v0.3 architecture reference

LLM-Brain v0.3 is a portable, filesystem-first memory lifecycle. `VERSION` is the package version (`0.3.0`); `schema.version` in a project is the storage schema (`2`). Schema-1 vaults remain readable and are migrated only through `migrate apply --all`.

## Data layers

| Layer | Location | Authority |
|---|---|---|
| Canonical semantic memory | `okf/` | Durable source of truth |
| Episodic provenance | `episodes/YYYY-MM-DD/` | Append-only history; not truth |
| Source custody | `sources/` | Full-SHA-256 content-addressed copies |
| Exceptions | `review/`, `quarantine/` | Candidates, conflicts and secret/redaction metadata |
| Derived retrieval | `indexes/` | Rebuildable |
| Derived consumption | `context-packs/`, `adapters/`, `exports/` | Rebuildable |

Each v2 write uses `brain_*` frontmatter, an atomic same-directory temporary file, `umask 077`, a portable directory lock and the hash-chained `audit.v2.tsv`. Existing unknown frontmatter and legacy episode/audit contents are preserved by migration.

## Provider protocol

The core invokes only an explicit trusted executable:

```text
reflector REQUEST_FILE EMPTY_OUTPUT_DIRECTORY
```

The request records the episode and source as untrusted data. A provider emits one or more Markdown `ReviewItem` candidates. Required candidate metadata includes kind, confidence, risk, sensitivity, authority, provider ID/version and provenance. The core validates file bounds, frontmatter, secret scan, allowed kinds and custody-backed provenance before writing review records.

An embedder is another explicit executable:

```text
embedder CANONICAL_DOCUMENT
```

Its output is exactly:

```text
model: local-model-id
dimensions: 3
vector: 0.1 -0.2 0.3
```

The vector count must equal dimensions. Cache entries are keyed by document hash and `LLM_BRAIN_EMBEDDER_VERSION`; `vectors.tsv` exists only after a valid embedding build.

Hybrid retrieval uses a separate explicit query embedder:

```text
query-embedder QUERY_TEXT_FILE
```

It returns the same three-line model, dimensions and vector format. The query model and dimensions must match the current vector index. Query embedding never makes a network call through the core.

## Promotion policy

Automatic promotion requires all of the following:

- claim, procedure or reference;
- confidence `>= 0.90`, risk `low`, sensitivity `public` or `internal`;
- exact source custody through an episode, effective approved OKF, explicit human directive, or verified runtime proof;
- provider ID and version, clean secret scan and no conflict;
- no protected-domain wording or ambiguity.

Protected domains include clinical/healthcare, security/authentication, privacy, legal, finance/payment, production control, credentials/secrets and destructive migration. Skills and adapters are always review-only. The review file and canonical file are promoted under one project lock; conflicts write a review item and leave canonical memory untouched.

## Retrieval and packs

`documents.tsv`, `terms.tsv`, `graph.tsv` and `manifest.tsv` are deterministic rebuilds from effective-approved OKF. Index status reports each derived surface as `current`, `stale` or `missing`. Lexical search is the default and continues to scan effective approved memory directly. `--expand-graph` performs deterministic one-hop expansion from a current graph index; only `links_to`, `supersedes` and `conflicts_with` edges participate. `--strategy hybrid` fuses lexical and semantic ranks with reciprocal-rank fusion over a current vector index. Stale or missing semantic/graph inputs produce explicit lexical fallback metadata.

Context packs are content-addressed by task, agent, filters, retrieval strategy and selected paths. They record the actual retrieval mode, degradation state, index manifest hash, filters and selection hash, bound excerpts to approximately four bytes/token, include a source hash/provider and point back to a relative canonical path.

## Migration rules

`migrate check` is read-only. `migrate apply --all` acquires an external sibling lock, inventories the live root, makes an SMB sibling snapshot and local tar backup, performs all changes in a sibling staging tree, compares the live manifest before cutover, then atomically renames the roots. Strict verification failure isolates the failed root and restores rollback immediately.

Migration only reconciles exact, provable records: exact registry duplicates, scaffold review placeholders, canonical scaffold retractions, exact-hash source recovery and legacy topic compatibility. A legacy MD5 record is recoverable only when the candidate bytes reproduce that MD5; the custody copy is then addressed by SHA-256 and both algorithms remain explicit in provenance. An exhaustively searched gap may be finalised as unrecoverable only with a recorded reason and no effective canonical dependency. This closes an ambiguous operational exception without inventing missing content or silently replacing a drifted hash.

An effective canonical item blocks source-gap finalisation. It may move to a current source only through `validate-source`, which requires an explicit reason, a bounded text file, a clean secret scan and exact SHA-256 custody. The former episode dependency is retained in the hash-chained audit event rather than left as an active provenance pointer. If current authority does not independently support the item, retract it instead.
