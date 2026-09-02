# Screenshot artifacts

Generated screenshot output lives here and is intentionally ignored by Git:

- `raw/` contains provenance-backed simulator captures.
- `promotional/` contains framed, copy-led compositions generated from `raw/`.

Run `marketing/screenshots/capture-all.sh` to refresh both trees, or pass
`--verify-only` to validate the existing artifacts without recapturing them.
