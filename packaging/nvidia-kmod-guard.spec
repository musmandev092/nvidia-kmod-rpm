Name:           nvidia-kmod-guard
Version:        1.0
Release:        1%{?dist}
Summary:        Keep booting a kernel that has its NVIDIA module
License:        MIT
URL:            https://github.com/musmandev092/nvidia-kmod-rpm
BuildArch:      noarch
Source0:        nvidia-kmod-guard
Source1:        99-nvidia-kmod-guard.install

Requires:       grubby
Requires:       kmod
Requires:       systemd-udev

%description
When a new kernel is installed before its prebuilt NVIDIA kernel module, this
keeps the previous kernel (which has the module) as the GRUB default, and
switches to the new kernel as soon as its module is installed.

%prep

%build

%install
install -Dpm0755 %{SOURCE0} %{buildroot}%{_bindir}/nvidia-kmod-guard
install -Dpm0755 %{SOURCE1} %{buildroot}%{_prefix}/lib/kernel/install.d/99-nvidia-kmod-guard.install
install -dm0755 %{buildroot}%{_sharedstatedir}/nvidia-kmod-guard

# Re-check at the end of every transaction that adds kernel modules or NVIDIA
# firmware (the firmware path is versioned, so it changes with the userspace).
%transfiletriggerin -- /usr/lib/modules /lib/modules /usr/lib/firmware/nvidia
%{_bindir}/nvidia-kmod-guard sync || :

%files
%{_bindir}/nvidia-kmod-guard
%{_prefix}/lib/kernel/install.d/99-nvidia-kmod-guard.install
%dir %{_sharedstatedir}/nvidia-kmod-guard

%changelog
* Wed Oct 21 2026 musmandev092 <mosman092@hotmail.com> - 1.0-1
- First version
