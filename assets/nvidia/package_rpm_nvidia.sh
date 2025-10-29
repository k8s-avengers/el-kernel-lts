#!/usr/bin/env bash

echo "Args:" "${@}"

declare nvidia_source_dir="${1}"
declare KVERSION="${2}"
declare OS_ARCH="${3}"
declare TOOLCHAIN_ARCH="${4}"
declare KERNEL_VERSION_FULL="${5}"
declare RPM_OUTPUT_DIR="${6}"

# Objective here is to package the nvidia kernel modules, already built from source into binary form, into an RPM package.
# We know which .ko's to package by running `find . -type f -name "*.ko"` and taking only the base name of the file.
# Then for each of those .ko files, we will search in /lib/modules/${KVERSION} to find their path there and package them into an RPM.

if [[ -z "${nvidia_source_dir}" || -z "${KVERSION}" || -z "${OS_ARCH}" || -z "${TOOLCHAIN_ARCH}" || -z "${KERNEL_VERSION_FULL}" || -z "${RPM_OUTPUT_DIR}" ]]; then
	echo "Usage: $0 <nvidia_source_dir> <KVERSION> <OS_ARCH> <TOOLCHAIN_ARCH> <KERNEL_VERSION_FULL> <RPM_OUTPUT_DIR>"
	exit 1
fi

if [[ ! -d "${nvidia_source_dir}" ]]; then
	echo "Error: NVIDIA source directory '${nvidia_source_dir}' does not exist."
	exit 1
fi

# Use find and readarray to get the list of .ko files
readarray -t nvidia_modules < <(find "${nvidia_source_dir}" -type f -name "*.ko" -exec basename {} \;)
if [[ ${#nvidia_modules[@]} -eq 0 ]]; then
	echo "Error: No NVIDIA kernel modules found in '${nvidia_source_dir}'."
	exit 1
fi

echo "KO's to package: " "${nvidia_modules[@]}"

# Create an array with their paths in /lib/modules/${KVERSION}
declare -a kos_absolute_paths=()
for ko in "${nvidia_modules[@]}"; do
	# Find the relative path of the .ko file in /lib/modules/${KVERSION}
	absolute_path=$(find "/lib/modules/${KVERSION}" -type f -name "${ko}" 2> /dev/null)
	if [[ -n "${absolute_path}" ]]; then
		echo "Found ${ko} at ${absolute_path}"
		kos_absolute_paths+=("${absolute_path}")
	else
		echo "Error: Could not find ${ko} in /lib/modules/${KVERSION}."
		exit 2
	fi
done

echo "--> Absolute paths of .ko files in /lib/modules/${KVERSION}: " "${kos_absolute_paths[@]}"

# If NVIDIA_VERSION is unset...
if [[ -z "${NVIDIA_VERSION}" ]]; then
	# Read the version from the version.mk file in the nvidia source directory
	version_file="${nvidia_source_dir}/version.mk"
	if [[ ! -f "${version_file}" ]]; then
		echo "Error: version.mk file not found in '${nvidia_source_dir}'."
		exit 3
	fi

	# Parse the "NVIDIA_VERSION = 575.64.05" line; take anything after the '=' sign and trim
	declare nvidia_version
	nvidia_version="$(grep "^NVIDIA_VERSION" "${version_file}" | cut -d '=' -f 2 | tr -d '[:space:]')"

	echo "--> NVIDIA version extracted from version.mk: '${nvidia_version}'"
	if [[ -z "${nvidia_version}" ]]; then
		echo "Error: Could not extract NVIDIA version from version.mk."
		exit 4
	fi
else
	echo "Externally-set NVIDIA_VERSION: '${NVIDIA_VERSION}'"
	declare nvidia_version="${NVIDIA_VERSION}"
fi

# if KERNEL_RPM_VERSION is unset, bomb.
if [[ -z "${KERNEL_RPM_VERSION}" ]]; then
	echo "Error: KERNEL_RPM_VERSION is not set in environment."
	exit 1
fi

# Default NVIDIA_TYPE_DRIVER to "open" if not set
NVIDIA_TYPE_DRIVER="${NVIDIA_TYPE_DRIVER:-"open"}"

# Prepare the rpmbuild directory structure, under a temporary directory
declare tmp_rpmbuild_dir
tmp_rpmbuild_dir="$(mktemp -d /tmp/nvidia.rpmbuild.XXXXXX)"

mkdir -p "${tmp_rpmbuild_dir}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# Prepare the %install and %files sections of the SPEC file
declare install_section_file="${tmp_rpmbuild_dir}/install_section.spec"
declare files_section_file="${tmp_rpmbuild_dir}/files_section.spec"

# Loop through the absolute paths of the .ko files; strip the first slash and create the directory structure and copy the files
for ko in "${kos_absolute_paths[@]}"; do
	# Feed the install and files sections
	echo "${ko}" >> "${files_section_file}"
	echo "install -D -m 0755 ${ko} %{buildroot}${ko}" >> "${install_section_file}"
done

# Create the SPEC
declare spec_file="${tmp_rpmbuild_dir}/SPECS/nvidia-${NVIDIA_TYPE_DRIVER}.spec"
cat << SPEC_FILE > "${spec_file}"
Name:           nvidia-${NVIDIA_TYPE_DRIVER}-el-lts-modules
Version:        %{KERNEL_VERSION_FULL}.%{NVIDIA_VERSION}.${KERNEL_RPM_VERSION}
Release:        1
Summary:        nvidia ${NVIDIA_TYPE_DRIVER} modules %{TOOLCHAIN_ARCH}
License:        GPLv2
URL:            https://github.com/NVIDIA/open-gpu-kernel-modules

BuildArch:      %{TOOLCHAIN_ARCH}

# nvidia-kmod-common is a dependency of nvidia-driver-cuda userspace stuff (once you dnf module enable nvidia-driver:580)
# nvidia-kmod-common itself contains the matching/required gsp firmware files. THANKS NVIDIA, brilliant idea :-( !!
# So let's provide what nvidia-kmod-common requires, which is the kmod-nvidia/nvidia-kmod package of a certain version.
# EL10: dnf modules were such a terrible idea that the whole thing got dropped in EL10.
# EL10: also nvidia introduced kmod-nvidia-open-dkms, so we Provides: that here as well.
Provides:       nvidia-kmod
Provides:       kmod-nvidia
Provides:       kmod-nvidia-open-dkms
Provides:       nvidia-kmod = 3:%{NVIDIA_VERSION}
Provides:       kmod-nvidia = 3:%{NVIDIA_VERSION}
Provides:       nvidia-kmod = 4:%{NVIDIA_VERSION}
Provides:       kmod-nvidia = 4:%{NVIDIA_VERSION}
Provides:       nvidia-kmod = 5:%{NVIDIA_VERSION}
Provides:       kmod-nvidia = 5:%{NVIDIA_VERSION}
Provides:       kmod-nvidia-open-dkms = 3:%{NVIDIA_VERSION}
Provides:       kmod-nvidia-open-dkms = 4:%{NVIDIA_VERSION}
Provides:       kmod-nvidia-open-dkms = 5:%{NVIDIA_VERSION}

# From mainline linux's mkspec, to convince rpmbuild to not strip the module (and avoid breaking BTF info, if any, and signature, if any)
%define __spec_install_post /usr/lib/rpm/brp-compress || :
%define debug_package %{nil}

%description
nvidia ${NVIDIA_TYPE_DRIVER} modules %{NVIDIA_VERSION} ${KERNEL_RPM_VERSION} for el-kernel-lts %{KVERSION} for %{TOOLCHAIN_ARCH}

%prep
# Nothing.

%build
# Builds are done externally; this rpm only packages the pre-built binaries.

%install
$(cat "${install_section_file}")

%post
set -x
/sbin/depmod "%{KVERSION}" || true
echo "nvidia ${NVIDIA_TYPE_DRIVER} modules %{NVIDIA_VERSION} ${KERNEL_RPM_VERSION} for el-kernel-lts %{KVERSION} for %{TOOLCHAIN_ARCH} installed."

%files
$(cat "${files_section_file}")

%changelog
* Mon Jul 14 2025 Your Name <you@example.com> - %{KERNEL_VERSION_FULL}.%{NVIDIA_VERSION}.${KERNEL_RPM_VERSION}-1
- nvidia ${NVIDIA_TYPE_DRIVER} modules %{NVIDIA_VERSION} ${KERNEL_RPM_VERSION} for el-kernel-lts %{KERNEL_VERSION_FULL} for %{TOOLCHAIN_ARCH}
SPEC_FILE

# Show the tree of the rpmbuild directory
echo "Tree of the rpmbuild directory:"
tree "${tmp_rpmbuild_dir}"

echo ".spec file contents:"
cat "${spec_file}"

# Build the RPM package
rpmbuild --define "_topdir ${tmp_rpmbuild_dir}" --define "NVIDIA_VERSION ${nvidia_version}" \
	--define "KVERSION ${KVERSION}" \
	--define "TOOLCHAIN_ARCH ${TOOLCHAIN_ARCH}" \
	--define "KERNEL_VERSION_FULL ${KERNEL_VERSION_FULL}" \
	-bb "${spec_file}"

# Find the produced RPM package
declare produced_rpm
produced_rpm=$(find "${tmp_rpmbuild_dir}/RPMS" -type f -name "*.rpm" 2> /dev/null)
if [[ -z "${produced_rpm}" ]]; then
	echo "Error: No RPM package was produced."
	exit 6
fi
echo "Produced RPM package: ${produced_rpm}"
ls -laht "${produced_rpm}"

# Rename the original .ko's to .old to make space for installing the rpm
for ko in "${kos_absolute_paths[@]}"; do
	if [[ -f "${ko}" ]]; then
		mv -v "${ko}" "${ko}.old"
	else
		echo "Warning: ${ko} does not exist, cannot rename."
		exit 5
	fi
done

# Install the produced RPM package
echo "Installing the produced RPM package..."
rpm -Uvh "${produced_rpm}"

echo "Checking the installed .ko files in /lib/modules/${KVERSION}..."
# Check if the .old files match the new rpm-installed .ko files
for ko in "${kos_absolute_paths[@]}"; do
	echo "Testing ${ko} against ${ko}.old..."
	if [[ -f "${ko}" && -f "${ko}.old" ]]; then
		if ! diff -u "${ko}.old" "${ko}"; then
			echo "Difference found between ${ko} and ${ko}.old. The RPM installation did not match the original .ko file."
			file "${ko}" "${ko}.old"
		else
			echo "No difference found between ${ko} and ${ko}.old. The RPM installation matched the original .ko file."
			modinfo "${ko}"
		fi
	else
		echo "Warning: ${ko} or ${ko}.old does not exist, cannot compare."
	fi
done

# All done, move the .rpm to the target directory
mkdir -p "${RPM_OUTPUT_DIR}/${TOOLCHAIN_ARCH}"
mv -v "${produced_rpm}" "${RPM_OUTPUT_DIR}/${TOOLCHAIN_ARCH}"

exit 0
