ARG EL_MAJOR_VERSION=8
ARG EL_MINOR_VERSION=9
ARG EL_VERSION=${EL_MAJOR_VERSION}.${EL_MINOR_VERSION}

FROM rockylinux:${EL_VERSION} AS basebuilder

# Common deps across all kernels; try to have as much as possible here so cache is reused
# Developer tools for kernel building; "dwarves" for "pahole"; "yum-utils" for "yum-builddep"
RUN dnf -y groupinstall 'Development Tools'
RUN dnf -y install ncurses-devel openssl-devel elfutils-libelf-devel python3 wget tree git rpmdevtools rpmlint yum-utils
RUN dnf config-manager --set-enabled powertools
RUN dnf -y install dwarves

# For kernel building...
FROM basebuilder as builder

# ARGs are lost everytime FROM is used, but if we redefine them here, they will be available
ARG EL_MAJOR_VERSION
ARG EL_MINOR_VERSION
ARG EL_VERSION

ARG KERNEL_MAJOR=5
ARG KERNEL_MINOR=4
ARG KERNEL_PKG="kernel-lt"


ARG KERNEL_VERSION=${KERNEL_MAJOR}.${KERNEL_MINOR}
ARG KERNEL_RPM_DIR="${KERNEL_PKG}-${KERNEL_VERSION}-el${EL_MAJOR_VERSION}"
ARG KERNEL_SPEC_FILE="${KERNEL_PKG}-${KERNEL_VERSION}.spec"
ARG COMMON_RPM_DIR="common-el${EL_MAJOR_VERSION}"

WORKDIR /root/rpmbuild

ADD ${KERNEL_RPM_DIR}/SPECS /root/rpmbuild/SPECS

RUN tree /root

WORKDIR /root/rpmbuild/SPECS

# install build dependencies from the spec file
RUN yum-builddep -y ${KERNEL_SPEC_FILE}

# Add the common SOURCES:
ADD ${COMMON_RPM_DIR}/SOURCES /root/rpmbuild/SOURCES

# Now add the SOURCES specific to this kernel
ADD ${KERNEL_RPM_DIR}/SOURCES/* /root/rpmbuild/SOURCES/

# download the sources mentioned in the spec (eg: the kernel tarball)
RUN spectool -g -R ${KERNEL_SPEC_FILE}

# prepares the SRPM, which checks that all sources are indeed in place
RUN rpmbuild -bs ${KERNEL_SPEC_FILE}

# Actually build the binary RPMs
# Consider that /root/rpmbuild/BUILD is around 25GB right now, so exporting this layer will take a while and will fill your host's disk
RUN time rpmbuild -bb ${KERNEL_SPEC_FILE} # && rm -rf /root/rpmbuild/BUILD

RUN du -h -d 1 -x /root/rpmbuild && echo yes

# PX Module builder
FROM basebuilder as pxbuilder

RUN yum install automake autoconf gcc-c++

WORKDIR /src/
RUN git clone https://github.com/portworx/px-fuse.git
WORKDIR /src/px-fuse
RUN git checkout v3.0.4
#RUN autoreconf
#RUN ./configure
#RUN make
RUN make rpm


# Copy the RPMs to a new Alpine image for easy droppage of the .rpm's to host/etc
FROM alpine:latest

WORKDIR /out

COPY --from=builder /root/rpmbuild/RPMS /out/RPMS/
COPY --from=builder /root/rpmbuild/SRPMS /out/SRPMS/

COPY --from=pxbuilder /src/px-fuse/rpm/px/RPMS /out/RPMS/
COPY --from=pxbuilder /src/px-fuse/rpm/px/SRPMS /out/SRPMS/

RUN ls -laR /out

