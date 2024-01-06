ARG EL_MAJOR_VERSION=8
ARG EL_MINOR_VERSION=9
ARG EL_VERSION=${EL_MAJOR_VERSION}.${EL_MINOR_VERSION}

ARG KERNEL_MAJOR=6
ARG KERNEL_MINOR=1
ARG KERNEL_POINT_RELEASE=70
ARG KERNEL_PKG="kernel-lts"

ARG KERNEL_RPM_VERSION=1
ARG PAHOLE_VERSION="v1.25"

ARG KERNEL_VERSION="${KERNEL_MAJOR}.${KERNEL_MINOR}"
ARG KERNEL_VERSION_FULL="${KERNEL_VERSION}.${KERNEL_POINT_RELEASE}"
ARG KERNEL_VERSION_FULL_RPM="${KERNEL_VERSION_FULL}-${KERNEL_RPM_VERSION}.el${EL_MAJOR_VERSION}"

# Used for PX module rpm building
ARG KVERSION="${KERNEL_VERSION_FULL_RPM}.x86_64"
ARG PX_FUSE_REPO="https://github.com/rpardini/px-fuse-mainline.git"
ARG PX_FUSE_BRANCH="v3.0.4-rpm-fixes"

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Common shared basebuilder; definitely build this with --pull so it doesn't bitrot
FROM rockylinux:${EL_VERSION} AS basebuilder

# Common deps across all kernels; try to have as much as possible here so cache is reused
# Developer tools for kernel building, from baseos; "yum-utils" for "yum-builddep"; "pciutils-libs" needed to install headers/devel later; cmake for building pahole
RUN dnf -y groupinstall 'Development Tools'
RUN dnf -y install ncurses-devel openssl-devel elfutils-libelf-devel python3 wget tree git rpmdevtools rpmlint yum-utils pciutils-libs cmake
RUN dnf -y install gcc-toolset-12 # 12.2.1-7 at the time of writing

# Use gcc-12 toolchain as default
SHELL ["/usr/bin/scl", "enable", "gcc-toolset-12", "--", "bash", "-c"]

RUN gcc --version

# FROM resets ARGs, so we need to redeclare them here
ARG PAHOLE_VERSION

# We need to build pahole from source, as the one in powertools is too old; we'll just overwrite the system one ("dwarves" yum pkg is still needed for deps)
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

# Stage specific args
ARG KERNEL_STUFF_DIR="${KERNEL_PKG}-${KERNEL_VERSION}"

WORKDIR /build

# Get the kernel tree via Docker
ADD https://www.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/linux-${KERNEL_VERSION_FULL}.tar.xz /build/
RUN tar -xf /build/linux-${KERNEL_VERSION_FULL}.tar.xz -C /build/
RUN ls -la /build/
RUN exit 1

# Add configs/patches/etc; for now only config
ADD ${KERNEL_STUFF_DIR} /build/stuff

# check again what gcc version is being used
RUN gcc --version

# Copy the config to the kernel tree
RUN cp /build/stuff/config /build/linux-${KERNEL_VERSION_FULL}/.config

# prepares the SRPM, which checks that all sources are indeed in place
RUN rpmbuild -bs ${KERNEL_SPEC_FILE}

# Actually build the binary RPMs
# Consider that /root/rpmbuild/BUILD is 25GB+ after the build, so exporting it to layer would take a while and will fill your host's disk. Remove it.
RUN time rpmbuild -vv -bb ${KERNEL_SPEC_FILE} && rm -rf /root/rpmbuild/BUILD

RUN du -h -d 1 -x /root/rpmbuild

# PX Module kernelbuilder
FROM basebuilder as pxbuilder

# ARGs are lost everytime FROM is used, redeclare to get the global ones at the top of this Dockerfile
ARG KVERSION
ARG PX_FUSE_REPO
ARG PX_FUSE_BRANCH

WORKDIR /temprpm
COPY --from=kernelbuilder /root/rpmbuild/RPMS/x86_64/kernel-*-headers-*.rpm /temprpm/
COPY --from=kernelbuilder /root/rpmbuild/RPMS/x86_64/kernel-*-devel-*.rpm /temprpm/
COPY --from=kernelbuilder /root/rpmbuild/RPMS/x86_64/kernel-*-tools-*.rpm /temprpm/
RUN yum install -y /temprpm/kernel-*.rpm --allowerasing

WORKDIR /src/
RUN git clone ${PX_FUSE_REPO} px-fuse # https://github.com/portworx/px-fuse.git

# check again what gcc version is being used
RUN gcc --version

WORKDIR /src/px-fuse
RUN git checkout ${PX_FUSE_BRANCH} # v3.0.4
RUN autoreconf && ./configure # Needed to get a root Makefile
RUN make rpm KVERSION=${KVERSION}
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

