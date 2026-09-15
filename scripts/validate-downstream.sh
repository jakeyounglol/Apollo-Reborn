#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD=false

if [[ "${1:-}" == "--build" ]]; then
  BUILD=true
elif [[ $# -gt 0 ]]; then
  printf 'usage: %s [--build]\n' "$0" >&2
  exit 2
fi

python3 "$ROOT/scripts/documentation_health.py" --check
python3 -m py_compile \
  "$ROOT/scripts/generate_release_notes.py" \
  "$ROOT/scripts/update_source_json.py" \
  "$ROOT/scripts/validate_release_inputs.py"

bash -n \
  "$ROOT/build-ipa.sh" \
  "$ROOT/patch.sh" \
  "$ROOT/scripts/publish-upstream-sync-review.sh" \
  "$ROOT/scripts/build_release_variants.sh" \
  "$ROOT/scripts/validate_release_variants.sh"

bash "$ROOT/tests/upstream_sync_publish_test.sh"

if [[ "$BUILD" == true ]]; then
  : "${THEOS:?THEOS must point to a Theos checkout for --build}"
  make -C "$ROOT" package FINALPACKAGE=1
  compgen -G "$ROOT/packages/*.deb" >/dev/null || {
    printf 'Apollo-Reborn build did not produce a package\n' >&2
    exit 1
  }
fi

printf 'Apollo-Reborn downstream validation passed\n'
