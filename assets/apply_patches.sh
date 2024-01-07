#!/usr/bin/env bash

for patch in /build/patches/*.patch; do
	echo "Applying patch $patch" >&2
	patch -p1 < $patch
done

echo "All patches applied OK" >&2
exit 0
