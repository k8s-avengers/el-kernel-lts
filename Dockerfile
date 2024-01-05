ARG EL_MAJOR_VERSION=8
ARG EL_MINOR_VERSION=9
ARG EL_VERSION=${EL_MAJOR_VERSION}.${EL_MINOR_VERSION}

FROM rockylinux:${EL_VERSION}

ARG EL_MAJOR_VERSION
ARG EL_MINOR_VERSION
ARG EL_VERSION

ARG KERNEL_MAJOR=6
ARG KERNEL_MINOR=1
ARG KERNEL_VERSION=${KERNEL_MAJOR}.${KERNEL_MINOR}
ARG KERNEL_RPM_DIR="kernel-lts-${KERNEL_VERSION}-el${EL_MAJOR_VERSION}"
ARG KERNEL_SPEC_FILE=kernel-lts-${KERNEL_VERSION}.spec

# Developer tools for kernel building; "dwarves" for "pahole"; "yum-utils" for "yum-builddep"
RUN dnf -y groupinstall 'Development Tools'
RUN dnf -y install ncurses-devel openssl-devel elfutils-libelf-devel python3 wget tree git rpmdevtools rpmlint yum-utils
RUN dnf config-manager --set-enabled powertools
RUN dnf -y install dwarves

WORKDIR /root/rpmbuild

ADD ${KERNEL_RPM_DIR}/SPECS /root/rpmbuild/SPECS

RUN tree /root

WORKDIR /root/rpmbuild/SPECS

# install build dependencies from the spec file
RUN yum-builddep -y ${KERNEL_SPEC_FILE}

# Now add the SOURCES;
ADD ${KERNEL_RPM_DIR}/SOURCES /root/rpmbuild/SOURCES

# download the sources mentioned in the spec (eg: the kernel tarball)
RUN spectool -g -R ${KERNEL_SPEC_FILE}

# prepares the SRPM, which checks that all sources are indeed in place
RUN rpmbuild -bs ${KERNEL_SPEC_FILE}

# Actually build the binary RPMs
RUN time rpmbuild -bb ${KERNEL_SPEC_FILE}


