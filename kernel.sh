#!/usr/bin/env bash

set -e

declare KERNEL_MAJOR="${KERNEL_MAJOR:-"6"}"
declare KERNEL_MINOR="${KERNEL_MINOR:-"1"}"
declare EL_MAJOR_VERSION="${EL_MAJOR_VERSION:-"8"}"
declare KERNEL_RPM_VERSION="${KERNEL_RPM_VERSION:-"666"}"
declare FLAVOR="${FLAVOR:-"${2:-"kvm"}"}" # maybe default to generic? kvm is much faster to build

if [[ ! -f kernel-releases.json ]]; then
	curl "https://www.kernel.org/releases.json" > kernel-releases.json
fi

# shellcheck disable=SC2002 # cat is not useless. my cat's stylistic
POINT_RELEASE_TRI="$(cat kernel-releases.json | jq -r ".releases[].version" | grep -v -e "^next\-" -e "\-rc" | grep -e "^${KERNEL_MAJOR}\.${KERNEL_MINOR}\.")"
POINT_RELEASE="$(echo "${POINT_RELEASE_TRI}" | cut -d '.' -f 3)"
echo "POINT_RELEASE_TRI: ${POINT_RELEASE_TRI}" >&2
echo "POINT_RELEASE: ${POINT_RELEASE}" >&2

# Calculate the input DEFCONFIG
INPUT_DEFCONFIG="defconfigs/${FLAVOR}-${KERNEL_MAJOR}.${KERNEL_MINOR}-x86_64"
if [[ ! -f "${INPUT_DEFCONFIG}" ]]; then
	echo "ERROR: ${INPUT_DEFCONFIG} does not exist, check inputs/envs" >&2
	exit 1
fi

declare KERNEL_POINT_RELEASE="${KERNEL_POINT_RELEASE:-"${POINT_RELEASE}"}"

declare -a build_args=(
	"--build-arg" "KERNEL_MAJOR=${KERNEL_MAJOR}"
	"--build-arg" "KERNEL_MINOR=${KERNEL_MINOR}"
	"--build-arg" "EL_MAJOR_VERSION=${EL_MAJOR_VERSION}"
	"--build-arg" "KERNEL_RPM_VERSION=${KERNEL_RPM_VERSION}"
	"--build-arg" "KERNEL_POINT_RELEASE=${KERNEL_POINT_RELEASE}"
	"--build-arg" "FLAVOR=${FLAVOR}"
	"--build-arg" "INPUT_DEFCONFIG=${INPUT_DEFCONFIG}"
)

set -x

case "${1:-"build"}" in
	config)
		# bail if not interactive (stdin is a terminal)
		[[ ! -t 0 ]] && echo "not interactive, can't configure" >&2 && exit 1
		docker build -t rpardini/el-kernel-lts:builder --target kernelreadytobuild "${build_args[@]}" .
		docker run -it --rm -v "$(pwd):/host" rpardini/el-kernel-lts:builder bash -c "echo 'Config ${INPUT_DEFCONFIG}' && make menuconfig && make savedefconfig && cp defconfig /host/${INPUT_DEFCONFIG} && echo 'Saved ${INPUT_DEFCONFIG}'"
		;;

	build)
		docker build -t rpardini/el-kernel-lts:rpms "${build_args[@]}" .
		;;

	buildandpush)
		echo "Not implemented: calc OCI_BASE and tag, check if on registry already, build if not, push, push latest tag as well" >&2
		exit 2
		;;

esac

echo "Success." >&2
exit 0
