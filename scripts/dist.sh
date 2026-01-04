#!/usr/bin/env bash
set -euo pipefail
# Build a small distribution folder (repository.yaml + scripts + op25_haos_experiment)
# so you can drag-and-drop into an OP25 repo root without overwriting the whole repo.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${here}/dist/op25-haos-addon-repo"
rm -rf "${out}"
mkdir -p "${out}/scripts"

cp -v "${here}/repository.yaml" "${out}/repository.yaml"
cp -av "${here}/op25_haos_experiment" "${out}/op25_haos_experiment"
cp -v "${here}/scripts/haos.sh" "${out}/scripts/haos.sh"
cp -v "${here}/scripts/dist.sh" "${out}/scripts/dist.sh"

echo
echo "Built: ${out}"
echo "Drag these into your OP25 repo root:"
echo "  repository.yaml"
echo "  scripts/"
echo "  op25_haos_experiment/"

echo
if command -v zip >/dev/null 2>&1; then
  (cd "${here}/dist" && zip -r op25-haos-addon-repo.zip op25-haos-addon-repo >/dev/null)
  echo "Zipped: ${here}/dist/op25-haos-addon-repo.zip"
else
  echo "Tip: install 'zip' to also generate a .zip automatically."
fi
