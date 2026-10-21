#!/usr/bin/bash
# Build the nvidia-kmod-guard RPM from packaging/.
# Usage: build-guard.sh <outdir>
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"
cp "$here"/packaging/nvidia-kmod-guard "$here"/packaging/99-nvidia-kmod-guard.install "$top/SOURCES/"
rpmbuild -bb --quiet --define "_topdir $top" "$here/packaging/nvidia-kmod-guard.spec"
mkdir -p "$1"
cp "$top"/RPMS/noarch/nvidia-kmod-guard-*.rpm "$1/"
