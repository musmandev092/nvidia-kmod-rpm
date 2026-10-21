#!/usr/bin/bash
# Put together the full (unsigned-new + signed-kept) package set for a repo:
# the kmods we keep from the live site, the ones built in this run, a fresh
# guard and a fresh nvidia-kmod-control listing every kernel that has a module
# for RPM Fusion's stable NVIDIA version.
#
# Usage: assemble.sh <plan.json> <dir of new kmods> <outdir> <pages url>
set -euo pipefail

plan=$1 new=$2 out=$3 pages=$4
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"

find "$new" -name 'kmod-nvidia-*.rpm' -exec cp -v {} "$out/" \;

jq -r '.keep[] | "\(.file) \(.sha256)"' "$plan" | while read -r file sha; do
    curl -fsSL --retry 3 -o "$out/$file" "$pages/repo/fedora-$(rpm -E %fedora)/x86_64/$file"
    echo "$sha  $out/$file" | sha256sum -c --quiet
    echo "kept $file"
done

"$here/build-guard.sh" "$out"

stable=$(jq -r .nvidia_stable "$plan")
kernels=()
for f in "$out"/kmod-nvidia-*.rpm; do
    [[ -e $f ]] || continue
    read -r name evr < <(rpm -qp --qf '%{NAME} %{EPOCH}:%{VERSION}-%{RELEASE}\n' "$f")
    [[ $evr == "$stable" ]] && kernels+=("${name#kmod-nvidia-}")
done
[[ ${#kernels[@]} -gt 0 ]] || { echo "ERROR: no kmod for RPM Fusion's stable NVIDIA $stable" >&2; exit 1; }
"$here/make-control.sh" "$(date -u +%Y%m%d.%H%M%S)" "$out" "${kernels[@]}"
echo "nvidia-kmod-control installs modules for: ${kernels[*]}"
