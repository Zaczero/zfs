#!/bin/sh
# Run inside a disposable Linux/glibc guest with a configured OpenZFS build.
set -eu
evidence=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build=$(CDPATH= cd -- "$1" && pwd)
mkdir -p "$2"
out=$(CDPATH= cd -- "$2" && pwd)
cd "$build"
{
	uname -a
	${CC:-cc} --version
	./config.status --config
	sha256sum zfs_config.h module/icp/io/aes.c \
	    module/icp/algs/modes/gcm.c module/icp/algs/modes/modes.c
} > "$out/environment.txt"
timeout 180 make -f Makefile -f "$evidence/probe.mk" OUT="$out" \
    review-probes > "$out/build.log" 2>&1
timeout 90 "$out/allocation_probe" 32768 > "$out/allocation.log" 2>&1
set +e
timeout 30 "$out/cleanup_probe" > "$out/cleanup.log" 2>&1
rc=$?
set -e
echo "$rc" > "$out/cleanup.exit"
case "$rc" in
0) echo "Hash-table size and wipe checks passed.";;
1) echo "Hash-table size or wipe check failed; see cleanup.log."; exit 1;;
77) echo "No supported accelerated GCM implementation was exercised."; exit 77;;
*) exit "$rc";;
esac
