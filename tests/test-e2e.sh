#!/usr/bin/bash
# End-to-end test with REAL packages: Fedora kernels, RPM Fusion's NVIDIA
# driver, our kmods in a GPG-signed repo served over HTTP, and real GRUB boot
# entries (BLS) so the boot default can be checked after every step.
# Kernels are moved up and down; nothing here uses stubs.
#
# Usage: test-e2e.sh <dir with real kmod-nvidia RPMs> <old kernel> <new kernel>
#   kernels as uname -r, e.g. 6.19.10-300.fc44.x86_64 7.2.11-200.fc44.x86_64
# Root, in a throwaway fedora container, after tools/setup-repos.sh.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
kmods=$(cd "$1" && pwd)
old=$2 new=$3
srv=/srv/nvidia-kmod-rpm
repo=$srv/repo/fedora-$(rpm -E %fedora)/x86_64
build_tools='^(akmod-nvidia|akmods|gcc|kernel-devel|perl-interpreter|make|kmodtool)$'

step() { echo; echo "== $*"; }
ok() { echo "ok   - $*"; }
fail() {
    echo "FAIL - $*"
    nvidia-kmod-guard status 2>/dev/null || true
    rpm -qa 'kernel*' 'kmod-nvidia*' 'xorg-x11-drv-nvidia' nvidia-kmod-control | sort
    exit 1
}
default() { local k; k=$(grubby --default-kernel 2>/dev/null) || true; echo "${k##*/vmlinuz-}"; }
expect_default() { [[ $(default) == "$1" ]] || fail "$2 (boot default is '$(default)', expected $1)"; ok "$2"; }
has() { rpm -q "$@" >/dev/null 2>&1; }
module_ok() {  # module_ok <kernel>: module installed and matches the userspace version
    local want have
    want=$(rpm -q --qf '%{VERSION}' xorg-x11-drv-nvidia)
    have=$(modinfo -F version "/usr/lib/modules/$1/extra/nvidia/nvidia.ko.xz" 2>/dev/null) || have=none
    [[ $have == "$want" ]] || fail "module for $1 is '$have', userspace is $want"
    ok "nvidia.ko for $1 is $have = NVIDIA userspace"
}
D() { dnf -y -q --setopt=install_weak_deps=False "$@" 2>&1 | grep -Ev '^(>>>|\[|Warning: skipped OpenPGP)' || true; }
evr() { local u=${1%.x86_64}; echo "$u"; }

step "Boot environment: GRUB with BLS entries, like a Fedora install"
dnf -y -q install --setopt=install_weak_deps=False grub2-tools grub2-common grubby systemd-udev dracut \
    rpm-build rpm-sign createrepo_c kmod gnupg2 python3 >/dev/null
[[ -s /etc/machine-id ]] || systemd-machine-id-setup >/dev/null
cat > /etc/default/grub <<EOF
GRUB_TIMEOUT=5
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_ENABLE_BLSCFG=true
GRUB_CMDLINE_LINUX="rhgb quiet"
EOF
echo "root=UUID=00000000-0000-0000-0000-000000000000 ro rhgb quiet" > /etc/kernel/cmdline
mkdir -p /boot/loader/entries /boot/grub2
# grub2-editenv probes the disk behind the default env file (/boot/grub2/grubenv)
# and a container has none. Shim: the same binary, given an explicit file
# (which it does not probe). Fedora's kernel-install plugins, grubby, the BLS
# entries and our guard all run unchanged.
if [[ ! -e /usr/bin/grub2-editenv.real ]]; then
    mkdir -p /var/lib/test-grub
    { printf '# GRUB Environment Block\n'; head -c 999 /dev/zero | tr '\0' '#'; } > /var/lib/test-grub/grubenv
    mv /usr/bin/grub2-editenv /usr/bin/grub2-editenv.real
    printf '%s\n' '#!/usr/bin/bash' 'f=$1; shift' \
        '[[ $f == - || $f == /boot/grub2/grubenv ]] && f=/var/lib/test-grub/grubenv' \
        'exec /usr/bin/grub2-editenv.real "$f" "$@"' > /usr/bin/grub2-editenv
    chmod +x /usr/bin/grub2-editenv
    # grubby --default-kernel greps this path directly, so it must show the same file.
    ln -sfn /var/lib/test-grub/grubenv /boot/grub2/grubenv
fi
grub2-editenv - list >/dev/null || fail "grubenv not usable"
ok "fake /boot ready"

step "Our repo: signed with a throwaway key, served over HTTP"
export GNUPGHOME=/root/.gnupg-test
mkdir -p "$repo"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key "e2e test key" ed25519 sign 1d 2>/dev/null
fpr=$(gpg --list-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')
gpg --armor --export "$fpr" > "$srv/key.asc"
"$here/tools/build-guard.sh" "$repo" >/dev/null
publish() {  # publish <kernels that have a module>...
    rm -f "$repo"/nvidia-kmod-control-*.rpm
    "$here/tools/make-control.sh" "$(date -u +%Y%m%d.%H%M%S)" "$repo" "$@" >/dev/null 2>&1
    rpm --define "_openpgp_sign_id $fpr" --addsign "$repo"/*.rpm >/dev/null
    createrepo_c -q --update "$repo"
    gpg --batch --yes --local-user "$fpr" --detach-sign --armor "$repo/repodata/repomd.xml" 2>/dev/null
    sleep 1   # control versions are per second
}
add_kmod() { cp "$kmods"/kmod-nvidia-"$1"-*.rpm "$repo/"; }
(cd "$srv" && exec python3 -m http.server 8088 --bind 127.0.0.1 >/dev/null 2>&1) &
sleep 1
sed -e "s|@URL@|http://127.0.0.1:8088|" -e "s|RPM-GPG-KEY-nvidia-kmod-rpm.asc|key.asc|" \
    "$here/site/nvidia-kmod-rpm.repo" > /etc/yum.repos.d/nvidia-kmod-rpm.repo
echo "metadata_expire=0" >> /etc/yum.repos.d/nvidia-kmod-rpm.repo
add_kmod "$old"
publish "$old"
ok "repo has a module for $old only"

step "Machine with kernel $old only"
D install "kernel-$(evr "$old")"
has "kernel-core-$(evr "$old")" || fail "kernel $old not installed"
expect_default "$old" "boot default is $old"

step "sudo dnf install nvidia-kmod-control (real NVIDIA driver from RPM Fusion)"
D install nvidia-kmod-control
has "kmod-nvidia-$old" || fail "kmod for $old not installed"
ok "kmod-nvidia-$old installed with the driver"
module_ok "$old"
rpm -qa --qf '%{NAME}\n' | grep -E "$build_tools" && fail "build tools installed"
ok "no akmod, gcc, kernel-devel, perl or make installed"

step "Fedora releases kernel $new, CI has not built its module yet: dnf upgrade"
D upgrade
has "kernel-core-$(evr "$new")" && fail "kernel $new installed without its module"
ok "kernel $new held back"
expect_default "$old" "still booting $old"

step "CI publishes the module for $new: dnf upgrade"
add_kmod "$new"
publish "$old" "$new"
D upgrade
has "kernel-core-$(evr "$new")" || fail "kernel $new not installed"
has "kmod-nvidia-$new" || fail "kmod for $new not installed"
ok "kernel $new and its module installed in the same upgrade"
module_ok "$new"
expect_default "$new" "boot default moved to $new"

step "Kernel down: remove $new"
D remove "kernel-$(evr "$new")" "kernel-core-$(evr "$new")" "kernel-modules-$(evr "$new")" "kernel-modules-core-$(evr "$new")"
has "kmod-nvidia-$new" && fail "kmod for removed kernel still installed"
ok "its kmod was removed with it"
expect_default "$old" "boot default back on $old"
module_ok "$old"

step "Kernel up again: dnf upgrade"
D upgrade
has "kmod-nvidia-$new" || fail "kmod for $new missing after reinstall"
expect_default "$new" "boot default on $new again"
module_ok "$new"

step "Safety net: $new is (re)installed while its module is missing"
rpm -e --nodeps "kmod-nvidia-$new"
kernel-install add "$new" "/usr/lib/modules/$new/vmlinuz" >/dev/null 2>&1 || true
expect_default "$old" "guard kept $old (has the module) as boot default"
nvidia-kmod-guard status
D install "kmod-nvidia-$new"
expect_default "$new" "module back: guard switched the boot default to $new"

step "Final state"
rpm -qa --qf '%{NAME}\n' | grep -E "$build_tools" && fail "build tools installed"
ok "still no build tools"
has akmod-nvidia && fail "akmod-nvidia came back"
ok "akmod-nvidia never came back"
nvidia-kmod-guard status
echo
echo "All end-to-end tests passed"
