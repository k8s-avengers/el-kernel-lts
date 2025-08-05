#!/usr/bin/env bash

set -e

declare KERNEL_MAJOR="${KERNEL_MAJOR:-"6"}"
declare KERNEL_MINOR="${KERNEL_MINOR:-"12"}"
declare EL_MAJOR_VERSION="${EL_MAJOR_VERSION:-"9"}"
declare KERNEL_RPM_VERSION="${KERNEL_RPM_VERSION:-"666"}"
declare FLAVOR="${FLAVOR:-"${2:-"kvm"}"}" # kvm is much faster to build than generic
declare GITHUB_OUTPUT="${GITHUB_OUTPUT:-"github_actions.output.kv"}"

declare MATRIX_ID="${MATRIX_ID:-"${KERNEL_MAJOR}.${KERNEL_MINOR}.y-${FLAVOR}"}"

# Different toolchain settings for different kernel versions
declare GCC_TOOLSET_NAME="gcc-toolset-12"
declare PAHOLE_VERSION="v1.25"
# Different px-fuse branches for different kernel versions
declare PX_FUSE_BRANCH="v3.1.0-rpm-fixes-btf-nodeps"
# Different make rpm-pkg / make binrpm-pkg - 6.12+ can't build without a git tree; 6.1 doesn't build devel without binrpm-pkg
declare MAKE_COMMAND_RPM="rpm-pkg"

# Different NVIDIA settings for different kernel versions and arch
declare NVIDIA_OPEN_BRANCH="570"                           # Open driver "Production Branch", see https://www.nvidia.com/en-us/drivers/unix/
declare NVIDIA_NONFREE_RUN_URL="undefined-nonfree-run-url" # varies per-arch
declare NVIDIA_NONFREE_STAGE="nvidianonfreebuilder"        # defaults to building the nonfree modules TODO not used yet
declare NVIDIA_NONFREE_VERSION="undefined"

# Determine the architecture we're running on, as that will be the target architecture for the kernel build.
declare OS_ARCH="undefined" TOOLCHAIN_ARCH="undefined"
OS_ARCH="$(uname -m)"
case "${OS_ARCH}" in
	"x86_64" | "amd64")
		OS_ARCH="amd64"
		TOOLCHAIN_ARCH="x86_64"
		;;
	"aarch64" | "arm64")
		OS_ARCH="arm64"
		TOOLCHAIN_ARCH="aarch64"
		;;
	*)
		echo "ERROR: Unsupported architecture '${OS_ARCH}' for kernel build." >&2
		exit 1
		;;
esac
echo "--> Architecture: OS_ARCH: ${OS_ARCH}, TOOLCHAIN_ARCH: ${TOOLCHAIN_ARCH}" >&2

# Decide
case "${KERNEL_MINOR}" in
	12)
		GCC_TOOLSET_NAME="gcc-toolset-14"
		PAHOLE_VERSION="v1.30"
		PX_FUSE_BRANCH="v-aaaae3e-6.12-rpm-btf-fixes-2"
		MAKE_COMMAND_RPM="binrpm-pkg"
		;;
esac

# Decide nvidia nonfree stuff. This ends up all hardcoded, and _will_ break over time
# Go find the latests builds via https://www.nvidia.com/en-us/drivers/ and https://us.download.nvidia.com/XFree86/Linux-x86_64/
# or https://us.download.nvidia.com/XFree86/aarch64/ for arm64
case "${TOOLCHAIN_ARCH}:${KERNEL_MINOR}:" in
	"x86_64:1:") # 535, it probably builds for .1, as it works for aarch64. CONFIRMED
		NVIDIA_NONFREE_VERSION="535.261.03"
		NVIDIA_NONFREE_RUN_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/535.261.03/NVIDIA-Linux-x86_64-535.261.03.run"
		# If not, bump to 570: https://us.download.nvidia.com/XFree86/Linux-x86_64/570.172.08/NVIDIA-Linux-x86_64-570.172.08.run
		;;
	"x86_64:12:") # 535 builds fine for .12 on amd64, but NOT on aarch64 - CONFIRMED
		NVIDIA_NONFREE_VERSION="535.261.03"
		NVIDIA_NONFREE_RUN_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/535.261.03/NVIDIA-Linux-x86_64-535.261.03.run"
		# If not, bump to 570: https://us.download.nvidia.com/XFree86/Linux-x86_64/570.172.08/NVIDIA-Linux-x86_64-570.172.08.run
		;;

	"aarch64:1:") # 535 builds with .1 on arm64, but NOT with .12 - CONFIRMED
		NVIDIA_NONFREE_VERSION="535.261.03"
		NVIDIA_NONFREE_RUN_URL="https://us.download.nvidia.com/XFree86/aarch64/535.261.03/NVIDIA-Linux-aarch64-535.261.03.run"
		;;
	"aarch64:12:") # 570 builds fine for .12 on arm64 - CONFIRMED
		NVIDIA_NONFREE_VERSION="570.172.08"
		NVIDIA_NONFREE_RUN_URL="https://us.download.nvidia.com/XFree86/aarch64/570.172.08/NVIDIA-Linux-aarch64-570.172.08.run"
		;;

	*)
		echo "ERROR: Unsupported TOOLCHAIN_ARCH:${TOOLCHAIN_ARCH} and KERNEL_MINOR:${KERNEL_MINOR} combination for NVIDIA nonfree run URL." >&2
		exit 1
		;;
esac

# If FIXED_POINT_RELEASE is set, skip the check and use it
if [[ -n "${FIXED_POINT_RELEASE:-""}" ]]; then
	KERNEL_POINT_RELEASE="${FIXED_POINT_RELEASE}"
	echo "Using FIXED_POINT_RELEASE: ${KERNEL_POINT_RELEASE}" >&2
	POINT_RELEASE_TRI="${KERNEL_MAJOR}.${KERNEL_MINOR}.${FIXED_POINT_RELEASE}"
	POINT_RELEASE="${FIXED_POINT_RELEASE}"
	echo "(fixed) POINT_RELEASE_TRI: ${POINT_RELEASE_TRI}" >&2
	echo "(fixed) POINT_RELEASE: ${POINT_RELEASE}" >&2
else
	if [[ ! -f kernel-releases.json ]]; then
		echo "Getting kernel-releases.json from kernel.org" >&2
		curl "https://www.kernel.org/releases.json" > kernel-releases.json
	else
		echo "Using disk cached kernel-releases.json" >&2
	fi

	set +e # multiple greps might fail in a pipe, allow for a while
	# shellcheck disable=SC2002 # cat is not useless. my cat's stylistic
	POINT_RELEASE_TRI="$(cat kernel-releases.json | jq -r ".releases[].version" | grep -v -e "^next\-" -e "\-rc" | grep -e "^${KERNEL_MAJOR}\.${KERNEL_MINOR}\.")"
	POINT_RELEASE="$(echo "${POINT_RELEASE_TRI}" | cut -d '.' -f 3)"
	echo "POINT_RELEASE_TRI: ${POINT_RELEASE_TRI}" >&2
	echo "POINT_RELEASE: ${POINT_RELEASE}" >&2
	set -e # back to normal
	if [[ -z "${POINT_RELEASE}" ]]; then
		echo "ERROR: Could not find a point release for ${KERNEL_MAJOR}.${KERNEL_MINOR} in kernel-releases.json" >&2
		exit 1
	fi
fi

# Calculate the input DEFCONFIG
INPUT_DEFCONFIG="defconfigs/${FLAVOR}-${KERNEL_MAJOR}.${KERNEL_MINOR}-${TOOLCHAIN_ARCH}"
if [[ ! -f "${INPUT_DEFCONFIG}" ]]; then
	echo "ERROR: ${INPUT_DEFCONFIG} does not exist, check inputs/envs" >&2
	exit 1
fi

declare KERNEL_POINT_RELEASE="${KERNEL_POINT_RELEASE:-"${POINT_RELEASE}"}"

# Calculate MATRIX_ID_POINT_RELEASE by replacing '.y' in MATRIX_ID with .${MATRIX_ID}
declare MATRIX_ID_POINT_RELEASE="${MATRIX_ID//.y/.${KERNEL_POINT_RELEASE}}"
echo "MATRIX_ID_POINT_RELEASE: ${MATRIX_ID_POINT_RELEASE}" >&2

declare -a build_args=(
	"--build-arg" "KERNEL_MAJOR=${KERNEL_MAJOR}"
	"--build-arg" "KERNEL_MINOR=${KERNEL_MINOR}"
	"--build-arg" "EL_MAJOR_VERSION=${EL_MAJOR_VERSION}"
	"--build-arg" "KERNEL_RPM_VERSION=${KERNEL_RPM_VERSION}"
	"--build-arg" "KERNEL_POINT_RELEASE=${KERNEL_POINT_RELEASE}"
	"--build-arg" "TOOLCHAIN_ARCH=${TOOLCHAIN_ARCH}"
	"--build-arg" "OS_ARCH=${OS_ARCH}"
	"--build-arg" "FLAVOR=${FLAVOR}"
	"--build-arg" "INPUT_DEFCONFIG=${INPUT_DEFCONFIG}"
	"--build-arg" "MAKE_COMMAND_RPM=${MAKE_COMMAND_RPM}"
	"--build-arg" "GCC_TOOLSET_NAME=${GCC_TOOLSET_NAME}"
	"--build-arg" "PX_FUSE_BRANCH=${PX_FUSE_BRANCH}"
	"--build-arg" "NVIDIA_NONFREE_RUN_URL=${NVIDIA_NONFREE_RUN_URL}"
	"--build-arg" "NVIDIA_NONFREE_STAGE=${NVIDIA_NONFREE_STAGE}"
	"--build-arg" "NVIDIA_NONFREE_VERSION=${NVIDIA_NONFREE_VERSION}"
	"--build-arg" "NVIDIA_OPEN_BRANCH=${NVIDIA_OPEN_BRANCH}"
)

echo "-- Args: ${build_args[*]}" >&2

case "${1:-"build"}" in
	config | shellconfig)
		# bail if not interactive (stdin is a terminal)
		[[ ! -t 0 ]] && echo "not interactive, can't configure" >&2 && exit 1
		docker buildx build --progress=plain -t k8s-avengers/el-kernel-lts:builder --target kernelconfigured "${build_args[@]}" .

		case "${1}" in
			shellconfig)
				echo "'Config ${INPUT_DEFCONFIG}' && make menuconfig && make savedefconfig && cp defconfig /host/${INPUT_DEFCONFIG}"
				echo "To produce a kvm config: rm .config; make ARCH=arm64 defconfig && make ARCH=arm64 kvm_guest.config && make savedefconfig && cp defconfig /host/${INPUT_DEFCONFIG}"
				docker run -it --rm -v "$(pwd):/host" k8s-avengers/el-kernel-lts:builder bash
				;;
			config)
				docker run -it --rm -v "$(pwd):/host" k8s-avengers/el-kernel-lts:builder bash -c "echo 'Config ${INPUT_DEFCONFIG}' && make menuconfig && make savedefconfig && cp defconfig /host/${INPUT_DEFCONFIG} && echo 'Saved ${INPUT_DEFCONFIG}'"
				;;
		esac
		exit 0
		;;

	build)
		docker buildx build --progress=plain -t k8s-avengers/el-kernel-lts:rpms "${build_args[@]}" .

		declare outdir="out-${KERNEL_MAJOR}.${KERNEL_MINOR}-${FLAVOR}-el${EL_MAJOR_VERSION}"
		docker run -it -v "$(pwd)/${outdir}:/host" k8s-avengers/el-kernel-lts:rpms sh -c "cp -rpv /out/* /host/"
		;;

	checkbuildandpush)
		set -x
		echo "BASE_OCI_REF: ${BASE_OCI_REF}" >&2 # Should end with a slash, or might have prefix, don't assume
		docker pull quay.io/skopeo/stable:latest

		declare FULL_VERSION="${FLAVOR}-${KERNEL_MAJOR}.${KERNEL_MINOR}.${KERNEL_POINT_RELEASE}-${KERNEL_RPM_VERSION}"
		declare image_versioned="${BASE_OCI_REF}el-kernel-lts:${FULL_VERSION}"
		declare image_latest="${BASE_OCI_REF}el-kernel-lts:${FLAVOR}-${KERNEL_MAJOR}.${KERNEL_MINOR}.y-latest"
		declare image_builder="${BASE_OCI_REF}el-kernel-lts:${FLAVOR}-${KERNEL_MAJOR}.${KERNEL_MINOR}.${KERNEL_POINT_RELEASE}-builder"

		echo "image_versioned: '${image_versioned}'" >&2
		echo "image_latest: '${image_latest}'" >&2
		echo "image_builder: '${image_builder}'" >&2

		# Set GH output with the full version
		echo "FULL_VERSION=${FULL_VERSION}" >> "${GITHUB_OUTPUT}"
		# Same with MATRIX_ID_POINT_RELEASE
		echo "MATRIX_ID_POINT_RELEASE=${MATRIX_ID_POINT_RELEASE}" >> "${GITHUB_OUTPUT}"

		# Use skopeo to check if the image_versioned tag already exists, if so, skip the build
		declare ALREADY_BUILT="no"
		if docker run quay.io/skopeo/stable:latest inspect "docker://${image_versioned}"; then
			echo "Image '${image_versioned}' already exists, skipping build." >&2
			ALREADY_BUILT="yes"
		fi

		echo "ALREADY_BUILT=${ALREADY_BUILT}" >> "${GITHUB_OUTPUT}"

		if [[ "${ALREADY_BUILT}" == "yes" ]]; then
			exit 0
		fi

		# build & tag up to the kernelconfigured stage as the image_builder
		docker buildx build --progress=plain -t "${image_builder}" --target kernelconfigured "${build_args[@]}" .

		# build final stage & push
		docker buildx build --progress=plain -t "${image_versioned}" "${build_args[@]}" .
		docker push "${image_versioned}"

		# tag & push the latest
		docker tag "${image_versioned}" "${image_latest}"
		docker push "${image_latest}"

		# push the builder
		if [[ "${PUSH_BUILDER_IMAGE:-"no"}" == "yes" ]]; then
			docker push "${image_builder}"
		fi

		# Get the built rpms out of the image and into our 'out' dir
		declare outdir="out"
		docker run -v "$(pwd)/${outdir}:/host" "${image_versioned}" sh -c "cp -rpv /out/* /host/"

		echo "Showing out dir:" >&2
		ls -lahR "${outdir}" >&2

		# Prepare a 'dist' dir with flat binary (not source) RPMs across all arches.
		echo "Preparing dist dir" >&2
		mkdir -p dist
		cp -v out/RPMS/*/*.rpm dist/
		ls -lahR "dist" >&2
		;;

esac

echo "Success." >&2
exit 0
