# Plan: `nvidia-kmod-rpm`: prebuilt NVIDIA kernel modules for Fedora

Status: **APPROVED and implemented** (2026-10-21). See README.md for the result.

Change during implementation: the separate `Conflicts:` gate (§3 option C) was dropped. RPM Fusion's
own dependencies already do it: `xorg-x11-drv-nvidia` requires `nvidia-kmod >= <its version>`
(checked by tests/test-real.sh on every run), so dnf holds the userspace back until a matching kmod
exists (proven by tests/test-dnf.sh). `nvidia-kmod-control` keeps the auto-install rules, Obsoletes
`akmod-nvidia` and hides it with a dnf5 repo override. Guard package is named `nvidia-kmod-guard`.

Goal: a clean Fedora 44 install gets the NVIDIA driver with `dnf install`, **without**
`akmod-nvidia`, gcc, kernel-devel or Perl on the machine. CI compiles; the laptop only installs.

Scope (v1): Fedora 44, x86_64, **open** kernel module only (Turing and newer, which covers the
RTX A4500 / Ampere). Secure Boot is off, so modules are not signed for the kernel (RPMs and repo
metadata *are* GPG-signed).

---

## 1. What the user's machine ends up with

| Package | From | Size | Notes |
|---|---|---|---|
| `kmod-nvidia-<kver>` | **this repo** | ~10 MB each (§7) | built by CI from RPM Fusion's akmod SRPM, unmodified source |
| `nvidia-kmod-control` | **this repo** | tiny | the version gate + auto-install rules (§3) |
| `nvidia-kmod-boot-guard` | **this repo** | tiny | keeps the old kernel as boot default until its kmod exists (§4) |
| `xorg-x11-drv-nvidia`, `-libs`, `-cuda`, `-cuda-libs`, `-power`, `nvidia-kmod-common`, … | **RPM Fusion**, unchanged | big | userspace stays with RPM Fusion; we do **not** mirror it (§3) |

On the machine, RPM Fusion nonfree gets one line: `excludepkgs=akmod-nvidia*,kmod-nvidia*`
so dnf never pulls the akmod (and its ~275 build packages) back in.

Install:
```
sudo dnf config-manager addrepo --from-repofile=https://musmandev092.github.io/nvidia-kmod-rpm/nvidia-kmod.repo
sudo dnf config-manager setopt 'rpmfusion-nonfree*.excludepkgs=akmod-nvidia*,kmod-nvidia*'
sudo dnf install nvidia-kmod-control xorg-x11-drv-nvidia-cuda xorg-x11-drv-nvidia-power
```

---

## 2. CI (`.github/workflows/build.yml`)

Same shape as `claude-desktop-rpm`: scheduled, no human step, signed, attested, security job.

| Job | What it does |
|---|---|
| **check** (cron, every 3 h) | In a `fedora:44` container with RPM Fusion release RPMs installed: `dnf repoquery` the newest `kernel-devel` in **`updates` and `updates-testing`** (testing lands 3–7 days before stable, so kmods are ready first), and the newest `akmod-nvidia` in **`rpmfusion-nonfree-updates` and `-updates-testing`**. Compares the wanted set `{kernels} × {nvidia versions}` with what the published repo already has (`dnf repoquery --repofrompath` against our Pages repo). Outputs a JSON matrix of **missing** builds only. |
| **build** (matrix, one job per kernel × nvidia) | `fedora:44` container: install `kernel-devel-<kver>`, `xorg-x11-drv-nvidia-kmodsrc-<nv>`, `rpm-build kmodtool gcc make dwarves …`, then `scripts/build-kmod.sh` (what the prototype ran). Checks: all five `.ko` files present, license `Dual MIT/GPL` (open), `vermagic` = `<kver>`, and `rpm -qpR` contains **no** gcc/kernel-devel/perl. |
| **test** | Fresh `fedora:44` container: add RPM Fusion + the just-built repo, `dnf install` the kmod with the matching userspace, assert dnf did **not** pull `akmod-nvidia`, `gcc`, `kernel-devel` or `perl`; `modinfo` the installed modules. (No GPU on runners, so we can't load the module; that is tested on the laptop.) |
| **security** | gitleaks, zizmor, actionlint, shellcheck: copied from the Claude repo. |
| **publish** (main branch only) | `rpmsign` every new RPM → upload RPMs to a GitHub **Release** → regenerate `nvidia-kmod-control` (§3) → `createrepo_c` → sign `repomd.xml` (detached `repomd.xml.asc`) → deploy Pages (repodata + `.repo` file + public key + `index.html` + `BUILDINFO.json`) → `actions/attest-build-provenance`. |
| **prune** | Keep kmods only for the 3 newest kernels per NVIDIA version still in RPM Fusion (matches `installonly_limit=3`); delete older Release assets. |

**Hosting.** Pages limit: 1 GB per site, ~100 GB/month soft bandwidth. Releases: 2 GiB per file,
no total limit. Kmods are ~10 MB (§7), so **v1 keeps everything on Pages** (~60 MB). Every RPM is
also attached to a GitHub Release as a backup. If we outgrow Pages, the RPMs move to Releases and
`createrepo_c --baseurl` (`xml:base`) points dnf at the Release download URLs.

**Which build method.** Plain `rpmbuild --rebuild` of RPM Fusion's `nvidia-kmod` SRPM with
`--define "kernels <kver>"`. That is exactly what `akmodsbuild` runs internally (checked in
`/usr/sbin/akmodsbuild`), minus the akmods daemon. Important: we pass `--with kmod_nvidia_open`,
because otherwise the spec runs `lspci` at build time to pick open vs closed, and a CI runner
has no NVIDIA GPU.

**Signing key (only after you approve).** New key, separate from the Claude repo key.
Secrets: `RPM_GPG_PRIVATE_KEY`, `RPM_GPG_KEY_ID`. Public key published on Pages and in the repo.

---

## 3. Version-mismatch protection (kmod version must equal userspace version)

The danger: RPM Fusion pushes userspace 620 to stable before our CI has built kmod 620 for
your kernel → `dnf upgrade` gives you userspace 620 + kmod 615 → no driver at boot.

| Option | How | Verdict |
|---|---|---|
| **A. Mirror userspace here** + `excludepkgs=*nvidia*` on RPM Fusion | CI copies RPM Fusion's userspace RPMs **byte-for-byte** (their GPG signature stays valid) into our repo only when kmods exist | Works, but: ~1 GB more per NVIDIA version on Releases, CI downloads it each time, and for *all* NVIDIA packages you'd trust our repo's metadata instead of RPM Fusion's. |
| **B. `dnf versionlock`** | Lock `xorg-x11-drv-nvidia*` to one version | Rejected: needs a human to unlock on every NVIDIA update. |
| **C. Gate package (recommended)** | CI publishes `nvidia-kmod-control` with `Conflicts: nvidia-kmod-common > 3:<newest version we have kmods for, for every supported kernel>` | Tiny, userspace still comes straight from RPM Fusion. dnf's default `best=0` (checked on this laptop) makes it simply **hold back** the userspace upgrade until CI publishes a new gate. |

`nvidia-kmod-control` also carries the **auto-install rules**, one per built kernel:
```
Requires: (kmod-nvidia-7.2.11-200.fc44.x86_64 if kernel-core-uname-r = 7.2.11-200.fc44.x86_64)
```
This is an RPM **rich (boolean) dependency**: when dnf installs a new kernel, the same transaction
also installs its kmod. (This replaces what the `akmods` service does after boot.)

**License (honest version, I'm not a lawyer).** NVIDIA's license (`/usr/share/licenses/xorg-x11-drv-nvidia/LICENSE`)
§1.1(d) allows distributing the software for OSI-licensed kernels if the binaries are
**not modified** and the license goes to each recipient; §2.7 forbids other distribution and
"commercial hosting services". RPM Fusion nonfree already relies on this. So option A would be
allowed if we mirror unchanged RPMs (they include the LICENSE). Option C avoids the question
entirely. The **kmods we build** come from the open module, licensed **Dual MIT/GPL** (verified with
`modinfo`), so publishing them is clearly fine.

---

## 4. Kernel-ahead protection on the laptop (`nvidia-kmod-boot-guard`)

Normally the kmod arrives in the same transaction as the kernel (§3). This is the safety net for when
it doesn't (CI broken, repo unreachable, kernel installed from a repo we didn't watch).

- **`/usr/lib/kernel/install.d/99-nvidia-kmod-guard.install`**: a **kernel-install plugin**
  (scripts `kernel-install add` runs for every new kernel; `99-` runs after GRUB's own plugin made the
  new kernel default). If `/usr/lib/modules/<new>/extra/nvidia/nvidia.ko*` is missing, it runs
  `grubby --set-default` back to the newest kernel that *has* the module and writes a marker in
  `/var/lib/nvidia-kmod-guard/`.
- **RPM file trigger** (`%transfiletriggerin -- /usr/lib/modules`): when a kmod lands later, it
  re-checks and moves the default to the newest kernel that now has its module, then clears the marker.
- Ships `/etc/dnf/libdnf5.conf.d/80-nvidia-kmod.conf` with `installonly_limit=3` (Fedora's default is
  2 on this laptop), so a fallback kernel always survives.
- Packaged as a normal RPM in this repo (installed to `/usr/lib/kernel/install.d/` so `/etc` stays yours).

---

## 5. Ideas taken from Universal Blue `ublue-os/akmods` (and what we do differently)

Read: [`build_files/nvidia/build-kmod-nvidia.sh`](https://github.com/ublue-os/akmods/blob/main/build_files/nvidia/build-kmod-nvidia.sh),
[`build_files/prep/build-prep.sh`](https://github.com/ublue-os/akmods/blob/main/build_files/prep/build-prep.sh),
[`build_files/nvidia/download-nvidia-rpms.sh`](https://github.com/ublue-os/akmods/blob/main/build_files/nvidia/download-nvidia-rpms.sh),
[`.github/workflows/reusable-cache-kernel.yml`](https://github.com/ublue-os/akmods/blob/main/.github/workflows/reusable-cache-kernel.yml).

| Used | From ublue |
|---|---|
| Build the akmod SRPM for an explicit kernel in a container, then `modinfo` every `.ko` and fail loudly | `build-kmod-nvidia.sh` |
| Pick the NVIDIA version by what userspace version is actually available, so akmod and userspace match | `build-kmod-nvidia.sh` / `download-nvidia-rpms.sh` |
| Always build **open** for the main driver | `KERNEL_MODULE_TYPE=open` |
| Reproducible paths: `KCFLAGS=-ffile-prefix-map=…` | `build-prep.sh` |
| Cache kernel RPMs per kernel version in `actions/cache` | `reusable-cache-kernel.yml` |
| Pinned action SHAs, OpenSSF-style hygiene | their workflows |

**Different on purpose:** ublue ships kmods inside **OCI images** for image-based systems; we need a
**dnf repo** for a normal Fedora install. ublue now builds NVIDIA from **negativo17**; we stay on
**RPM Fusion** (your trusted source, and what this laptop already runs). ublue signs modules for
Secure Boot; we don't need that yet. No ublue code is copied.

---

## 6. Order of work (each step waits for your OK)

| # | Step | Public effect |
|---|---|---|
| 1 | ✅ Local prototype (this session, §7) | none |
| 2 | Write the build/check scripts, specs for `nvidia-kmod-control` and `-boot-guard`, workflow; run CI steps locally in podman | none |
| 3 | **You approve** → create GPG key, repo `musmandev092/nvidia-kmod-rpm`, add secrets | repo exists |
| 4 | First CI run; test install on the laptop: remove `akmod-nvidia`, install from this repo, reboot, `nvidia-smi` | repo live |
| 5 | Wait for one real kernel update to go through testing → stable, confirm the kmod was ready first | — |

Risk / honest trade-offs:
- **One trust point more:** you trust this repo's CI for kernel code that runs as root. Mitigated by
  build attestation, public logs, and building only from RPM Fusion's SRPM with no source changes.
- If CI is down, kernels still update but you keep booting the old kernel (§4) and NVIDIA userspace is held (§3).
- Rich deps + `Conflicts` gating rely on dnf behavior (`best=0`): the test job checks it every run.

---

## 7. Prototype result (kernel 7.2.11-200.fc44, NVIDIA 615.78.08)

Built in podman `fedora:44` with `scripts/build-kmod.sh` (~95 MiB toolchain download; to save
bandwidth the prototype mounted this laptop's kernel headers and NVIDIA source read-only and used
`--nodeps`. CI installs them properly instead).

| Check | Result |
|---|---|
| Output | `out/kmod-nvidia-7.2.11-200.fc44.x86_64-615.78.08-1.fc44.x86_64.rpm`, **10 MB** (12 MB installed) |
| `rpm -qpR` | only `kernel-uname-r = 7.2.11-200.fc44.x86_64`, `nvidia-kmod-common >= 3:615.78.08`, `/usr/sbin/depmod`, `/bin/sh`: **no gcc, kernel-devel, perl or akmods** |
| Module flavor | all 5 modules open (`Dual MIT/GPL`, peermem `Dual BSD/GPL`), vermagic `7.2.11-200.fc44.x86_64` |
| Same as akmods? | `srcversion` of `nvidia.ko` and `nvidia-drm.ko` **identical** to the akmod-built module running on this laptop |
| Installed on laptop? | **No** |

Size math: 10 MB × 3 kernels × 2 NVIDIA versions ≈ 60 MB → everything fits on **Pages** for v1;
Releases are only needed if we ever add the closed module or more Fedora versions.

Two facts found on the way:
- `akmod-nvidia` and userspace releases differ (`595.58.03-2` vs `-1`), so all matching is on
  **epoch:version**, never release, same as RPM Fusion's `nvidia-kmod-common >= 3:<ver>`.
- The kmod `Provides: kmod-nvidia-newest-<kver>` and `nvidia-kmod`, but nothing installs it
  automatically for a new kernel. That's why `nvidia-kmod-control` (§3) is needed.
