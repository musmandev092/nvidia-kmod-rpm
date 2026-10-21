#!/usr/bin/bash
# Install test against the REAL Fedora and RPM Fusion repos (as root, in a
# throwaway fedora container, after tools/setup-repos.sh).
#  - RPM Fusion's userspace still requires `nvidia-kmod >= its version`
#    (the hold-back in tests/test-dnf.sh depends on it)
#  - our kmods need no compiler, kernel-devel, perl or akmods
#  - `dnf install nvidia-kmod-control` gives a module matching the userspace
#    and pulls none of those build tools
#
# Usage: test-real.sh <dir with kmod-nvidia-*, nvidia-kmod-control, nvidia-kmod-guard RPMs>
# DRY=1 only resolves the transaction (no big download), for slow connections.
set -euo pipefail

rpms=$(cd "$1" && pwd)
dry=${DRY:-0}
build_tools='^(akmod-nvidia|akmods|gcc|kernel-devel|perl-interpreter|make|kmodtool)$'
fail() { echo "FAIL - $*"; exit 1; }

dnf -y -q install --setopt=install_weak_deps=False createrepo_c rpm-build >/dev/null
nv=$(dnf -q repoquery --latest-limit=1 --qf '%{version}\n' xorg-x11-drv-nvidia | grep .)
echo "RPM Fusion stable NVIDIA userspace: $nv"

dnf -q repoquery --requires xorg-x11-drv-nvidia-"$nv" | grep -qx "nvidia-kmod >= 3:$nv" \
    || fail "xorg-x11-drv-nvidia no longer requires 'nvidia-kmod >= 3:$nv': the version hold-back would break"
echo "ok   - RPM Fusion userspace requires nvidia-kmod >= 3:$nv"

for f in "$rpms"/kmod-nvidia-*.rpm; do
    if rpm -qpR "$f" | grep -Eiq 'gcc|kernel-devel|perl|akmod|make'; then
        fail "$(basename "$f") requires build tools"
    fi
done
echo "ok   - no kmod requires a compiler, kernel-devel, perl or akmods"

kmod=$(ls "$rpms"/kmod-nvidia-*-"$nv"-*.rpm | sort -V | tail -n1)
kver=$(rpm -qp --qf '%{NAME}\n' "$kmod")
kver=${kver#kmod-nvidia-}
echo "Testing with kernel $kver"

# A stub kernel-core with the same provides as the real one, so the test
# doesn't download a kernel and linux-firmware.
top=$(mktemp -d)
cat > "$top/kernel-core.spec" <<EOF
Name: kernel-core
Version: ${kver%%-*}
Release: $(r=${kver#*-}; echo "${r%.x86_64}")
Summary: stub
License: MIT
BuildArch: noarch
Provides: kernel-uname-r = $kver
Provides: kernel-core-uname-r = $kver
Provides: installonlypkg(kernel)
%description
stub
%install
mkdir -p %{buildroot}/usr/lib/modules/$kver
touch %{buildroot}/usr/lib/modules/$kver/vmlinuz
%files
/usr/lib/modules/$kver
EOF
rpmbuild -bb --quiet --define "_topdir $top" "$top/kernel-core.spec"
dnf -y -q install "$top"/RPMS/noarch/kernel-core-*.rpm >/dev/null

createrepo_c -q "$rpms"
cat > /etc/yum.repos.d/nvidia-kmod-rpm.repo <<EOF
[nvidia-kmod-rpm]
name=nvidia-kmod-rpm (test)
baseurl=file://$rpms
gpgcheck=0
EOF

if [[ $dry == 1 ]]; then
    out=$(dnf install --assumeno --setopt=install_weak_deps=False \
        nvidia-kmod-control xorg-x11-drv-nvidia-cuda xorg-x11-drv-nvidia-power 2>&1 || true)
    echo "$out" | grep -E "^ (kmod-nvidia|nvidia-kmod|xorg-x11-drv-nvidia) " || fail "transaction did not resolve: $out"
    echo "$out" | awk '{print $1}' | grep -Eq "$build_tools" && fail "transaction pulls build tools"
    echo "$out" | grep -q "kmod-nvidia-$kver" || fail "kmod for $kver not in the transaction"
    echo "ok   - (dry run) install resolves with kmod-nvidia-$kver and no build tools"
    echo "$out" | grep -E '^Total size|^Installing:|^ Installing'
    exit 0
fi

dnf -y -q install --setopt=install_weak_deps=False nvidia-kmod-control >/dev/null
rpm -q --qf '%{NAME}\n' -a | grep -E "$build_tools" && fail "build tools got installed"
echo "ok   - nvidia-kmod-control installed without any build tools"

have=$(modinfo -F version /usr/lib/modules/"$kver"/extra/nvidia/nvidia.ko*)
[[ $have == "$nv" ]] || fail "module version $have != userspace $nv"
echo "ok   - nvidia.ko for $kver is $have, same as the userspace"
[[ $(modinfo -F license /usr/lib/modules/"$kver"/extra/nvidia/nvidia.ko*) == "Dual MIT/GPL" ]] || fail "not the open module"
echo "ok   - open kernel module"

out=$(dnf install --assumeno --setopt=install_weak_deps=False xorg-x11-drv-nvidia-cuda xorg-x11-drv-nvidia-power 2>&1 || true)
echo "$out" | awk '{print $1}' | grep -Eq "$build_tools" && fail "CUDA/power packages pull build tools"
echo "ok   - CUDA and power packages resolve without build tools"
nvidia-kmod-guard status
echo "All real-repo tests passed"
