#!/usr/bin/env bash

for patch in /build/patches/*.patch; do
	echo "Applying patch $patch" >&2
	if [[ "$patch" == "/build/patches/empty.patch" ]]; then
		echo "Skipping $patch -- empty placeholder." >&2
		continue
	fi

	patch -p1 < $patch
done

echo "All patches applied OK" >&2
exit 0
