# Architecture Assets

<!-- fleet-documentation-contract:start -->

## Rendering contract

PNG files are the viewer-compatible diagrams embedded in repository documents.
Same-basename SVG files are editable sources; converted Mermaid sources are
also retained as `.mmd` files under `generated/`.

Run `python3 scripts/documentation_health.py --write` after architecture or
documentation changes. The per-commit workflow rejects Mermaid-only diagrams,
missing image targets, invalid PNG files, and stale generated repository state.
<!-- fleet-documentation-contract:end -->
