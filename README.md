# What?

- Configs and builds for mainline LTS kernels multiple kernel versions and EL releases.
- Using kernel standard rpm packaging. ElRepo's/RHEL's .specs are not used.
- Minimal patching, just to get different named packages.
- The px-fuse module is included as a separate RPM, to prove the kernel-devel
- Binary x86_64 builds are provided by GitHub.

# Why?

I need kernels for EL8 (RockyLinux) and EL9 that are

- mainline LTS kernels, at least 5.10.y; 6.1.y or 6.6.y would be ideal
- packaged as RPMs, with different names than the distro's
    - RPM name includes LTS branch version (eg 6.1.y is `kernel-lts-generic-61y`)
    - `uname -r` is not insane; keep it simple eg `6.1.71-1000.el8`
- fully eBPF BTF [CO-RE](https://nakryiko.com/posts/bpf-core-reference-guide/) enabled
    - built with a toolchain available in EL8: gcc12 with DWARF5
- include working `-devel` packages that can be used to build out-of-tree modules
- such out-of-tree modules should also be signed and BTF-enabled
- kernel includes BTRFS, XXHASH, ZSTD, etc as modules -- take that, RedHat
- includes px-fuse out-of-tree module, in a separate RPM
- fully signed, and **won't load unsigned modules**
    - _"use a privileged daemonset to drop random kernel modules into host"_ won't work ever again

## Why-not?s

- Why not the RedHat's vendor 4.18 +years-of-half-baked-backports kernel?
    - Trick question. Move along.
- Why not ELRepo's kernels?
    - ELRepo has `kernel-lt` (5.4.y) and `kernel-ml` (6.6.y) for EL8 at the time of writing
    - ELRepo's kernels are not fully BTF-enabled; well some for EL9 are but not all
    - ELRepo's kernels won't reject unsigned modules, and I won't be able to sign my own modules since I don't have their (throaway?) keys

## Ideally

- ~~ideally I don't want to maintain expanded `.config`'s, only defconfigs~~
- ideally px-fuse would not require any fixes to produce a working rpm, see PR
- ideally I would use 6.6.y, but px-fuse won't build with it. A shame, since 6.3+ brings user namespaces.
- ideally I would build a single "generic" kernel, but build time is too long; thus FLAVORs
- ideally I would publish a GPG-signed yum repo with the RPMS/SRPMS

## How?

Using a Dockerfile with multiple stages:

- RockyLinux stages
    - a stage with all the toolchain and tools, plus signing keys
    - a stage with the unpacked kernel source
    - a stage with patched kernel source
    - a stage with .`config`ured, patched, kernel (this is expoted as `-builder` for easy config/patch maintenance)
    - a stage with the built kernel RPMs/SRPM
    - a stage for building out-of-tree modules
- a final, Alpine, stage to carry/publish the RPMs/SRPMs from both the kernel & out-of-tree stages
- this is tagged with the complete version, eg ``
- but also with the latest variant, `` when a new kernel is built

## Using

tl,dr: pull from Docker, export files to host, publish in some repo or install directly from disk

Example:

```bash
# Might need to add --privileged depending on your user / setup / podman / etc
# ATTENTION: the 'kvm' flavor is only for qemu/kvm virtio-based machines and wont' work everywhere, use 'generic' if it ever finishes building
# Adapt `el8-kvm-6.1.y` to your liking; eg `el8-generic-6.1.y` or `el9-kvm-6.1.y`
docker run -it -v "$(pwd)/kernel-lts:/host" ghcr.io/rpardini/el-kernel-lts:el8-kvm-6.1.y-latest
# Installing the module will emit errors for depmod and modprobe on the first install; module will only be loaded after reboot.
yum install kernel-lts/kernel_lts_kvm_61y-6.1.71_1000.el8-1.x86_64.rpm kernel-lts/px-6.1.71-1000.x86_64.rpm
grubby --default-kernel # should output /boot/vmlinuz-6.1.71-1000.el8
reboot
```

## Development

### Change kernel config

```bash
# ... git clone "<this repo>" && cd there ...

# Default config is 6.1 and kvm
./kernel.sh config # configure the default 6.1 kvm flavor

# 2nd param is FLAVOR, or pass FLAVOR=; use env vars for the rest
KERNEL_MINOR=5 KERNEL_MINOR=4 FLAVOR=elrepo ./kernel.sh config  # configure the 5.4.y elrepo flavor
```

### Build

```bash
# ... git clone "<this repo>" && cd there ...

# Default build is 6.1 and kvm
./kernel.sh build # build the default 6.1 kvm flavor

# build for el9, 5.4.y, elrepo
EL_MAJOR_VERSION=9 KERNEL_MINOR=5 KERNEL_MINOR=4 ./kernel.sh build elrepo # build the 5.4.y elrepo flavor for EL9
```

## Issues

### vmlinuz et al disappears from `/boot` if kernel pkg is `yum reinstall`ed

Why? Help.

### Missing `crashkernel=auto` RedHat kernel patches, so EL8's `kdump.service` fails to start

**Update:** scratch all the below, I've rebased and added the patch for 6.1.y kernels. Won't fight EL so I rather lose by default.

Mainline kernel is (obviously) [missing this patch](https://patchwork.kernel.org/project/linux-mm/patch/20210507010432.IN24PudKT%25akpm@linux-foundation.org/), which enables `crashkernel=auto` to work.

Linus [pratically guaranteed this will _never_ get into mainline](https://patchwork.kernel.org/project/linux-mm/patch/20210507010432.IN24PudKT%25akpm@linux-foundation.org/#24161757).

Unfortunately EL8 has `crashkernel=auto` by default (in `/etc/default/grub`'s `GRUB_CMDLINE_LINUX`), which triggers the `ConditionKernelCommandLine=crashkernel` in `/usr/lib/systemd/system/kdump.service`
which tries to setup for kdump, failing with `kdump: No memory reserved for crash kernel`. K has already rejected the option during early boot, check `dmesg`: `crashkernel: memory value expected`.

The original EL8 kernel instead produces

```
[    0.000000] Using crashkernel=auto, the size chosen is a best effort estimation.
[    0.000000] Reserving 256MB of memory at 1712MB for crashkernel (System RAM: 32761MB)
```

To solve for this, either:

- is already solved by adding RH's patch
- ~~just disable kdump: `systemctl disable kdump.service`~~
- ~~remove `crashkernel=auto` from `/etc/default/grub`'s `GRUB_CMDLINE_LINUX` and regen grub config~~
- ~~change `crashkernel=auto` to `crashkernel=256M` (256M being from the example above, in a 16gb machine) in `/etc/default/grub`'s `GRUB_CMDLINE_LINUX` and regen grub~~
