#!/usr/bin/bash
# Decide which kmods to build and which published ones to keep.
#
# Kernels: Fedora's release kernel (what a fresh install boots), plus the
# newest KEEP_KERNELS kernels seen in updates / updates-testing / already
# published. updates-testing usually lands 3-7 days before stable, so the
# module is ready before users get the kernel.
# NVIDIA: the newest akmod-nvidia in RPM Fusion stable and in updates-testing.
#
# Usage: plan.sh <published kmods.json>  (root, after setup-repos.sh)
# Prints JSON: {kernels, nvidia, nvidia_stable, builds: [{kver, nvidia}], keep: [...]}
set -euo pipefail

published=$1
keep_kernels=${KEEP_KERNELS:-3}

latest() {  # latest <repo> <queryformat> <package>
    dnf -q repoquery --disablerepo='*' --enablerepo="$1" --arch=x86_64 \
        --latest-limit=1 --qf "$2\n" "$3" 2>/dev/null | grep . || true
}

kfmt='%{version}-%{release}.%{arch}'
ga=$(latest fedora "$kfmt" kernel-devel)
[[ -n $ga ]] || { echo "ERROR: no kernel-devel in the fedora repo" >&2; exit 1; }
recent=$({
    latest updates "$kfmt" kernel-devel
    latest updates-testing "$kfmt" kernel-devel
    jq -r '.[].kver' "$published"
} | grep -vxF "$ga" | sort -uV | tail -n "$keep_kernels")

nfmt='%{epoch}:%{version}-%{release}'
stable=$(latest rpmfusion-nonfree-updates "$nfmt" akmod-nvidia)
[[ -n $stable ]] || stable=$(latest rpmfusion-nonfree "$nfmt" akmod-nvidia)
[[ -n $stable ]] || { echo "ERROR: no akmod-nvidia in RPM Fusion" >&2; exit 1; }
testing=$(latest rpmfusion-nonfree-updates-testing "$nfmt" akmod-nvidia)
nvidia=$stable
if [[ -n $testing && $(printf '%s\n%s\n' "$stable" "$testing" | sort -V | tail -n1) != "$stable" ]]; then
    nvidia+=$'\n'$testing
fi

jq -n \
    --arg kernels "$(printf '%s\n%s\n' "$ga" "$recent" | grep .)" \
    --arg nvidia "$nvidia" --arg stable "$stable" \
    --slurpfile pub "$published" '
    ($kernels | split("\n")) as $k | ($nvidia | split("\n")) as $n |
    ($pub[0] | map(select((.kver | IN($k[])) and (.nvidia | IN($n[]))))) as $keep |
    {kernels: $k, nvidia: $n, nvidia_stable: $stable,
     builds: [ $k[] as $kv | $n[] as $nv
               | select([$keep[] | select(.kver == $kv and .nvidia == $nv)] | length == 0)
               | {kver: $kv, nvidia: $nv} ],
     keep: $keep}'
