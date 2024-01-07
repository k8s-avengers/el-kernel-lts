# Base image ARGs, default to Rocky (thanks Rocky!) but you can override if you've RHEL subscription etc
ARG EL_MAJOR_VERSION=8
ARG EL_IMAGE="rockylinux"
ARG EL_VERSION=${EL_MAJOR_VERSION}

# Kernel target; "primary keys" together with EL_MAJOR_VERSION above.
ARG KERNEL_MAJOR=6
ARG KERNEL_MINOR=1
ARG FLAVOR="kvm"
ARG KERNEL_RPM_VERSION=666
ARG KERNEL_POINT_RELEASE=69

# Derived args, still overridable, but override at your own risk ;-)
ARG INPUT_DEFCONFIG="defconfigs/${FLAVOR}-${KERNEL_MAJOR}.${KERNEL_MINOR}-x86_64"
ARG KERNEL_PKG="kernel_lts_${FLAVOR}_${KERNEL_MAJOR}${KERNEL_MINOR}y"

ARG KERNEL_VERSION="${KERNEL_MAJOR}.${KERNEL_MINOR}"
ARG KERNEL_VERSION_FULL="${KERNEL_VERSION}.${KERNEL_POINT_RELEASE}"
ARG KERNEL_EXTRAVERSION="${KERNEL_RPM_VERSION}.el${EL_MAJOR_VERSION}"

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Common shared basebuilder; definitely build this with --pull on CI, so it doesn't bitrot
FROM ${EL_IMAGE}:${EL_VERSION} AS basebuilder

# Common deps across all kernels; try to have as much as possible here so cache is reused
# Developer tools for kernel building, from baseos; "yum-utils" for "yum-builddep"; "pciutils-libs" needed to install headers/devel later; cmake for building pahole
RUN dnf -y groupinstall 'Development Tools'
RUN dnf -y install ncurses-devel openssl-devel elfutils-libelf-devel python3 wget tree git rpmdevtools rpmlint yum-utils pciutils-libs cmake bc rsync
RUN dnf -y install gcc-toolset-12 # 12.2.1-7 at the time of writing

# Use gcc-12 toolchain as default. Every RUN statement after this is affected, inclusive after FROMs, as long as this is the base layer.
# It makes escaping funny.
SHELL ["/usr/bin/scl", "enable", "gcc-toolset-12", "--", "bash", "-xe", "-c"]

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
      pahole --version && which pahole && \
      rm -rf /src/pahole

# Prepare signing keys in this common layer; both kernel and px module will use it.
WORKDIR /keys
ADD keys/x509.genkey .
RUN openssl req -new -nodes -utf8 -sha256 -days 36500 -batch -x509 -config x509.genkey -outform PEM -out kernel_key.pem -keyout kernel_key.pem
RUN echo Sign with: $(realpath /keys/kernel_key.pem) >&2


# For kernel building...
FROM basebuilder as kernelreadytobuild

# ARGs used from global scope in this stage
ARG KERNEL_MAJOR
ARG INPUT_DEFCONFIG
ARG KERNEL_PKG
ARG KERNEL_VERSION_FULL
ARG KERNEL_EXTRAVERSION

WORKDIR /build

RUN echo "KERNEL_PKG=${KERNEL_PKG}" >&2
RUN echo "KERNEL_VERSION_FULL=${KERNEL_VERSION_FULL}" >&2
RUN echo 'KERNEL_PKG=${KERNEL_PKG}' >&2
RUN echo 'KERNEL_VERSION_FULL=${KERNEL_VERSION_FULL}' >&2

# Download, extract, and rename the kernel source, all in one go, for docker layer slimness
RUN wget --progress=dot:giga -O linux-${KERNEL_VERSION_FULL}.tar.xz https://www.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/linux-${KERNEL_VERSION_FULL}.tar.xz && \
      tar -xf linux-${KERNEL_VERSION_FULL}.tar.xz  && \
      ls -la /build/ && \
      mv -v /build/linux-${KERNEL_VERSION_FULL} /build/linux && \
      rm -f linux-${KERNEL_VERSION_FULL}.tar.xz

WORKDIR /build/linux

# Copy the config to the kernel tree
ADD ${INPUT_DEFCONFIG} .config

### Patch the config; use our signing key and enforce signing. See https://www.kernel.org/doc/html/v4.15/admin-guide/module-signing.html

# Add the signing key configs. (The escape is weird due to the SHELL def in base layer containing bash -c)
RUN ( echo 'CONFIG_MODULE_SIG_KEY=\"/keys/kernel_key.pem\"' ) >> .config
RUN ( echo 'CONFIG_MODULE_SIG_FORCE=y' ) >> .config

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

# scripts/Makefile.package: the tarball must match the RPM package name
RUN sed -i 's/KERNELPATH := kernel-/KERNELPATH := ${KERNEL_PKG}-/' scripts/Makefile.package

# Debugs
RUN cat scripts/package/mkspec | grep -e "Name:" -e "description" -e "Source:" >&2
RUN cat scripts/Makefile.package | grep "^KERNELPATH" >&2

# Show some options that are critical for this
RUN cat .config | grep -e "EXTRAVERSION" -e "GCC" -e "PAHOLE" -e "DWARF" -e "BTF" -e "BTRFS" -e "XXHASH" -e "DEBUG_INFO" -e "MODULE_SIG" | grep -v "\ is not set" | sort >&2
RUN ( echo "KERNELRELEASE"; make kernelrelease; ) >&2

# Set some envs for the kernel build
ENV KBUILD_BUILD_USER=${KERNEL_PKG} KBUILD_BUILD_HOST=kernel-lts KGZIP=pigz 

# Separate layer, so the above can be used for interactive building
FROM kernelreadytobuild as kernelbuilder
# check again what gcc version is being used
RUN gcc --version >&2

# rpm-pkg does NOT operate on the tree, instead, in /root/rpmbuild; tree is built in /root/rpmbuild/BUILD and is huge. build & remove it immediately to save a huge layer export.
RUN make -j$(nproc --all) rpm-pkg  && \
    rm -rf /root/rpmbuild/BUILD

RUN du -h -d 1 -x /root/rpmbuild >&2
RUN tree /root/rpmbuild/RPMS >&2
RUN tree /root/rpmbuild/SRPMS >&2

# PX Module kernelbuilder
FROM basebuilder as pxbuilder

# Used for PX module rpm building; KVERSION_PX is the dir under /usr/src/kernels/
ARG KERNEL_VERSION_FULL
ARG KERNEL_EXTRAVERSION
ARG KVERSION_PX="${KERNEL_VERSION_FULL}-${KERNEL_EXTRAVERSION}"

RUN echo "KVERSION_PX=${KVERSION_PX}" >&2

# Install both the devel (for headers/tools) and the kernel image proper (for vmlinuz BTF, needed to built this module with BTF info)
WORKDIR /temprpm
COPY --from=kernelbuilder /root/rpmbuild/RPMS/x86_64/kernel*.rpm /temprpm/
RUN yum install -y /temprpm/kernel*.rpm --allowerasing

# check again what gcc version is being used; show headers installed etc
RUN gcc --version >&2
RUN ls -la /usr/src/kernels >&2
RUN ls -la /usr/src/kernels/${KVERSION_PX} >&2

# Copy 'vmlinuz' (from the kernel pkg, in /boot) in a place the build will find it. Decompress it using extract-vmlinuz (which somehow is not included in the devel package, so we've a copy in "assets").
# This is needed to the px module gets correct BTF typeinfo.
ADD assets/extract-vmlinux /usr/bin/extract-vmlinux
RUN chmod +x /usr/bin/extract-vmlinux
RUN cp -v /boot/vmlinuz-* /usr/src/kernels/${KVERSION_PX}/vmlinuz
RUN file  /usr/src/kernels/${KVERSION_PX}/vmlinuz
RUN /usr/bin/extract-vmlinux /usr/src/kernels/${KVERSION_PX}/vmlinuz > /usr/src/kernels/${KVERSION_PX}/vmlinux

WORKDIR /src/
# with fixes on top of https://github.com/portworx/px-fuse.git # v3.0.4
ARG PX_FUSE_REPO="https://github.com/rpardini/px-fuse-mainline.git"
ARG PX_FUSE_BRANCH="v3.0.4-rpm-fixes-btf"

RUN git clone ${PX_FUSE_REPO} px-fuse

WORKDIR /src/px-fuse
RUN git checkout ${PX_FUSE_BRANCH}
RUN autoreconf && ./configure # Needed to get a root Makefile

RUN make rpm KVERSION=${KVERSION_PX}

# After the build, check the .ko built
RUN file ./rpm/px/BUILD/px-src/px.ko >&2
RUN modinfo ./rpm/px/BUILD/px-src/px.ko >&2


RUN ls -laht rpm/px/RPMS/x86_64/*.rpm >&2
RUN ls -laht rpm/px/SRPMS/*.rpm >&2

RUN mkdir /out-px
RUN cp -rvp rpm/px/RPMS /out-px/
RUN cp -rvp rpm/px/SRPMS /out-px/

# Copy the RPMs to a new Alpine image for easy droppage of the .rpm's to host/etc; otherwise could be from SCRATCH
FROM alpine:latest

WORKDIR /out

COPY --from=kernelbuilder /root/rpmbuild/RPMS /out/RPMS/
COPY --from=kernelbuilder /root/rpmbuild/SRPMS /out/SRPMS/

COPY --from=pxbuilder /out-px/RPMS /out/RPMS/
COPY --from=pxbuilder /out-px/SRPMS /out/SRPMS/

RUN ls -lahR /out

