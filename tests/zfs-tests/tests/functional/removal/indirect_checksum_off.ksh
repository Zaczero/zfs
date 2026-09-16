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
. "$STF_SUITE"/tests/functional/removal/indirect_test.kshlib

#
# DESCRIPTION:
#	Scrubs preserve differing checksumless copies; resilvers repair missing ones.
#

verify_runnable "global"

function cleanup
{
	zinject -c all >/dev/null 2>&1
	# Destroy before restoring progress so cleanup cannot finish repair.
	destroy_pool "$TESTPOOL1"
	set_tunable32 SCAN_SUSPEND_PROGRESS \
	    "$ORIG_SCAN_SUSPEND_PROGRESS" >/dev/null 2>&1
	set_tunable32 REMOVE_MAX_SEGMENT \
	    "$ORIG_REMOVE_MAX_SEGMENT" >/dev/null 2>&1
	rm -f "${VDEV_FILES[0]}" "${VDEV_FILES[1]}" "${VDEV_FILES[2]}" \
	    "$SPARE_VDEV_FILE"
	rm -rf "$workdir"
}

log_assert "Checksumless split repair preserves differing current copies"

ORIG_SCAN_SUSPEND_PROGRESS=$(get_tunable SCAN_SUSPEND_PROGRESS)
ORIG_REMOVE_MAX_SEGMENT=$(get_tunable REMOVE_MAX_SEGMENT)
workdir=$(mktemp -d "$TEST_BASE_DIR/indirect_checksum_off.XXXXXX") ||
    log_fail "cannot create test directory"
set -A VDEV_FILES "$workdir"/disk-{0,1,2}
SPARE_VDEV_FILE="$workdir/spare"
log_onexit cleanup

log_must zinject -c all
# Removal needs free space beyond the pool's minimum slop reservation.
log_must truncate -s 512M \
    "${VDEV_FILES[0]}" "${VDEV_FILES[1]}" "$SPARE_VDEV_FILE"
log_must zpool create -f -o feature@resilver_defer=disabled \
    "$TESTPOOL1" "${VDEV_FILES[1]}"
# Keep file data out of the ARC so that every read reaches the leaves.
log_must zfs create -o recordsize=128k -o compression=off -o atime=off \
    -o primarycache=metadata "$TESTPOOL1/$TESTFS"
mntpnt=$(get_prop mountpoint "$TESTPOOL1/$TESTFS")
log_must file_write -o create -f "$workdir/expected" \
    -b 131072 -c 1 -d 65
log_must zfs create -o checksum=off "$TESTPOOL1/$TESTFS/off"
log_must cp "$workdir/expected" "$mntpnt/off/file"
sync_pool "$TESTPOOL1"
off_object=$(get_objnum "$mntpnt/off/file")

log_must zpool add "$TESTPOOL1" "${VDEV_FILES[0]}"
log_must set_tunable32 REMOVE_MAX_SEGMENT 32768
log_must zpool remove -w "$TESTPOOL1" "${VDEV_FILES[1]}"
log_must set_tunable32 REMOVE_MAX_SEGMENT "$ORIG_REMOVE_MAX_SEGMENT"

log_must truncate -s 512M "${VDEV_FILES[2]}"
log_must zpool attach -w "$TESTPOOL1" "${VDEV_FILES[0]}" "${VDEV_FILES[2]}"
indirect_test_locate "$TESTPOOL1/$TESTFS/off" "$off_object" 20000
segment=$(printf "%x:%x:r" "$disk_offset" "$segment_size")
log_must zpool export "$TESTPOOL1"
log_must file_write -o create -f "$workdir/bad-sector" \
    -b 512 -c 1 -d 165
log_must dd if="$workdir/bad-sector" of="${VDEV_FILES[2]}" \
    bs=512 count=1 seek=$(((disk_offset + 4194304) / 512)) conv=notrunc
log_must zpool import -d "$workdir" "$TESTPOOL1"
for leaf in "${VDEV_FILES[0]}" "${VDEV_FILES[2]}"; do
	log_must eval "zdb -R '$TESTPOOL1' '$leaf:$segment' \
	    >'$workdir/before-${leaf##*/}'"
done
log_mustnot cmp "$workdir/before-${VDEV_FILES[0]##*/}" \
    "$workdir/before-${VDEV_FILES[2]##*/}"
# Either copy may be the correct one; the scrub must overwrite neither.
log_must zpool scrub -w "$TESTPOOL1"
for leaf in "${VDEV_FILES[0]}" "${VDEV_FILES[2]}"; do
	log_must eval "zdb -R '$TESTPOOL1' '$leaf:$segment' \
	    >'$workdir/after-${leaf##*/}'"
	log_must cmp "$workdir/before-${leaf##*/}" "$workdir/after-${leaf##*/}"
done
# A copy missing the block is still repaired from one which is not.
log_must truncate -s 512M "$workdir/off-target"
log_must zpool replace -w "$TESTPOOL1" "${VDEV_FILES[2]}" "$workdir/off-target"
log_must eval "zdb -R '$TESTPOOL1' '$workdir/off-target:$segment' \
    >'$workdir/after-off-target'"
log_must cmp "$workdir/before-${VDEV_FILES[0]##*/}" "$workdir/after-off-target"


log_pass "Checksumless split repair preserved current copies"
