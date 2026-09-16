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
#	Verify a scrub request with outstanding DTLs is rejected and starts
#	healing resilver I/O instead of reporting a successful scrub.
#
# STRATEGY:
#	1. Start a replacement with scan progress paused.
#	2. Fail repair writes during the initial resilver, leaving the
#	   replacement incomplete.
#	3. Request a scrub and verify it is rejected while a resilver starts.
#	4. Verify scrub pause does not apply to that resilver.
#	5. Fail its repair writes and verify the original is not detached.
#	6. Run it again with read errors injected on the DTL-missing child.
#	7. Verify resilver I/O, repair, detach, and that a later genuine scrub
#	   is accepted.
#

verify_runnable "global"

function inject_count
{
	zinject | awk '
		/^ *[0-9]/ {
			count++
			inject = $NF
		}
		END {
			if (count != 1)
				exit 1
			print inject
		}'
}

function cleanup
{
	zinject -c all >/dev/null 2>&1
	# Destroy before restoring progress so cleanup cannot finish repair.
	destroy_pool "$TESTPOOL1"
	set_tunable32 SCAN_SUSPEND_PROGRESS \
	    "$ORIG_SCAN_SUSPEND_PROGRESS" >/dev/null 2>&1
	rm -f "${VDEV_FILES[@]}" "$SPARE_VDEV_FILE"
}

log_assert "Scrub requests with outstanding DTLs are rejected in favor of repair"

ORIG_SCAN_SUSPEND_PROGRESS=$(get_tunable SCAN_SUSPEND_PROGRESS)

log_onexit cleanup

log_must zinject -c all
log_must truncate -s "$VDEV_FILE_SIZE" \
    "${VDEV_FILES[0]}" "$SPARE_VDEV_FILE"
# Exercise scrub admission without the optional manual-resilver feature.
log_must zpool create -f -o feature@resilver_defer=disabled \
    "$TESTPOOL1" "${VDEV_FILES[0]}"
log_must zfs create "$TESTPOOL1/$TESTFS"

mntpnt=$(get_prop mountpoint "$TESTPOOL1/$TESTFS")
log_must dd if=/dev/urandom of="$mntpnt/file" bs=1M count=1
sync_pool "$TESTPOOL1"

log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
log_must zpool replace "$TESTPOOL1" "${VDEV_FILES[0]}" \
    "$SPARE_VDEV_FILE"
log_must is_pool_resilvering "$TESTPOOL1"
log_must zinject -d "$SPARE_VDEV_FILE" -e io -T write -f 100 "$TESTPOOL1"
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must zpool wait -t resilver "$TESTPOOL1"
log_must is_pool_resilvered "$TESTPOOL1"
write_inject_count=$(inject_count) ||
    log_fail "zinject did not report exactly one active rule"
(( write_inject_count > 0 )) || log_fail "repair write injection did not fire"
log_must zinject -c all

pool_status=$(zpool status -P "$TESTPOOL1") ||
    log_fail "unable to read pool status after failed repair"
[[ "$pool_status" == *replacing-* &&
    "$pool_status" == *"${VDEV_FILES[0]}"* &&
    "$pool_status" == *"$SPARE_VDEV_FILE"* ]] ||
    log_fail "replacement topology was not preserved: $pool_status"

# Hold the newly scheduled healing pass while checking its identity and
# rejecting scrub-only controls; a fast completed pass would hide misreporting.
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
log_mustnot zpool scrub "$TESTPOOL1"
sync_pool "$TESTPOOL1"
log_must is_pool_resilvering "$TESTPOOL1"
log_mustnot zpool scrub -p "$TESTPOOL1"
log_mustnot zpool scrub -s "$TESTPOOL1"
log_must is_pool_resilvering "$TESTPOOL1"

# Failed repair writes must preserve the DTL and the original child.
log_must zinject -d "$SPARE_VDEV_FILE" -e io -T write -f 100 "$TESTPOOL1"
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must zpool wait -t resilver "$TESTPOOL1"
write_inject_count=$(inject_count) ||
    log_fail "zinject did not report exactly one active rule"
(( write_inject_count > 0 )) || log_fail "repair write injection did not fire"
log_must zinject -c all
log_must is_pool_replacing "$TESTPOOL1"

# Ordinary healing reads must select the original, not the DTL-missing target.
# A zero injection count checks source selection as well as eventual repair.
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
log_must zinject -d "$SPARE_VDEV_FILE" -e io -T read -f 100 "$TESTPOOL1"
log_must zpool events -c
log_mustnot zpool scrub "$TESTPOOL1"
sync_pool "$TESTPOOL1"
log_must is_pool_resilvering "$TESTPOOL1"

log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must zpool wait -t resilver "$TESTPOOL1"
target_inject_count=$(inject_count) ||
    log_fail "zinject did not report exactly one active rule"
log_must zinject -c all
[[ "$target_inject_count" == 0 ]] ||
    log_fail "scan read the replacement target (inject=$target_inject_count)"
log_must is_pool_resilvered "$TESTPOOL1"

log_must zpool wait -t replace "$TESTPOOL1"
pool_status=$(zpool status -P "$TESTPOOL1") ||
    log_fail "unable to read pool status after resilver"
[[ "$pool_status" != *replacing-* &&
    "$pool_status" != *"${VDEV_FILES[0]}"* &&
    "$pool_status" == *"$SPARE_VDEV_FILE"* ]] ||
    log_fail "replacement did not complete: $pool_status"

resilver_finish=$(zpool events | \
    awk '/sysevent.fs.zfs.resilver_finish/ { count++ } END { print count + 0 }')
(( resilver_finish >= 1 )) ||
    log_fail "expected a resilver finish event, found $resilver_finish"

# Healing must not advance the incremental-scrub verification boundary.
last_scrubbed=$(zpool get -H -o value last_scrubbed_txg "$TESTPOOL1")
[[ "$last_scrubbed" == 0 ]] ||
    log_fail "healing resilver advanced last_scrubbed_txg to $last_scrubbed"

log_must check_pool_status "$TESTPOOL1" "scan" \
    "resilvered .*with 0 errors"
log_must check_pool_status "$TESTPOOL1" "errors" "No known data errors"
log_must zdb -cdui "$TESTPOOL1/$TESTFS"

# Once healing is complete, genuine scrub controls and paused-state persistence
# must still work, and only completed verification advances last_scrubbed_txg.
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
log_must zpool scrub -t "$TESTPOOL1"
log_must zpool scrub -p "$TESTPOOL1"
log_must zpool export "$TESTPOOL1"
log_must zpool import -d "$TEST_BASE_DIR" "$TESTPOOL1"
log_must is_pool_scrub_paused "$TESTPOOL1"
log_must zpool scrub -t "$TESTPOOL1"
log_must zpool scrub -s "$TESTPOOL1"
log_must is_pool_scrub_stopped "$TESTPOOL1"
log_must zpool scrub "$TESTPOOL1"
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must zpool wait -t scrub "$TESTPOOL1"
last_scrubbed=$(zpool get -H -o value last_scrubbed_txg "$TESTPOOL1")
[[ "$last_scrubbed" != 0 ]] ||
    log_fail "genuine scrub did not advance last_scrubbed_txg"

log_pass "Scrub requests with outstanding DTLs are rejected in favor of repair"
