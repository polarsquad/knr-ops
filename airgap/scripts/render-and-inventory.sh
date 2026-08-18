#!/usr/bin/env bash
# airgap/scripts/render-and-inventory.sh
# Render every kustomize overlay (local-host + workload) and harvest container
# images via `zarf dev find-images`. Idempotent; output goes to airgap/rendered/.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
mkdir -p airgap/rendered
rm -f airgap/rendered/*.yaml
shopt -s nullglob
ok=0; fail=0
for dir in $(find mgmt/local-host workload -name kustomization.yaml -exec dirname {} \; | sort -u); do
  out="airgap/rendered/$(echo "$dir" | sed 's#/#__#g').yaml"
  if kubectl kustomize "$dir" > "$out" 2>/tmp/rend.err; then
    n=$(grep -c '^kind:' "$out" || true)
    echo "OK   $dir -> $out ($n docs)"
    ok=$((ok+1))
  else
    echo "FAIL $dir : $(head -1 /tmp/rend.err)"
    fail=$((fail+1))
  fi
done
echo "---- rendered: $ok ok, $fail fail ----"
[ "$fail" -eq 0 ] || { echo "some overlays failed to render"; exit 1; }
