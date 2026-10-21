#!/usr/bin/bash
# Add RPM Fusion and Fedora's updates-archive to a fedora container (as root).
# RPM Fusion's release RPMs are checked against the RPM Fusion keys pinned in
# keys/ before they are installed, so a tampered download is refused.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
rel=$(rpm -E %fedora)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for repo in free nonfree; do
    curl -fsSL --connect-timeout 20 --retry 3 -o "$tmp/rpmfusion-$repo-release.rpm" \
        "https://download1.rpmfusion.org/$repo/fedora/rpmfusion-$repo-release-$rel.noarch.rpm"
done

db="$tmp/rpmdb"
mkdir -p "$db"
rpmkeys --dbpath "$db" --import "$here"/keys/RPM-GPG-KEY-rpmfusion-*-fedora-2020
for f in "$tmp"/rpmfusion-*-release.rpm; do
    rpmkeys --dbpath "$db" --checksig "$f" | grep -q ': digests signatures OK$' \
        || { echo "ERROR: $f is not signed by a pinned RPM Fusion key" >&2; exit 1; }
done

rpm --import "$here"/keys/RPM-GPG-KEY-rpmfusion-*-fedora-2020
dnf -y -q install --setopt=install_weak_deps=False fedora-repos-archive "$tmp"/rpmfusion-*-release.rpm
