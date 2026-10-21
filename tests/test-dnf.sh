#!/usr/bin/bash
# Update-scenario test: does plain `dnf install` / `dnf upgrade` always end
# with a kernel module that matches the NVIDIA userspace, and never pull
# RPM Fusion's akmod?
#
# Kernels, RPM Fusion's NVIDIA packages and our kmods are replaced by tiny
# stub RPMs that copy the real dependencies (checked against the real
# packages by tests/test-real.sh). nvidia-kmod-control and nvidia-kmod-guard
# are the real ones. Runs as root in a throwaway fedora container that has
# rpm-build, createrepo_c, grubby and kmod installed.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
w=$(mktemp -d)
mkdir -p "$w"/{updates,rpmfusion,ours,build}

V1=615.78.08 V2=620.10.01
K1=9.1.0-100.fc44.x86_64 K2=9.2.0-100.fc44.x86_64 K3=9.3.0-100.fc44.x86_64

# stub <repo> <name> <epoch> <version> <release> [spec lines...]
stub() {
    local repo=$1 name=$2 epoch=$3 version=$4 release=$5
    shift 5
    {
        echo "Name: $name"
        [[ $epoch != 0 ]] && echo "Epoch: $epoch"
        echo "Version: $version"
        echo "Release: $release"
        echo "Summary: stub"
        echo "License: MIT"
        echo "BuildArch: noarch"
        printf '%s\n' "$@"
        printf '%%description\nstub\n%%files\n%%changelog\n* Wed Oct 21 2026 test - 0-0\n- stub\n'
    } > "$w/build/$name.spec"
    rpmbuild -bb --quiet --define "_topdir $w/build" --define "_rpmdir $w/$repo" \
        --define '_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm' "$w/build/$name.spec"
}
kernel() {  # kernel <uname-r>: kernel, kernel-modules, kernel-core like Fedora's
    local v=${1%%-*} r=${1#*-}
    r=${r%.x86_64}
    stub updates kernel-core 0 "$v" "$r" \
        "Provides: kernel-uname-r = $1" "Provides: kernel-core-uname-r = $1" "Provides: installonlypkg(kernel)"
    stub updates kernel-modules 0 "$v" "$r" "Provides: kernel-modules-uname-r = $1" \
        "Requires: kernel-core-uname-r = $1" "Provides: installonlypkg(kernel-module)"
    stub updates kernel 0 "$v" "$r" "Requires: kernel-core-uname-r = $1" \
        "Requires: kernel-modules-uname-r = $1" "Provides: installonlypkg(kernel)"
}
userspace() {  # userspace <version>: RPM Fusion's xorg-x11-drv-nvidia + akmod
    stub rpmfusion xorg-x11-drv-nvidia 3 "$1" 1.fc44 \
        "Provides: nvidia-kmod-common = 3:$1" "Requires: nvidia-kmod >= 3:$1"
    stub rpmfusion akmod-nvidia 3 "$1" 1.fc44 \
        "Provides: nvidia-kmod = 3:$1-1.fc44" "Requires: nvidia-kmod-common >= 3:$1"
    stub rpmfusion kmod-nvidia 3 "$1" 1.fc44 "Requires: akmod-nvidia = 3:$1-1.fc44"
}
kmod() {  # kmod <uname-r> <version>: our prebuilt module (same deps as the real one)
    stub ours "kmod-nvidia-$1" 3 "$2" 1.fc44 \
        "Provides: nvidia-kmod = 3:$2-1.fc44" "Provides: kernel-modules-for-kernel = $1" \
        "Requires: kernel-uname-r = $1" "Requires: nvidia-kmod-common >= 3:$2"
}
control() {  # control <version> <kernels...>
    rm -f "$w"/ours/nvidia-kmod-control-*.rpm
    "$here/tools/make-control.sh" "$@" >/dev/null
}
publish() { local d; for d in updates rpmfusion ours; do createrepo_c -q --update "$w/$d"; done; }

# Only the stub repos from here on (repo ids as on a real system).
mkdir -p /etc/yum.repos.d.real
mv /etc/yum.repos.d/*.repo /etc/yum.repos.d.real/ 2>/dev/null || true
cat > /etc/yum.repos.d/stubs.repo <<EOF
[updates]
name=stub Fedora updates
baseurl=file://$w/updates
gpgcheck=0
metadata_expire=0
[rpmfusion-nonfree-updates]
name=stub RPM Fusion nonfree
baseurl=file://$w/rpmfusion
gpgcheck=0
metadata_expire=0
[nvidia-kmod-rpm]
name=stub nvidia-kmod-rpm
baseurl=file://$w/ours
gpgcheck=0
metadata_expire=0
EOF
"$here/tools/build-guard.sh" "$w/ours"

D() { dnf -y -q --setopt=install_weak_deps=False "$@"; }
installed() { rpm -q "$@" >/dev/null 2>&1; }
check() {  # check <description> <command...>
    if "${@:2}"; then echo "ok   - $1"; else echo "FAIL - $1"; rpm -qa | grep -E 'nvidia|kernel' | sort; exit 1; fi
}
evr() { rpm -q --qf '%{VERSION}\n' "$1"; }

echo "== Laptop today: kernel K1, NVIDIA $V1 with RPM Fusion's akmod"
kernel "$K1"; userspace "$V1"; publish
D install kernel xorg-x11-drv-nvidia akmod-nvidia
check "akmod installed (starting point)" installed akmod-nvidia

echo "== Switch: dnf install nvidia-kmod-control"
kmod "$K1" "$V1"; control 1 "$w/ours" "$K1"; publish
D install nvidia-kmod-control
check "akmod-nvidia removed" bash -c "! rpm -q akmod-nvidia >/dev/null"
check "kmod for K1 installed" installed "kmod-nvidia-$K1"
check "guard installed" installed nvidia-kmod-guard
check "RPM Fusion's akmod is hidden from dnf" test -z "$(dnf -q repoquery akmod-nvidia kmod-nvidia 2>/dev/null)"
dnf -q -y install akmod-nvidia kmod-nvidia >/dev/null 2>&1 || true
check "asking for the akmod still doesn't install it" bash -c "! rpm -q akmod-nvidia >/dev/null"

echo "== Fedora ships kernel K2; CI already built its module"
kernel "$K2"; kmod "$K2" "$V1"; control 2 "$w/ours" "$K1" "$K2"; publish
D upgrade
check "kernel K2 installed" bash -c "rpm -q kernel | grep -q 9.2.0"
check "kmod for K2 came in the same upgrade" installed "kmod-nvidia-$K2"

echo "== RPM Fusion ships NVIDIA $V2 before CI built modules for it"
userspace "$V2"; publish
D upgrade
check "userspace held at $V1 (no module for $V2 yet)" test "$(evr xorg-x11-drv-nvidia)" = "$V1"

echo "== CI builds $V2 modules"
kmod "$K1" "$V2"; kmod "$K2" "$V2"; publish
D upgrade
check "userspace now $V2" test "$(evr xorg-x11-drv-nvidia)" = "$V2"
check "kmod K1 upgraded to $V2" test "$(evr "kmod-nvidia-$K1")" = "$V2"
check "kmod K2 upgraded to $V2" test "$(evr "kmod-nvidia-$K2")" = "$V2"

echo "== Fedora ships kernel K3 before CI built its module"
kernel "$K3"; publish
D upgrade
check "kernel K3 held back (no module yet), rest of the system upgraded" \
    bash -c "! rpm -q kernel-core kernel kernel-modules | grep -q 9.3.0"
check "asking for K3 explicitly is refused with a conflict" bash -c "! dnf -y -q install kernel-9.3.0 >/dev/null 2>&1"

echo "== CI catches up with K3"
kmod "$K3" "$V2"; control 3 "$w/ours" "$K1" "$K2" "$K3"; publish
D upgrade
check "kernel K3 installed" bash -c "rpm -q kernel | grep -q 9.3.0"
check "and its kmod in the same upgrade" installed "kmod-nvidia-$K3"

echo "== Old kernel K1 is removed"
D remove "kernel-${K1%.x86_64}" "kernel-modules-${K1%.x86_64}" "kernel-core-${K1%.x86_64}"
check "its kmod went with it" bash -c "! rpm -q kmod-nvidia-$K1 >/dev/null"
D upgrade
check "upgrade still works afterwards" true

check "akmod-nvidia never came back" bash -c "! rpm -q akmod-nvidia >/dev/null"
check "every kmod matches the userspace" bash -c \
    "test -z \"\$(rpm -qa --qf '%{NAME} %{VERSION}\n' 'kmod-nvidia-*' | grep -v ' $V2\$')\""
echo "All dnf scenario tests passed"
