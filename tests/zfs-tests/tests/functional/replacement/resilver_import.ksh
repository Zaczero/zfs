#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source. A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#

# shellcheck disable=SC1091
. "$STF_SUITE"/include/libtest.shlib
. "$STF_SUITE"/tests/functional/replacement/replacement.cfg

. "$STF_SUITE"/tests/functional/replacement/resilver_test.kshlib

#
# DESCRIPTION:
#	An imported healing pass restarts incomplete coverage
#

verify_runnable "global"
log_assert "An imported healing pass restarts incomplete coverage"
resilver_test_init

# Small legacy I/O batches leave a file bookmark before the scan finishes.
log_must set_tunable32 SCAN_LEGACY 1
log_must set_tunable32 RESILVER_MIN_TIME_MS 1
log_must set_tunable64 SCAN_VDEV_LIMIT 131072

log_note "Repair failure: import"
log_must zpool create -f "$TESTPOOL1" "$workdir/disk-0"
log_must zfs create -o compression=off -o atime=off -o recordsize=128k \
    "$TESTPOOL1/$TESTFS"
mntpnt=$(get_prop mountpoint "$TESTPOOL1/$TESTFS")
# A later indirect block can reference children born in earlier TXGs.
# Losing it must not limit retained DTLs to the parent's birth TXG.
log_must dd if="$workdir/expected" of="$mntpnt/file" bs=1M count=32
sync_pool "$TESTPOOL1"
log_must dd if="$workdir/expected" of="$mntpnt/file" bs=1M \
    skip=32 seek=32 count=32 conv=notrunc
sync_pool "$TESTPOOL1"
object=$(get_objnum "$mntpnt/file")
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
log_must zpool replace "$TESTPOOL1" \
    "$workdir/disk-0" "$workdir/disk-1"
# Suppress the write and report failure, leaving missing bytes and
# DTLs. An I/O error alone can be injected after bytes are written.
log_must zinject -d "$workdir/disk-1" -e noop -T write \
    -f 100 "$TESTPOOL1"
log_must zinject -d "$workdir/disk-1" -e io -T write \
    -f 100 "$TESTPOOL1"

log_must zinject -d "$workdir/disk-0" -D 10:1 -T read "$TESTPOOL1"
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
# Freeze and sync before zdb opens the MOS; otherwise it can see
# a completed scan instead of the prefix to import. The MOS scan
# array is dsl_scan_phys_t: bookmark object and block ID are
# words 21 and 23.
for ((i = 0; i < 30; i++)); do
	sync_pool "$TESTPOOL1"
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
	sync_pool "$TESTPOOL1"
	log_must eval "zdb -dddd '$TESTPOOL1' 1 >'$workdir/scan'"
	# shellcheck disable=SC2016 # awk field references
	log_must awk '$1 == "scan" { print }' "$workdir/scan"
	if awk -v object="$object" '
	    $1 == "scan" {
		found = ($4 == 1 && $23 == object && $25 > 0)
	    }
	    END { exit !found }' "$workdir/scan"; then
		break
	fi
	log_must is_pool_resilvering "$TESTPOOL1"
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
done
(( i < 30 )) || log_fail "no persisted import file bookmark"
log_must is_pool_resilvering "$TESTPOOL1"
log_must zinject -c all
restarts=$(zpool history -i "$TESTPOOL1" |
    grep -c "scan aborted, restarting")
log_must zpool export "$TESTPOOL1"
log_must zpool import -d "$workdir" "$TESTPOOL1"
sync_pool "$TESTPOOL1"
log_must is_pool_replacing "$TESTPOOL1"
after=$(zpool history -i "$TESTPOOL1" |
    grep -c "scan aborted, restarting")
log_must test "$after" -gt "$restarts"


log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must zpool wait -t replace "$TESTPOOL1"
log_must zpool export "$TESTPOOL1"
log_must zpool import -d "$workdir" "$TESTPOOL1"
log_must cmp "$workdir/expected" "$mntpnt/file"
destroy_pool "$TESTPOOL1"
log_pass "An imported healing pass restarts incomplete coverage"
