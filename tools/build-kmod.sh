#!/usr/bin/bash
# Build kmod-nvidia-<kver> from RPM Fusion's akmod SRPM, the same way
# akmodsbuild does, but without akmods installed and inside a container.
#
# Usage: build-kmod.sh <kernel-uname-r> <nvidia-kmod.src.rpm> <outdir>
# Needs (in the container): rpm-build kmodtool make gcc dwarves pciutils
# elfutils-libelf-devel kmod cpio, kernel-devel-<kver>, xorg-x11-drv-nvidia-kmodsrc.
# RPMBUILD_EXTRA=--nodeps is only for local prototypes with host files mounted.
set -euo pipefail

kver=$1
srpm=$2
outdir=$3

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT

# --with kmod_nvidia_open: force the open module. Without it the spec runs
# lspci at build time to choose, and a CI runner has no NVIDIA GPU.
rpmbuild --rebuild "$srpm" \
    --define "_topdir $top" \
    --define "kernels $kver" \
    --define "_smp_mflags -j$(nproc)" \
    --with kmod_nvidia_open \
    ${RPMBUILD_EXTRA:-}

mkdir -p "$outdir"
find "$top/RPMS" -name 'kmod-nvidia-*.rpm' -exec cp -v {} "$outdir/" \;

# Fail if the build silently produced the closed module (license "NVIDIA"),
# missed a module, or targeted another kernel.
rpm2cpio "$outdir"/kmod-nvidia-"$kver"-*.rpm | (cd "$top" && cpio -idm --quiet)
for m in nvidia nvidia-drm nvidia-modeset nvidia-peermem nvidia-uvm; do
    ko=$(echo "$top"/lib/modules/"$kver"/extra/nvidia/"$m".ko*)
    lic=$(modinfo -F license "$ko")
    [[ $lic == Dual* ]] || { echo "ERROR: $m license is '$lic', expected open module" >&2; exit 1; }
    [[ $(modinfo -F vermagic "$ko") == "$kver "* ]] || { echo "ERROR: $m vermagic mismatch" >&2; exit 1; }
done
echo "OK: open kernel modules built for $kver"
