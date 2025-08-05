# Base image ARGs, default to Rocky (thanks Rocky!) but you can override if you've RHEL subscription etc
ARG EL_MAJOR_VERSION=8
ARG EL_IMAGE="docker.io/rockylinux/rockylinux"
ARG EL_VERSION=${EL_MAJOR_VERSION}

ARG OS_ARCH="arm64"
ARG TOOLCHAIN_ARCH="aarch64"

# Toolchain ARGs - compiler to use
ARG GCC_TOOLSET_NAME="gcc-toolset-12"

# Kernel target; "primary keys" together with EL_MAJOR_VERSION above.
ARG KERNEL_MAJOR=6
ARG KERNEL_MINOR=1
ARG FLAVOR="kvm"
ARG KERNEL_RPM_VERSION=666
ARG KERNEL_POINT_RELEASE=71
ARG MAKE_COMMAND_RPM="rpm-pkg"

# Derived args, still overridable, but override at your own risk ;-)
ARG INPUT_DEFCONFIG="defconfigs/${FLAVOR}-${KERNEL_MAJOR}.${KERNEL_MINOR}-${TOOLCHAIN_ARCH}"
ARG KERNEL_PKG="kernel_lts_${FLAVOR}_${KERNEL_MAJOR}${KERNEL_MINOR}y"

ARG KERNEL_VERSION="${KERNEL_MAJOR}.${KERNEL_MINOR}"
ARG KERNEL_VERSION_FULL="${KERNEL_VERSION}.${KERNEL_POINT_RELEASE}"
ARG KERNEL_EXTRAVERSION="${KERNEL_RPM_VERSION}-${FLAVOR}"
# KVERSION is the dir under /usr/src/kernels/ when -devel package is installed
ARG KVERSION="${KERNEL_VERSION_FULL}-${KERNEL_EXTRAVERSION}"

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Common shared basebuilder; definitely build this with --pull on CI, so it doesn't bitrot
FROM ${EL_IMAGE}:${EL_VERSION} AS basebuilder

# Common deps across all kernels; try to have as much as possible here so cache is reused
# Developer tools for kernel building, from baseos; "yum-utils" for "yum-builddep"; "pciutils-libs" needed to install headers/devel later; cmake for building pahole
RUN dnf -y groupinstall 'Development Tools'
RUN dnf -y install ncurses-devel openssl-devel python3 wget tree git rpmdevtools yum-utils pciutils-libs cmake bc rsync kmod
RUN dnf -y install rpmlint || true # might fail on EL10? not sure if strictly required
RUN dnf -y install elfutils-libelf-devel || true # might fail on non-x86
RUN dnf -y install dwarves perl || true # for 6.12 rpms... don't fail as they dont exist on EL8

ARG GCC_TOOLSET_NAME
RUN dnf -y install ${GCC_TOOLSET_NAME}


# Dockerfiles won't allow using ARGS in SHELL, so we need to use a trick here; create a script that will be used as the shell.
RUN echo -e '#!/bin/bash\n/usr/bin/scl enable '"${GCC_TOOLSET_NAME}"' -- bash -xe -c "$@"' > /usr/bin/shell_with_toolset.sh && \
    chmod +x /usr/bin/shell_with_toolset.sh

# Use gcc-12 toolchain as default. Every RUN statement after this is affected, inclusive after FROMs, as long as this is the base layer.
# It makes escaping funny.
SHELL ["/usr/bin/shell_with_toolset.sh"]

RUN gcc --version

# pahole ("dwarves") version to use; some combos of gcc/kernel/pahole (and DEBUG_INFO .config's) are painful to get working
ARG PAHOLE_VERSION="v1.25"

# We need to build pahole from source, as the one in powertools is too old. Do it in one go to save layers.
WORKDIR /src
RUN git clone https://git.kernel.org/pub/scm/devel/pahole/pahole.git && \
      cd /src/pahole && \
      git -c advice.detachedHead=false checkout "${PAHOLE_VERSION}" && \
      mkdir -p build && \
      cd /src/pahole/build && \
      cmake -D__LIB=lib -DCMAKE_INSTALL_PREFIX=/usr .. && \
      make install && \
      ldconfig && \
      pahole --version && command -v pahole && \
      rm -rf /src/pahole

# Prepare signing keys in this common layer; both kernel and px module will use it.
WORKDIR /keys
ADD assets/x509.genkey .
ARG KVERSION
RUN sed -i \"s|KVERSION|${KVERSION}|g\" x509.genkey
RUN echo Contents of x509.genkey; cat x509.genkey
RUN openssl req -new -nodes -utf8 -sha256 -days 36500 -batch -x509 -config x509.genkey -outform PEM -out kernel_key.pem -keyout kernel_key.pem
RUN echo Sign with: $(realpath /keys/kernel_key.pem) >&2


# Layer with the unpacked kernel source
FROM basebuilder AS kernelsourceunpacked

# ARGs used from global scope in this stage
ARG KERNEL_MAJOR
ARG KERNEL_VERSION_FULL

WORKDIR /build

RUN echo 'KERNEL_MAJOR=${KERNEL_MAJOR}' >&2
RUN echo 'KERNEL_VERSION_FULL=${KERNEL_VERSION_FULL}' >&2

# Download, extract, and rename the kernel source, all in one go, for docker layer slimness
RUN wget --progress=dot:giga -O linux-${KERNEL_VERSION_FULL}.tar.xz https://www.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/linux-${KERNEL_VERSION_FULL}.tar.xz && \
      tar -xf linux-${KERNEL_VERSION_FULL}.tar.xz  && \
      ls -la /build/ && \
      mv -v /build/linux-${KERNEL_VERSION_FULL} /build/linux && \
      rm -f linux-${KERNEL_VERSION_FULL}.tar.xz

WORKDIR /build/linux

# Separate layer for patching
FROM kernelsourceunpacked AS kernelpatched

ARG KERNEL_MAJOR
ARG KERNEL_MINOR

### Patch the kernel source itself, from patch files in assets/patches/
WORKDIR /build/patches
# ADD/COPY, but don't fail if source does not exist? @TODO this whole layer will be skipped
ADD assets/patches/${KERNEL_MAJOR}.${KERNEL_MINOR}/*.patch .
ADD assets/apply_patches.sh /build/patches/apply_patches.sh
RUN chmod +x /build/patches/apply_patches.sh # @TODO maybe not needed if we mark the source +x

WORKDIR /build/linux
RUN bash /build/patches/apply_patches.sh


# Layer with the config prepared, on top of patches
FROM kernelpatched AS kernelconfigured

# ARGs used from global scope in this stage
ARG INPUT_DEFCONFIG
ARG KERNEL_PKG
ARG KERNEL_EXTRAVERSION

RUN echo "KERNEL_PKG=${KERNEL_PKG}" >&2
RUN echo 'INPUT_DEFCONFIG=${INPUT_DEFCONFIG}' >&2
RUN echo 'KERNEL_EXTRAVERSION=${KERNEL_EXTRAVERSION}' >&2

# Copy the config to the kernel tree
ADD ${INPUT_DEFCONFIG} .config

### Patch the config; use our signing key and enforce signing. See https://www.kernel.org/doc/html/v4.15/admin-guide/module-signing.html

# Add the signing key configs. (The escape is weird due to the SHELL def in base layer containing bash -c)
RUN ( echo 'CONFIG_MODULE_SIG_KEY=\"/keys/kernel_key.pem\"' ) >> .config
RUN ( echo 'CONFIG_MODULE_SIG_FORCE=y' ) >> .config
RUN ( echo 'CONFIG_MODULE_SIG=y' ) >> .config
RUN ( echo 'CONFIG_MODULE_SIG_SHA512=y' ) >> .config

# Expand the config, with defaults for new options
RUN make olddefconfig

### Patch the Makefile, to change the EXTRAVERSION.

# (root) Makefile: Patch the EXTRAVERSION, this is included in the kernel itself. (rpardini: not great, there's a config for that, but that's how elrepo did it)
RUN sed -i 's/^EXTRAVERSION.*/EXTRAVERSION = -${KERNEL_EXTRAVERSION}/' Makefile
RUN cat Makefile | grep EXTRAVERSION >&2

### Patch minimally to have different kernel package hierarchy RPMs

# scripts/package/mkspec: Patch the RPM name, description for the -devel pkg, and source
RUN sed -i 's/Name: kernel/Name: ${KERNEL_PKG}/' scripts/package/mkspec
RUN sed -i 's/%description -n kernel-devel/%description -n ${KERNEL_PKG}-devel/' scripts/package/mkspec
RUN sed -i 's/Source: kernel-/Source: ${KERNEL_PKG}-/' scripts/package/mkspec

# scripts/package/kernel.spec (6.12+): Patch the RPM name, description for the -devel pkg, and source
RUN sed -i 's/Name: kernel/Name: ${KERNEL_PKG}/' scripts/package/kernel.spec || true
RUN sed -i 's/%description -n kernel-devel/%description -n ${KERNEL_PKG}-devel/' scripts/package/kernel.spec || true
RUN sed -i 's/Source: kernel-/Source: ${KERNEL_PKG}-/' scripts/package/kernel.spec || true

# scripts/Makefile.package: the tarball must match the RPM package name
RUN sed -i 's/KERNELPATH := kernel-/KERNELPATH := ${KERNEL_PKG}-/' scripts/Makefile.package

# Debugs
RUN cat scripts/package/mkspec | grep -e "Name:" -e "description" -e "Source:" || true >&2
RUN cat scripts/package/kernel.spec | grep -e "Name:" -e "description" -e "Source:" || true >&2
RUN cat scripts/Makefile.package | grep "^KERNELPATH"|| true  >&2

# Show some options that are critical for this
RUN cat .config | grep -e "EXTRAVERSION" -e "GCC" -e "PAHOLE" -e "DWARF" -e "BTF" -e "BTRFS" -e "XXHASH" -e "DEBUG_INFO" -e "MODULE_SIG" -e "CRASH_CORE" | grep -v "\ is not set" | sort >&2
RUN ( echo "KERNELRELEASE"; make kernelrelease; ) >&2

# Set some envs for the kernel build
ENV KBUILD_BUILD_USER=${KERNEL_PKG} KBUILD_BUILD_HOST=kernel-lts KGZIP=pigz 


# Separate layer, so the above can be used for interactive building
FROM kernelconfigured AS kernelbuilder
# check again what gcc version is being used
RUN gcc --version >&2

# Different make invocations
ARG MAKE_COMMAND_RPM

RUN make -j$(nproc --all) ${MAKE_COMMAND_RPM} INSTALL_MOD_STRIP=1
RUN if [[ -d /build/linux/rpmbuild ]]; then mv /build/linux/rpmbuild /root/rpmbuild; fi

# Store a copy of the bare ELF/debug_info/btf vmlinux in a separate directory, so it can be used by the module builder later.
RUN mkdir -pv /root/rpmbuild/vmlinux_bare
RUN cp -v  $(find / -type f -name vmlinux | grep -v "^/sys" | xargs file | grep "ELF" | grep "debug_info" | cut -d ":" -f 1) /root/rpmbuild/vmlinux_bare/

# Hack; create /root/rpmbuild/tools with some file inside; include resolve_btfids if it exists.
RUN mkdir -pv /root/rpmbuild/tools/bpf/resolve_btfids; touch /root/rpmbuild/tools/non-empty-marker
RUN bash -c 'if [[ -f /build/linux/tools/bpf/resolve_btfids/resolve_btfids ]]; then cp -v /build/linux/tools/bpf/resolve_btfids/resolve_btfids /root/rpmbuild/tools/bpf/resolve_btfids/resolve_btfids; fi'
RUN tree /root/rpmbuild/tools >&2

RUN du -h -d 1 -x /root/rpmbuild >&2
RUN ls -lahR /root/rpmbuild/RPMS >&2
RUN tree /root/rpmbuild/RPMS >&2
RUN tree /root/rpmbuild/SRPMS >&2

# Hack: copy signing_key.x509 in build dir somewhere we can get at them later
RUN mkdir -pv /root/rpmbuild/certs; touch /root/rpmbuild/certs/non-empty-marker
RUN cp -pv certs/signing_key.x509 /root/rpmbuild/certs/ || echo 'Failed copying file signing_key.x509'
RUN ls -la /root/rpmbuild/certs

# Generic Out-of-Tree Module kernelbuilder
FROM basebuilder AS modulebuilder

# Used for module building; KVERSION is the dir under /usr/src/kernels/
ARG KVERSION
ARG OS_ARCH
ARG TOOLCHAIN_ARCH

RUN echo "KVERSION=${KVERSION}" >&2

WORKDIR /buildtools/tools
COPY --from=kernelbuilder /root/rpmbuild/tools /buildtools/tools
RUN tree /buildtools >&2

WORKDIR /buildtools/certs
COPY --from=kernelbuilder /root/rpmbuild/certs /buildtools/certs
RUN tree /buildtools/certs >&2

# Install both the devel (for headers/tools) and the kernel image proper (for vmlinuz BTF, needed to built this module with BTF info)
WORKDIR /temprpm
COPY --from=kernelbuilder /root/rpmbuild/RPMS/${TOOLCHAIN_ARCH}/kernel*.rpm /temprpm/
RUN yum install -y /temprpm/kernel*.rpm --allowerasing

# check again what gcc version is being used; show headers installed etc
RUN gcc --version >&2
RUN ls -la /usr/src/kernels >&2
RUN ls -la /usr/src/kernels/${KVERSION} >&2

# Grab the bare vmlinux from the build tree, as that is uncompressed and has the BTF info needed.
COPY --from=kernelbuilder /root/rpmbuild/vmlinux_bare/vmlinux /usr/src/kernels/${KVERSION}/vmlinux

# HACK - somehow the kernel 6.12+ rpm build does not install resolve_btfids, so we copy it from the kernelbuilder layer.
RUN cp -vr /buildtools/* /usr/src/kernels/${KVERSION}/

RUN find /usr/src/kernels/${KVERSION}/ -name signing_key.x509

RUN echo 'Module builder is ready' >&2

# Layer using the modulebuilder to build px-fuse out-of-tree module
FROM modulebuilder AS pxbuilder

# Used for module building; KVERSION is the dir under /usr/src/kernels/
ARG KVERSION
ARG OS_ARCH
ARG TOOLCHAIN_ARCH

WORKDIR /src/
# with fixes on top of https://github.com/portworx/px-fuse.git # v3.1.0
ARG PX_FUSE_REPO="https://github.com/k8s-avengers/px-fuse-mainline.git"
ARG PX_FUSE_BRANCH="v-aaaae3e-6.12-rpm-btf-fixes-2"

RUN echo Cloning the ${PX_FUSE_REPO} repo with branch ${PX_FUSE_BRANCH} 
RUN git clone --branch=${PX_FUSE_BRANCH} ${PX_FUSE_REPO} px-fuse

WORKDIR /src/px-fuse
RUN git checkout ${PX_FUSE_BRANCH}
RUN autoreconf && ./configure # Needed to get a root Makefile

RUN make rpm KVERSION=${KVERSION}

# After the build, check the .ko built
RUN file ./rpm/px/BUILD/px-src/px.ko >&2
RUN modinfo ./rpm/px/BUILD/px-src/px.ko >&2


RUN ls -laht rpm/px/RPMS/${TOOLCHAIN_ARCH}/*.rpm >&2
RUN ls -laht rpm/px/SRPMS/*.rpm >&2
RUN echo 'rpm  info'; rpm -qRp rpm/px/RPMS/${TOOLCHAIN_ARCH}/*.rpm

# Install the RPM to make sure of sanity
RUN dnf install -y rpm/px/RPMS/${TOOLCHAIN_ARCH}/*.rpm
# Modinfo the installed module to make sure it is sane
RUN find /lib/modules/${KVERSION} -type f -name px.ko
RUN modinfo $(find /lib/modules/${KVERSION} -type f -name px.ko)

RUN mkdir /out-px
RUN cp -rvp rpm/px/RPMS /out-px/
RUN cp -rvp rpm/px/SRPMS /out-px/

# Layer using the modulebuilder to build NVIDIA GPU drivers
FROM modulebuilder AS nvidiabuilder

# Used for module building; KVERSION is the dir under /usr/src/kernels/
ARG KVERSION
ARG OS_ARCH
ARG TOOLCHAIN_ARCH
ARG KERNEL_VERSION_FULL
ARG NVIDIA_OPEN_BRANCH
ARG KERNEL_RPM_VERSION

WORKDIR /src/nvidia-open
RUN git clone --branch=${NVIDIA_OPEN_BRANCH} --single-branch https://github.com/NVIDIA/open-gpu-kernel-modules.git
WORKDIR /src/nvidia-open/open-gpu-kernel-modules
RUN make KERNEL_UNAME=${KVERSION} modules -j$(nproc)
RUN make KERNEL_UNAME=${KVERSION}  modules_install
RUN modinfo  /lib/modules/${KVERSION}/kernel/drivers/video/nvidia.ko

RUN mkdir /out-nvidia
COPY --chmod=0777 assets/nvidia/package_rpm_nvidia.sh .
RUN KERNEL_RPM_VERSION="${KERNEL_RPM_VERSION}" ./package_rpm_nvidia.sh "$(pwd)" "${KVERSION}" "${OS_ARCH}" "${TOOLCHAIN_ARCH}" "${KERNEL_VERSION_FULL}" "/out-nvidia"

# Layer using the modulebuilder to build non-free NVIDIA GPU drivers
FROM modulebuilder AS nvidianonfreebuilder

# Used for module building; KVERSION is the dir under /usr/src/kernels/
ARG KVERSION
ARG OS_ARCH
ARG TOOLCHAIN_ARCH
ARG KERNEL_VERSION_FULL
ARG NVIDIA_NONFREE_RUN_URL
ARG NVIDIA_NONFREE_VERSION
ARG KERNEL_RPM_VERSION

WORKDIR /src/nvidia-nonfree
RUN <<DOWNLOAD_EXTRACT
wget -O nvidia-nonfree.run ${NVIDIA_NONFREE_RUN_URL}
chmod -v +x nvidia-nonfree.run
./nvidia-nonfree.run --extract-only
rm -fv nvidia-nonfree.run
mv -v NVIDIA-Linux-* nvidia-nonfree
DOWNLOAD_EXTRACT

WORKDIR /src/nvidia-nonfree/nvidia-nonfree/kernel
RUN make KERNEL_UNAME=${KVERSION} modules -j$(nproc)
RUN make KERNEL_UNAME=${KVERSION}  modules_install
RUN modinfo  /lib/modules/${KVERSION}/kernel/drivers/video/nvidia.ko
RUN mkdir /out-nvidia
COPY --chmod=0777 assets/nvidia/package_rpm_nvidia.sh .
RUN KERNEL_RPM_VERSION="${KERNEL_RPM_VERSION}" NVIDIA_VERSION="${NVIDIA_NONFREE_VERSION}" NVIDIA_TYPE_DRIVER="nonfree" ./package_rpm_nvidia.sh "$(pwd)" "${KVERSION}" "${OS_ARCH}" "${TOOLCHAIN_ARCH}" "${KERNEL_VERSION_FULL}" "/out-nvidia"

# Copy the RPMs to a new Alpine image for easy droppage of the .rpm's to host/etc; otherwise could be from SCRATCH
FROM alpine:latest

WORKDIR /out

COPY --from=kernelbuilder /root/rpmbuild/RPMS /out/RPMS/
COPY --from=kernelbuilder /root/rpmbuild/SRPMS /out/SRPMS/

COPY --from=pxbuilder /out-px/RPMS /out/RPMS/
COPY --from=pxbuilder /out-px/SRPMS /out/SRPMS/

COPY --from=nvidiabuilder /out-nvidia/ /out/RPMS/
COPY --from=nvidianonfreebuilder /out-nvidia/ /out/RPMS/

RUN ls -lahR /out

