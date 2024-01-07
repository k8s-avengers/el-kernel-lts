# kernel-lts-px

- Configs and builds for mainline LTS kernels multiple kernel versions and EL releases.
- Using kernel standard rpm packaging. ElRepo's/RHEL's .specs are not used.
- Minimal patching, just to get different named packages.
- The px-fuse module is included as a separate RPM, to prove the kernel-devel
- Binary x86_64 builds are provided by GitHub.


## Missing `crashkernel=auto` RedHat kernel patches, so EL8's `kdump.service` fails to start

Mainline kernel is (obviously) [missing this atrocity](https://patchwork.kernel.org/project/linux-mm/patch/20210507010432.IN24PudKT%25akpm@linux-foundation.org/), which enables `crashkernel=auto` to work.

Linus [pratically guaranteed this will _never_ get into mainline](https://patchwork.kernel.org/project/linux-mm/patch/20210507010432.IN24PudKT%25akpm@linux-foundation.org/#24161757).

Unfortunately EL8 has `crashkernel=auto` by default (in `/etc/default/grub`'s `GRUB_CMDLINE_LINUX`), which triggers the `ConditionKernelCommandLine=crashkernel` in `/usr/lib/systemd/system/kdump.service`
which tries to setup for kdump, failing with `kdump: No memory reserved for crash kernel`. K has already rejected the option during early boot, check `dmesg`: `crashkernel: memory value expected`.

The original EL8 kernel instead produces
```
[    0.000000] Using crashkernel=auto, the size chosen is a best effort estimation.
[    0.000000] Reserving 256MB of memory at 1712MB for crashkernel (System RAM: 32761MB)
```

To solve for this, either:
- just disable kdump: `systemctl disable kdump.service`
- remove `crashkernel=auto` from `/etc/default/grub`'s `GRUB_CMDLINE_LINUX` and regen grub config 
- change `crashkernel=auto` to `crashkernel=256M` (256M being from the example above, in a 16gb machine) in `/etc/default/grub`'s `GRUB_CMDLINE_LINUX` and regen grub

### Regen grub

```
grub2-mkconfig -o /etc/grub2.cfg && grub2-mkconfig -o /etc/grub2-efi.cfg
```