ARG EL_MAJOR_VERSION=8
ARG EL_MINOR_VERSION=9

ARG KERNEL_MAJOR=6
ARG KERNEL_MINOR=1
ARG KERNEL_POINT_RELEASE=70
ARG KERNEL_PKG="kernel-lts"

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

# We need to build pahole from source, as the one in powertools is too old
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
FROM basebuilder as kernelbuilder

# ARGs are lost everytime FROM is used, redeclare to get the global ones at the top of this Dockerfile
ARG EL_MAJOR_VERSION
ARG EL_MINOR_VERSION
ARG EL_VERSION
ARG KERNEL_MAJOR
ARG KERNEL_MINOR
ARG KERNEL_PKG
ARG KERNEL_VERSION
ARG KERNEL_VERSION_FULL
ARG KERNEL_EXTRAVERSION

# Stage specific args
ARG KERNEL_STUFF_DIR="${KERNEL_PKG}-${KERNEL_VERSION}"

WORKDIR /build

# Download, extract, and rename the kernel source, all in one go, for docker layer slimness
RUN wget --progress=dot:giga -O linux-${KERNEL_VERSION_FULL}.tar.xz https://www.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/linux-${KERNEL_VERSION_FULL}.tar.xz && \
      tar -xf linux-${KERNEL_VERSION_FULL}.tar.xz  && \
      ls -la /build/ && \
      mv -v /build/linux-${KERNEL_VERSION_FULL} /build/linux && \
      rm -f linux-${KERNEL_VERSION_FULL}.tar.xz


# Add configs/patches/etc; for now only config
ADD ${KERNEL_STUFF_DIR} /build/stuff


WORKDIR /build/linux

# check again what gcc version is being used
RUN gcc --version

# Copy the config to the kernel tree
RUN cp -v /build/stuff/defconfig-6.1-x86_64 .config

# Expand the config, with defaults for new options
RUN make olddefconfig

# Patch the EXTRAVERSION, this is included in the kernel itself
RUN sed -i 's/^EXTRAVERSION.*/EXTRAVERSION = -${KERNEL_EXTRAVERSION}/' Makefile
RUN cat Makefile | grep EXTRAVERSION

# Patch the rpm base package Name: in mkspec; so instead of "kernel" we get "kernel-lts-61y"
#RUN sed -i 's/Name: kernel/Name: kernel-lts-${KERNEL_MAJOR}${KERNEL_MINOR}y/' scripts/package/mkspec
# Same, for the kernel-devel description
#RUN sed -i 's/%description -n kernel-devel/%description -n kernel-lts-${KERNEL_MAJOR}${KERNEL_MINOR}y-devel/' scripts/package/mkspec

RUN cat scripts/package/mkspec | grep -e "Name:" -e "description"

# Show some options that are critical for this
RUN cat .config | grep -e "EXTRAVERSION" -e "GCC" -e "PAHOLE" -e "DWARF" -e "BTF" -e "BTRFS" -e "XXHASH" -e "ZSTD" -e "DEBUG_INFO" >&2
RUN make kernelrelease
RUN make kernelversion

## Build the kernel (this does NOT give out a -devel package, which is what we want)
#RUN make -j$(nproc) bzImage
#RUN make -j$(nproc) modules
#RUN make -j$(nproc) binrpm-pkg

# rpm-pkg does CLEAN so fucks up everything, either do it once or don't. binrpm-pkg packages a prebuilt thingy
RUN make -j$(($(nproc --all)*2)) rpm-pkg RPMOPTS='-vv' 

RUN du -h -d 1 -x /root/rpmbuild
RUN tree /root/rpmbuild/RPMS
RUN tree /root/rpmbuild/SRPMS

# PX Module kernelbuilder
FROM basebuilder as pxbuilder

# ARGs are lost everytime FROM is used, redeclare to get the global ones at the top of this Dockerfile
ARG KVERSION_PX
ARG PX_FUSE_REPO
ARG PX_FUSE_BRANCH

WORKDIR /temprpm
COPY --from=kernelbuilder /root/rpmbuild/RPMS/x86_64/kernel-devel-*.rpm /temprpm/
RUN yum install -y /temprpm/kernel-*.rpm --allowerasing

WORKDIR /src/
RUN git clone ${PX_FUSE_REPO} px-fuse # https://github.com/portworx/px-fuse.git

# check again what gcc version is being used; show headers installed etc
RUN gcc --version
RUN yum list installed | grep kernel-devel
RUN ls -la /usr/src/kernels

WORKDIR /src/px-fuse
RUN git checkout ${PX_FUSE_BRANCH} # v3.0.4
RUN autoreconf && ./configure # Needed to get a root Makefile

RUN make rpm KVERSION=${KVERSION_PX}
RUN ls -laht rpm/px/RPMS/x86_64/*.rpm
RUN ls -laht rpm/px/SRPMS/*.rpm

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

RUN ls -laR /out

