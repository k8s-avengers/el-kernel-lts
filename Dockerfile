ARG EL_MAJOR_VERSION=8
ARG EL_MINOR_VERSION=9

ARG KERNEL_MAJOR=6
ARG KERNEL_MINOR=1
ARG KERNEL_POINT_RELEASE=69
ARG KERNEL_PKG="kernel_lts_kvm_${KERNEL_MAJOR}${KERNEL_MINOR}y"
ARG INPUT_DEFCONFIG="defconfigs/kvm-6.1-x86_64"

ARG PAHOLE_VERSION="v1.25"

ARG PX_FUSE_REPO="https://github.com/rpardini/px-fuse-mainline.git"
ARG PX_FUSE_BRANCH="v3.0.4-rpm-fixes"

# Derived args
ARG EL_VERSION=${EL_MAJOR_VERSION}.${EL_MINOR_VERSION}
ARG KERNEL_VERSION="${KERNEL_MAJOR}.${KERNEL_MINOR}"
ARG KERNEL_VERSION_FULL="${KERNEL_VERSION}.${KERNEL_POINT_RELEASE}"

ARG KERNEL_RPM_VERSION=666
ARG KERNEL_EXTRAVERSION="${KERNEL_RPM_VERSION}.el${EL_MAJOR_VERSION}"

# Used for PX module rpm building; KVERSION_PX is the dir under /usr/src/kernels/
ARG KVERSION_PX="${KERNEL_VERSION_FULL}-${KERNEL_EXTRAVERSION}"

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Common shared basebuilder; definitely build this with --pull so it doesn't bitrot
FROM rockylinux:${EL_VERSION} AS basebuilder

# Common deps across all kernels; try to have as much as possible here so cache is reused
# Developer tools for kernel building, from baseos; "yum-utils" for "yum-builddep"; "pciutils-libs" needed to install headers/devel later; cmake for building pahole
RUN dnf -y groupinstall 'Development Tools'
RUN dnf -y install ncurses-devel openssl-devel elfutils-libelf-devel python3 wget tree git rpmdevtools rpmlint yum-utils pciutils-libs cmake bc rsync
RUN dnf -y install gcc-toolset-12 # 12.2.1-7 at the time of writing

# Use gcc-12 toolchain as default
SHELL ["/usr/bin/scl", "enable", "gcc-toolset-12", "--", "bash", "-xe", "-c"]

RUN gcc --version

# FROM resets ARGs, so we need to redeclare them here
ARG PAHOLE_VERSION

# We need to build pahole from source, as the one in powertools is too old; one day join this together to save layers
WORKDIR /src
RUN git clone https://git.kernel.org/pub/scm/devel/pahole/pahole.git
WORKDIR /src/pahole
RUN git -c advice.detachedHead=false checkout "${PAHOLE_VERSION}"
RUN mkdir -p build
WORKDIR /src/pahole/build
RUN cmake -D__LIB=lib -DCMAKE_INSTALL_PREFIX=/usr ..
RUN make install
RUN ldconfig
RUN pahole --version && which pahole
WORKDIR /src


# For kernel building...
FROM basebuilder as kernelreadytobuild

# ARGs are lost everytime FROM is used, redeclare to get the global ones at the top of this Dockerfile
ARG KERNEL_MAJOR
ARG KERNEL_MINOR
ARG KERNEL_PKG
ARG KERNEL_VERSION
ARG KERNEL_VERSION_FULL
ARG KERNEL_EXTRAVERSION
ARG INPUT_DEFCONFIG

WORKDIR /build

# Download, extract, and rename the kernel source, all in one go, for docker layer slimness
RUN wget --progress=dot:giga -O linux-${KERNEL_VERSION_FULL}.tar.xz https://www.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/linux-${KERNEL_VERSION_FULL}.tar.xz && \
      tar -xf linux-${KERNEL_VERSION_FULL}.tar.xz  && \
      ls -la /build/ && \
      mv -v /build/linux-${KERNEL_VERSION_FULL} /build/linux && \
      rm -f linux-${KERNEL_VERSION_FULL}.tar.xz

WORKDIR /build/linux

# Copy the config to the kernel tree
ADD ${INPUT_DEFCONFIG} .config

# Expand the config, with defaults for new options
RUN make olddefconfig

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
RUN cat .config | grep -e "EXTRAVERSION" -e "GCC" -e "PAHOLE" -e "DWARF" -e "BTF" -e "BTRFS" -e "XXHASH" -e "ZSTD" -e "DEBUG_INFO" >&2
RUN make kernelrelease
RUN make kernelversion

# Separate layer, so the above can be used for interactive building
FROM kernelreadytobuild as kernelbuilder
# check again what gcc version is being used
RUN gcc --version >&2

# rpm-pkg does NOT operate on the tree, instead, in /root/rpmbuild; tree is built in /root/rpmbuild/BUILD very big. exporting this layer will take a while
# Remove it, but keep the keys, for later usage in the PX module build. The bash + \$ escape is needed so it runs _after_ the build happened
RUN make -j$(($(nproc --all)*2)) rpm-pkg KBUILD_BUILD_USER=${KERNEL_PKG} KBUILD_BUILD_HOST=kernel-lts KGZIP=pigz && \
    mkdir -p /root/rpmbuild/KEYS && \
    bash -c "cp -v \$(find /root/rpmbuild/ -type f -name signing_key.pem) /root/rpmbuild/KEYS/" && \
    rm -rf /root/rpmbuild/BUILD

RUN du -h -d 1 -x /root/rpmbuild >&2
RUN tree /root/rpmbuild/RPMS >&2
RUN tree /root/rpmbuild/SRPMS >&2
RUN tree /root/rpmbuild/KEYS >&2

# PX Module kernelbuilder
FROM basebuilder as pxbuilder

# ARGs are lost everytime FROM is used, redeclare to get the global ones at the top of this Dockerfile
ARG KVERSION_PX
ARG PX_FUSE_REPO
ARG PX_FUSE_BRANCH

WORKDIR /temprpm
COPY --from=kernelbuilder /root/rpmbuild/RPMS/x86_64/kernel*-devel-*.rpm /temprpm/
RUN yum install -y /temprpm/kernel-*.rpm --allowerasing

WORKDIR /src/
RUN git clone ${PX_FUSE_REPO} px-fuse # https://github.com/portworx/px-fuse.git

# check again what gcc version is being used; show headers installed etc
RUN gcc --version >&2
RUN yum list installed | grep kernel-devel >&2
RUN ls -la /usr/src/kernels >&2

WORKDIR /src/px-fuse
RUN git checkout ${PX_FUSE_BRANCH} # v3.0.4
RUN autoreconf && ./configure # Needed to get a root Makefile

RUN make rpm KVERSION=${KVERSION_PX}
RUN ls -laht rpm/px/RPMS/x86_64/*.rpm >&2
RUN ls -laht rpm/px/SRPMS/*.rpm >&2

RUN mkdir /out-px
RUN cp -rvp rpm/px/RPMS /out-px/
RUN cp -rvp rpm/px/SRPMS /out-px/

# Copy the RPMs to a new Alpine image for easy droppage of the .rpm's to host/etc
FROM alpine:latest

WORKDIR /out

COPY --from=kernelbuilder /root/rpmbuild/RPMS /out/RPMS/
COPY --from=kernelbuilder /root/rpmbuild/SRPMS /out/SRPMS/

COPY --from=pxbuilder /out-px/RPMS /out/RPMS/
COPY --from=pxbuilder /out-px/SRPMS /out/SRPMS/

RUN ls -lahR /out

