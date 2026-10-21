#!/usr/bin/bash
# Unit test for nvidia-kmod-guard with a fake /usr/lib/modules, grubby and
# modinfo. Needs no root and no real kernels.
set -euo pipefail

guard=$(cd "$(dirname "$0")/.." && pwd)/packaging/nvidia-kmod-guard
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

export NVIDIA_KMOD_GUARD_MODDIR=$t/modules
export NVIDIA_KMOD_GUARD_STATE=$t/state
export NVIDIA_KMOD_GUARD_BOOT=/boot
export NVIDIA_KMOD_GUARD_GRUBBY=$t/grubby
export NVIDIA_KMOD_GUARD_MODINFO=$t/modinfo
export NVIDIA_KMOD_GUARD_USERSPACE=615.78.08

# Fake grubby: the default kernel lives in a file.
cat > "$t/grubby" <<EOF
#!/usr/bin/bash
case \$1 in
    --default-kernel) cat "$t/default" ;;
    --set-default) echo "\$2" > "$t/default" ;;
esac
EOF
# Fake modinfo: the "module" file contains its version.
printf '#!/usr/bin/bash\ncat "$3"\n' > "$t/modinfo"
chmod +x "$t/grubby" "$t/modinfo"

kernel() { mkdir -p "$t/modules/$1"; touch "$t/modules/$1/vmlinuz"; echo "/boot/vmlinuz-$1" > "$t/default"; }
kmod() { mkdir -p "$t/modules/$1/extra/nvidia"; echo "$2" > "$t/modules/$1/extra/nvidia/nvidia.ko.xz"; }
default() { local d; d=$(cat "$t/default"); echo "${d#/boot/vmlinuz-}"; }
expect() {
    if [[ $(default) == "$1" ]]; then echo "ok   - $2"
    else echo "FAIL - $2: default is $(default), expected $1"; exit 1; fi
}
sync() { "$guard" sync 2>/dev/null; }

K1=7.2.11-200.fc44.x86_64 K2=7.2.12-200.fc44.x86_64 K3=7.3.1-200.fc44.x86_64

kernel "$K1"; kmod "$K1" 615.78.08; sync
expect "$K1" "kernel with its module stays default"

kernel "$K2"; sync
expect "$K1" "new kernel without module: previous kernel stays default"
[[ -f $t/state/held ]] || { echo "FAIL - held marker missing"; exit 1; }

kmod "$K2" 615.78.08; sync
expect "$K2" "module arrives: new kernel becomes default"
[[ ! -f $t/state/held ]] || { echo "FAIL - held marker not cleared"; exit 1; }

kernel "$K3"; kmod "$K3" 610.00.00; sync
expect "$K2" "module of the wrong NVIDIA version counts as missing"

kmod "$K3" 615.78.08; sync
expect "$K3" "matching module installed: newest kernel is default again"

echo "/boot/vmlinuz-$K1" > "$t/default"; sync
expect "$K1" "a kernel the user picked is left alone"

echo "/boot/vmlinuz-$K3" > "$t/default"
NVIDIA_KMOD_GUARD_USERSPACE=620.10.01 sync
expect "$K3" "no kernel matches the userspace: nothing is changed"

NVIDIA_KMOD_GUARD_USERSPACE='' sync
expect "$K3" "no NVIDIA driver installed: nothing is changed"

status=$("$guard" status)
grep -Eq "^\* $K3 +ok$" <<<"$status" || { echo "FAIL - status output"; echo "$status"; exit 1; }
echo "ok   - status marks the default kernel"
echo "All guard tests passed"
