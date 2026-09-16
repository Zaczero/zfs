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

#
# DESCRIPTION:
#	Repair-write errors survive a persisted scan bookmark and import.
#	Unvisited metadata retains the original.
#	The recovery override permits retirement without erasing diagnostics.
#
# STRATEGY:
#	1. Fail replacement writes during healing.
#	2. Import an errorful healing bookmark, or prevent traversal of metadata
#	   whose children span older TXGs, and require the original to remain.
#	3. Remove the faults, finish replacement, and verify the file cold.
#	4. Allow errorful healing to retire DTLs with the override, while
#	   requiring the diagnostic count to survive import.
#

verify_runnable "global"

function cleanup
{
	zinject -c all >/dev/null 2>&1
	# Destroy before restoring progress so cleanup cannot finish repair.
	destroy_pool "$TESTPOOL1"
	set_tunable32 SCAN_IGNORE_ERRORS "$orig_ignore"
	set_tunable32 SCAN_SUSPEND_PROGRESS "$orig_suspend"
	set_tunable32 SCAN_LEGACY "$orig_legacy"
	set_tunable32 RESILVER_MIN_TIME_MS "$orig_min_time"
	set_tunable64 SCAN_VDEV_LIMIT "$orig_vdev_limit"
	rm -rf "$workdir"
}

log_assert "Incomplete repair retains its error evidence and original device"
orig_ignore=$(get_tunable SCAN_IGNORE_ERRORS)
orig_suspend=$(get_tunable SCAN_SUSPEND_PROGRESS)
orig_legacy=$(get_tunable SCAN_LEGACY)
orig_min_time=$(get_tunable RESILVER_MIN_TIME_MS)
orig_vdev_limit=$(get_tunable SCAN_VDEV_LIMIT)
workdir=$(mktemp -d "$TEST_BASE_DIR/resilver_errors.XXXXXX") ||
    log_fail "cannot create test directory"
log_onexit cleanup
log_must set_tunable32 SCAN_IGNORE_ERRORS 0
log_must truncate -s 512M "$workdir"/disk-{0,1}
log_must dd if=/dev/urandom of="$workdir/expected" bs=1M count=64
# Small legacy I/O batches leave a file bookmark before the scan finishes.
log_must set_tunable32 SCAN_LEGACY 1
log_must set_tunable32 RESILVER_MIN_TIME_MS 1
log_must set_tunable64 SCAN_VDEV_LIMIT 131072

for failure in import metadata; do
	log_note "Repair failure: $failure"
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
	# Suppress the write and report failure, leaving missing bytes and DTLs.
	# An I/O error alone can be injected after bytes are written.
	log_must zinject -d "$workdir/disk-1" -e noop -T write \
	    -f 100 "$TESTPOOL1"
	log_must zinject -d "$workdir/disk-1" -e io -T write \
	    -f 100 "$TESTPOOL1"

	if [[ "$failure" == import ]]; then
		log_must zinject -d "$workdir/disk-0" -D 10:1 -T read "$TESTPOOL1"
	fi
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
	if [[ "$failure" == import ]]; then
		# Freeze and sync before zdb opens the MOS; otherwise it can see
		# a completed scan instead of the errorful prefix to import.
		# The MOS scan array is dsl_scan_phys_t: errors is word 14;
		# bookmark object and block ID are words 21 and 23.
		for ((i = 0; i < 30; i++)); do
			sync_pool "$TESTPOOL1"
			log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
			sync_pool "$TESTPOOL1"
			log_must eval "zdb -dddd '$TESTPOOL1' 1 >'$workdir/scan'"
			# shellcheck disable=SC2016 # awk field references
			log_must awk '$1 == "scan" { print }' "$workdir/scan"
			if awk -v object="$object" '$1 == "scan" {
			    found = ($4 == 1 && $16 > 0 &&
			        $23 == object && $25 > 0)
			} END { exit !found }' "$workdir/scan"; then
				break
			fi
			log_must is_pool_resilvering "$TESTPOOL1"
			log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
		done
		(( i < 30 )) || log_fail "no errorful persisted file bookmark"
		log_must is_pool_resilvering "$TESTPOOL1"
		log_must zinject -c all
		log_must zpool export "$TESTPOOL1"
		log_must zpool import -d "$workdir" "$TESTPOOL1"
		log_must is_pool_replacing "$TESTPOOL1"
	else
		log_must zpool wait -t resilver "$TESTPOOL1"
		log_must is_pool_replacing "$TESTPOOL1"
		log_must zinject -c all
	fi

	if [[ "$failure" == metadata ]]; then
		# Drop cached metadata before blocking file-child traversal.
		log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
		log_must zpool export "$TESTPOOL1"
		log_must zpool import -d "$workdir" "$TESTPOOL1"
		sync_pool "$TESTPOOL1"
		log_must is_pool_resilvering "$TESTPOOL1"
		log_must zinject -a -t data -l 1 -e io -f 100 "$mntpnt/file"
		log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
		log_must zpool wait -t resilver "$TESTPOOL1"
		log_must zinject
		count=$(zinject | awk '/^ *[0-9]/ { print $NF }')
		(( count > 0 )) || log_fail "metadata injection did not fire"
		log_must is_pool_replacing "$TESTPOOL1"
		log_must zinject -c all
	fi

	if [[ "$failure" != import ]]; then
		# Rejected scrub admission schedules the remaining healing work.
		log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
		log_mustnot zpool scrub "$TESTPOOL1"
	fi
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
	log_must zpool wait -t replace "$TESTPOOL1"
	log_must zpool export "$TESTPOOL1"
	log_must zpool import -d "$workdir" "$TESTPOOL1"
	log_must cmp "$workdir/expected" "$mntpnt/file"
	destroy_pool "$TESTPOOL1"
done

log_note "Recovery override diagnostics"
# Attach keeps the original available after deliberately authorizing incomplete
# repair. Export/import makes the logical metadata injection reach disk reads.
log_must truncate -s 0 "$workdir"/disk-{0,1}
log_must truncate -s 512M "$workdir"/disk-{0,1}
log_must zpool create -f "$TESTPOOL1" "$workdir/disk-0"
log_must zfs create -o compression=off -o atime=off -o recordsize=128k \
    "$TESTPOOL1/$TESTFS"
mntpnt=$(get_prop mountpoint "$TESTPOOL1/$TESTFS")
log_must cp "$workdir/expected" "$mntpnt/file"
sync_pool "$TESTPOOL1"
log_must zpool export "$TESTPOOL1"
log_must zpool import -d "$workdir" "$TESTPOOL1"
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
log_must set_tunable32 SCAN_IGNORE_ERRORS 1
log_must zpool attach "$TESTPOOL1" "$workdir/disk-0" "$workdir/disk-1"
log_must zinject -a -t data -l 1 -e io -f 100 "$mntpnt/file"
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must zpool wait -t resilver "$TESTPOOL1"
log_must set_tunable32 SCAN_IGNORE_ERRORS 0
log_must zinject -c all
log_must check_pool_status "$TESTPOOL1" scan \
    "resilvered .*with [1-9][0-9]* errors" true
# Completion status alone does not show that the override retired missing DTLs.
log_must eval "zdb -ddd '$TESTPOOL1' >'$workdir/dtl'"
# shellcheck disable=SC2016 # awk field references
log_must awk -v leaf="$workdir/disk-1" '
    $2 ~ /^\[DTL-/ {
        selected = ($1 == leaf)
        if (selected) found = 1
    }
    selected && $1 == "missing" { missing = 1 }
    END { exit (!found || missing) }' "$workdir/dtl"
# Keep the known-good original: the override deliberately lost repairs.
log_must zpool offline "$TESTPOOL1" "$workdir/disk-1"
log_must zpool export "$TESTPOOL1"
log_must zpool import -d "$workdir" "$TESTPOOL1"
log_must check_pool_status "$TESTPOOL1" scan \
    "resilvered .*with [1-9][0-9]* errors" true
log_must cmp "$workdir/expected" "$mntpnt/file"

log_pass "Incomplete repair retains its error evidence and original device"
