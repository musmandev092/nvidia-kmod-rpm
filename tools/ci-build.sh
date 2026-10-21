#!/usr/bin/bash
# Build kmod-nvidia-<kver> for one NVIDIA version, with every build
# dependency installed from Fedora / RPM Fusion (root, after setup-repos.sh).
#
# Usage: ci-build.sh <kernel-uname-r> <akmod-nvidia epoch:version-release> <outdir>
set -euo pipefail

kver=$1
nv=$2
outdir=$3
here=$(cd "$(dirname "$0")" && pwd)
repos=(--enablerepo=updates-testing --enablerepo=updates-archive --enablerepo=rpmfusion-nonfree-updates-testing)

epoch_version=${nv%-*}          # 3:615.78.08
vr=${nv#*:}                     # 615.78.08-1.fc44

dnf -y -q install --setopt=install_weak_deps=False "${repos[@]}" \
    rpm-build kmodtool make gcc dwarves pciutils elfutils-libelf-devel kmod cpio redhat-rpm-config \
    "kernel-devel-uname-r = $kver" \
    "xorg-x11-drv-nvidia-kmodsrc = $epoch_version"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dnf -q download "${repos[@]}" --destdir "$tmp" "akmod-nvidia-$vr.x86_64"
akmod=$(echo "$tmp"/akmod-nvidia-*.rpm)
# dnf download does not check signatures: insist on RPM Fusion's key.
rpmkeys --checksig "$akmod" | grep -q ': digests signatures OK$' \
    || { echo "ERROR: $akmod is not signed by RPM Fusion" >&2; exit 1; }
(cd "$tmp" && rpm2cpio "$akmod" | cpio -idm --quiet './usr/src/akmods/*.src.rpm')
srpm=$(echo "$tmp"/usr/src/akmods/nvidia-kmod-*.src.rpm)

"$here/build-kmod.sh" "$kver" "$srpm" "$outdir"
