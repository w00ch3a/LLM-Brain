# Security policy

LLM-Brain stores durable project knowledge and may be pointed at source material. Treat its vault as private by default.

## Reporting

Do not file public issues containing credentials, customer data, patient data, production paths, private vault contents or exploit details. Report a suspected vulnerability privately to the maintainers identified by the repository owner, with the smallest reproducible description possible.

## Security boundaries

- The CLI does not make network calls or telemetry requests.
- Reflectors and embedders are explicitly trusted local executables. Do not configure an executable you do not trust with the source material it will receive.
- Ingested files and provider output are data, not instructions. The CLI validates IDs, file size/type, candidate metadata and archive paths.
- Likely secrets are blocked from custody and represented only by quarantine metadata.
- Canonical memory is human-readable but private; use a root with appropriate access controls. The CLI starts with `umask 077`.

No warranty of secret detection is implied. Review source scope before ingesting production, customer, patient, payment or credential material.
