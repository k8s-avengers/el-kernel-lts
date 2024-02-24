#!/usr/bin/env bash

set -e

declare KERNEL_MAJOR="${KERNEL_MAJOR:-"6"}"
declare KERNEL_MINOR="${KERNEL_MINOR:-"1"}"
declare EL_MAJOR_VERSION="${EL_MAJOR_VERSION:-"8"}"
declare KERNEL_RPM_VERSION="${KERNEL_RPM_VERSION:-"666"}"
declare FLAVOR="${FLAVOR:-"${2:-"kvm"}"}" # maybe default to generic? kvm is much faster to build
declare GITHUB_OUTPUT="${GITHUB_OUTPUT:-"github_actions.output.kv"}"

if [[ ! -f kernel-releases.json ]]; then
	echo "Getting kernel-releases.json from kernel.org" >&2
	curl "https://www.kernel.org/releases.json" > kernel-releases.json
else
	echo "Using disk cached kernel-releases.json" >&2
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

echo "-- Args: ${build_args[*]}" >&2

case "${1:-"build"}" in
	config)
		# bail if not interactive (stdin is a terminal)
		[[ ! -t 0 ]] && echo "not interactive, can't configure" >&2 && exit 1
		docker build -t k8s-avengers/el-kernel-lts:builder --target kernelconfigured "${build_args[@]}" .
		docker run -it --rm -v "$(pwd):/host" k8s-avengers/el-kernel-lts:builder bash -c "echo 'Config ${INPUT_DEFCONFIG}' && make menuconfig && make savedefconfig && cp defconfig /host/${INPUT_DEFCONFIG} && echo 'Saved ${INPUT_DEFCONFIG}'"
		;;

	build)
		docker build -t k8s-avengers/el-kernel-lts:rpms "${build_args[@]}" .

		declare outdir="out-${KERNEL_MAJOR}.${KERNEL_MINOR}-${FLAVOR}-el${EL_MAJOR_VERSION}"
		docker run -it -v "$(pwd)/${outdir}:/host" k8s-avengers/el-kernel-lts:rpms sh -c "cp -rpv /out/* /host/"
		;;

	checkbuildandpush)
		set -x
		echo "BASE_OCI_REF: ${BASE_OCI_REF}" >&2 # Should end with a slash, or might have prefix, don't assume
		docker pull quay.io/skopeo/stable:latest

		declare FULL_VERSION="el${EL_MAJOR_VERSION}-${FLAVOR}-${KERNEL_MAJOR}.${KERNEL_MINOR}.${KERNEL_POINT_RELEASE}-${KERNEL_RPM_VERSION}"
		declare image_versioned="${BASE_OCI_REF}el-kernel-lts:${FULL_VERSION}"
		declare image_latest="${BASE_OCI_REF}el-kernel-lts:el${EL_MAJOR_VERSION}-${FLAVOR}-${KERNEL_MAJOR}.${KERNEL_MINOR}.y-latest"
		declare image_builder="${BASE_OCI_REF}el-kernel-lts:el${EL_MAJOR_VERSION}-${FLAVOR}-${KERNEL_MAJOR}.${KERNEL_MINOR}.${KERNEL_POINT_RELEASE}-builder"

		echo "image_versioned: '${image_versioned}'" >&2
		echo "image_latest: '${image_latest}'" >&2
		echo "image_builder: '${image_builder}'" >&2

		# Set GH output with the full version
		echo "FULL_VERSION=${FULL_VERSION}" >> "${GITHUB_OUTPUT}"

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
		docker build -t "${image_builder}" --target kernelconfigured "${build_args[@]}" .

		# build final stage & push
		docker build -t "${image_versioned}" "${build_args[@]}" .
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
