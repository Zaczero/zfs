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
#	Failed healing writes retain the original until recovery succeeds
#

verify_runnable "global"
log_assert "Failed healing writes retain the original until recovery succeeds"
resilver_test_init

for mode in retried failfast; do
	log_note "Failed healing writes: $mode"
	flags=""
	[[ $mode == failfast ]] && flags="-F"
	log_must rm -f "$workdir"/disk-{0,1}
	log_must truncate -s 512M "$workdir"/disk-{0,1}
	log_must zpool create -f "$TESTPOOL1" "$workdir/disk-0"
	log_must zfs create -o compression=off -o recordsize=128k "$TESTPOOL1/$TESTFS"
	mntpnt=$(get_prop mountpoint "$TESTPOOL1/$TESTFS")
	log_must cp "$workdir/expected" "$mntpnt/file"
	sync_pool "$TESTPOOL1"

	# Suppress the destination's writes as well as reporting failure.
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
	log_must zpool replace "$TESTPOOL1" "$workdir/disk-0" "$workdir/disk-1"
	log_must zinject $flags -d "$workdir/disk-1" -e noop -T write -f 100 "$TESTPOOL1"
	log_must zinject $flags -d "$workdir/disk-1" -e io -T write -f 100 "$TESTPOOL1"
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
	# A pass whose repairs failed is not retried until something changes.
	log_must timeout 300 zpool wait -t resilver "$TESTPOOL1"
	log_must zinject -c all
	log_must is_pool_replacing "$TESTPOOL1"
	log_must eval "zpool status '$TESTPOOL1' | grep -q '$workdir/disk-0'"

	log_must zpool resilver "$TESTPOOL1"
	log_must timeout 300 zpool wait -t resilver,replace "$TESTPOOL1"
	log_mustnot is_pool_replacing "$TESTPOOL1"
	log_must zpool export "$TESTPOOL1"
	log_must rm "$workdir/disk-0"
	log_must zpool import -d "$workdir" "$TESTPOOL1"
	log_must cmp "$workdir/expected" "$mntpnt/file"
	log_must zpool scrub -w "$TESTPOOL1"
	log_must check_pool_status "$TESTPOOL1" "errors" "No known data errors"

	log_must zpool destroy "$TESTPOOL1"
done

log_pass "Failed healing writes retain the original until recovery succeeds"
