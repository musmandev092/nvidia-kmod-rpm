# nvidia-kmod-rpm

Prebuilt NVIDIA kernel modules for Fedora, as a signed dnf repository.

RPM Fusion's `akmod-nvidia` compiles the NVIDIA module **on your machine** after every kernel
update, which needs gcc, kernel-devel, Perl and ~275 extra packages. This repo compiles it in
GitHub Actions instead, from RPM Fusion's **unmodified** akmod source, and you install the result
with plain `dnf`. The NVIDIA userspace (drivers, CUDA, power management) still comes straight from
RPM Fusion.

Scope: Fedora 44, x86_64, the **open** kernel module (GPUs from Turing / RTX 20 onwards).
Secure Boot must be off (modules are not signed for the kernel; RPMs and repo metadata are).

## Install

Needs RPM Fusion nonfree ([how](https://rpmfusion.org/Configuration)).

```sh
sudo dnf config-manager addrepo --from-repofile=https://musmandev092.github.io/nvidia-kmod-rpm/nvidia-kmod-rpm.repo
sudo dnf install nvidia-kmod-control xorg-x11-drv-nvidia-cuda xorg-x11-drv-nvidia-power
```

Coming from `akmod-nvidia`? The same command replaces it. Afterwards `sudo dnf autoremove`
removes the compiler and kernel headers it pulled in.

Updates: `sudo dnf upgrade`. That's all.

## What happens on updates

| Event | What you get |
|---|---|
| Fedora ships a new kernel | CI built its module from `updates-testing` days earlier, so `dnf upgrade` installs kernel + module together |
| New kernel but no module yet (CI broken, unusual kernel) | The kernel installs; `nvidia-kmod-guard` keeps the previous kernel as the boot default and switches over once the module arrives |
| RPM Fusion ships a new NVIDIA version | `dnf upgrade` holds the NVIDIA packages back until modules for it are published, then upgrades driver and modules together |

Check anytime: `nvidia-kmod-guard status`.

## Packages

| Package | Contents |
|---|---|
| `kmod-nvidia-<kernel>` | The compiled modules, one package per kernel. Requires only `kernel-uname-r = <kernel>` and `nvidia-kmod-common >= <version>` |
| `nvidia-kmod-control` | Rules `(kmod-nvidia-K if kernel-core-uname-r = K)` for every built kernel; replaces `akmod-nvidia`; hides RPM Fusion's akmod via `/usr/share/dnf5/repos.override.d/80-nvidia-kmod-rpm.repo` |
| `nvidia-kmod-guard` | `kernel-install` plugin + RPM file trigger that keep a kernel with a matching module as the GRUB default |

Keep at least 3 kernels so a fallback always exists: Fedora's default `installonly_limit` is 3. If
`/etc/dnf/dnf.conf` sets it lower, raise it.

## How it's built

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs every 3 hours, with no human step:

1. **plan**: newest kernels in Fedora `fedora` / `updates` / `updates-testing`, newest
   `akmod-nvidia` in RPM Fusion stable / testing, minus what is already published.
2. **build** (one job per kernel × NVIDIA version): `rpmbuild --rebuild` of RPM Fusion's
   `nvidia-kmod` SRPM with `--define "kernels <kver>"` (what `akmodsbuild` does) and
   `--with kmod_nvidia_open`. RPM Fusion's release RPMs and akmod are checked against RPM Fusion's
   keys pinned in [`keys/`](keys/).
3. **test**: update scenarios with stub packages ([`tests/test-dnf.sh`](tests/test-dnf.sh)), the
   boot guard ([`tests/test-guard.sh`](tests/test-guard.sh)), and a real install against Fedora +
   RPM Fusion ([`tests/test-real.sh`](tests/test-real.sh)).
4. **security**: gitleaks, zizmor, actionlint, shellcheck.
5. **publish**: sign RPMs and `repomd.xml`, deploy to GitHub Pages, attest build provenance,
   create a release.

Verify a download: `gh attestation verify <file> -R musmandev092/nvidia-kmod-rpm`.
Signing key fingerprint: `975B A05E 7774 D44B DCCB  BB12 E5C0 6F1D 1989 8021`.

If the repo metadata is ever tampered with, dnf ignores this repo entirely (you get no updates from
it rather than bad ones).

## Go back to akmod

```sh
sudo dnf remove nvidia-kmod-control nvidia-kmod-guard
sudo dnf install akmod-nvidia
```

## Credits and license

Build approach informed by Universal Blue's [`ublue-os/akmods`](https://github.com/ublue-os/akmods)
(no code copied). Kernel module source: NVIDIA's open GPU kernel modules (Dual MIT/GPL), packaged by
[RPM Fusion](https://rpmfusion.org). Unofficial; not affiliated with NVIDIA, Fedora or RPM Fusion.
Scripts in this repository: MIT.
