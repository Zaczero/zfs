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

. "$STF_SUITE"/include/libtest.shlib
. "$STF_SUITE"/tests/functional/replacement/replacement.cfg
. "$STF_SUITE"/tests/functional/replacement/resilver_test.kshlib

#
# DESCRIPTION:
#	A healing read failure retains a source which may become readable again.
#

verify_runnable "global"
log_assert "Healing retains an unreadable source until its data is copied"
resilver_test_init

log_must zpool create -f "$TESTPOOL1" "$workdir/disk-0"
log_must zfs create -o compression=off -o primarycache=metadata \
    "$TESTPOOL1/$TESTFS"
mntpnt=$(get_prop mountpoint "$TESTPOOL1/$TESTFS")
log_must cp "$workdir/expected" "$mntpnt/file"
sync_pool "$TESTPOOL1"
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
log_must zpool replace "$TESTPOOL1" "$workdir/disk-0" "$workdir/disk-1"
log_must zinject -d "$workdir/disk-0" -e io -T read -f 100 "$TESTPOOL1"
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must zpool wait -t resilver "$TESTPOOL1"
log_must check_pool_status "$TESTPOOL1" scan \
    "resilvered .*with [1-9][0-9]* errors" true
log_must is_pool_replacing "$TESTPOOL1"
log_mustnot zpool detach "$TESTPOOL1" "$workdir/disk-0"

log_must zinject -c all
log_must zpool resilver "$TESTPOOL1"
sync_pool "$TESTPOOL1"
log_must zpool wait -t resilver,replace "$TESTPOOL1"
log_must zpool export "$TESTPOOL1"
log_must rm "$workdir/disk-0"
log_must zpool import -d "$workdir" "$TESTPOOL1"
log_must cmp "$workdir/expected" "$mntpnt/file"
log_must zpool scrub -w "$TESTPOOL1"
log_must check_pool_status "$TESTPOOL1" errors "No known data errors"

log_pass "Healing retained the unreadable source until its data was copied"
