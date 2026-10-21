#!/usr/bin/bash
# Build the nvidia-kmod-control RPM: the one package users install.
#  - Requires the guard and the NVIDIA userspace from RPM Fusion.
#  - One rich dependency per kernel we have a module for:
#      (kmod-nvidia-K if kernel-core-uname-r = K)
#    so the kernel and its module arrive in the same dnf transaction.
#  - Replaces RPM Fusion's akmod (Obsoletes) and hides it for good with a
#    dnf5 repo override, so gcc/kernel-devel/perl never come back.
#
# Usage: make-control.sh <version> <outdir> <kernel-uname-r>...
set -euo pipefail

version=$1
outdir=$2
shift 2

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES" "$top/SPECS"

cat > "$top/SOURCES/80-nvidia-kmod-rpm.repo" <<'EOF'
# Installed by nvidia-kmod-control. NVIDIA kernel modules come prebuilt from
# the nvidia-kmod-rpm repository, so RPM Fusion's compile-on-the-machine
# akmod (which needs gcc, kernel-devel and perl) is never installed.
[rpmfusion-nonfree*]
excludepkgs=akmod-nvidia*,kmod-nvidia*
EOF

requires=""
for k in "$@"; do
    requires+="Requires:       (kmod-nvidia-$k if kernel-core-uname-r = $k)"$'\n'
done

cat > "$top/SPECS/nvidia-kmod-control.spec" <<EOF
Name:           nvidia-kmod-control
Version:        $version
Release:        1%{?dist}
Summary:        Prebuilt NVIDIA kernel modules for every installed Fedora kernel
License:        MIT
URL:            https://github.com/musmandev092/nvidia-kmod-rpm
BuildArch:      noarch
Source0:        80-nvidia-kmod-rpm.repo

Requires:       nvidia-kmod-guard
Requires:       xorg-x11-drv-nvidia
Obsoletes:      akmod-nvidia
Obsoletes:      kmod-nvidia
$requires
%description
Installs the prebuilt NVIDIA kernel module (kmod-nvidia-<kernel>) together
with every Fedora kernel, so no compiler is needed on this machine.
Kernels with a module in this release: $*

%prep

%build

%install
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/dnf5/repos.override.d/80-nvidia-kmod-rpm.repo

%files
%{_datadir}/dnf5/repos.override.d/80-nvidia-kmod-rpm.repo

%changelog
* $(LC_ALL=C date -u '+%a %b %d %Y') nvidia-kmod-rpm CI - $version-1
- Modules for: $*
EOF

rpmbuild -bb --quiet --define "_topdir $top" "$top/SPECS/nvidia-kmod-control.spec"
mkdir -p "$outdir"
cp "$top"/RPMS/noarch/nvidia-kmod-control-*.rpm "$outdir/"
