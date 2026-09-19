#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#

. "$STF_SUITE"/include/libtest.shlib
. "$STF_SUITE"/tests/functional/replacement/rebuild_test.kshlib

#
# DESCRIPTION:
#	Unreconstructable dRAID rows count as rebuild errors
#

verify_runnable "global"
log_assert "Unreconstructable dRAID rows count as rebuild errors"
rebuild_test_init

for mode in missing parity; do
	log_note "Testing dRAID row with $mode errors"
	if [[ "$mode" = missing ]]; then
		rebuild_test_create 3 disabled draid1:2d:3c:0s
		log_must zpool offline -f "$TESTPOOL1" "$rebuild_dir/disk-1"
	else
		rebuild_test_create 4 disabled draid2:2d:4c:0s
		# Reconstruct the new column so another parity column can reject it.
		log_must zpool offline -f "$TESTPOOL1" "$rebuild_dir/disk-0"
	fi
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
	log_must zpool replace -s "$TESTPOOL1" \
	    "$rebuild_dir/disk-0" "$rebuild_target"
	if [[ "$mode" = missing ]]; then
		# The unavailable child plus this error exceed parity.
		rebuild_test_inject -F -d "$rebuild_dir/disk-2" \
		    -e io -T read -f 100
	else
		rebuild_test_inject -d "$rebuild_dir/disk-2" \
		    -e corrupt -T read -f 100
	fi
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
	rebuild_test_completed '[1-9][0-9]*'
	log_must rebuild_test_wait_fired $rebuild_inject_ids
	log_must rebuild_test_retained
	rebuild_test_finish
done

log_pass "Unreconstructable dRAID rows count as rebuild errors"
