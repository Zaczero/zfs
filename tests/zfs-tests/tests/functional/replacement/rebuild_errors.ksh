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
#	Failed rebuild repairs retain DTLs and the original device.
#
# STRATEGY:
#	Exercise failed and speculative writes, a new device that is offline
#	during its rebuild, and a stale source that misses writes during the
#	rebuild. Require nonzero rebuild-local errors with post-rebuild
#	verification disabled, then heal and compare data after export/import.
#

verify_runnable "global"
log_assert "Incomplete rebuilds preserve repair obligations"
rebuild_test_init

for mode in mirror target_offline stale draid draid_speculative; do
	log_note "Testing $mode rebuild outcome"
	case "$mode" in
		mirror) rebuild_test_create 1 ;;
		target_offline|stale) rebuild_test_create 2 mirror ;;
		draid) rebuild_test_create 5 draid2:3d:5c:0s ;;
		draid_speculative) rebuild_test_create 3 draid1:2d:3c:0s ;;
	esac

	# With one unavailable child and a full-width dRAID1 group, every row
	# consumes all parity. Repair of the new child is speculative.
	if [[ "$mode" = draid_speculative ]]; then
		log_must zpool offline -f "$TESTPOOL1" "$rebuild_dir/disk-1"
	fi
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
	log_must zpool replace -s "$TESTPOOL1" \
	    "$rebuild_dir/disk-0" "$rebuild_target"

	case "$mode" in
		target_offline)
			# Writes to a device being rebuilt fail while it is
			# offline. A second new device keeps the rebuild going.
			log_must truncate -s 512M "$rebuild_dir/extra"
			log_must zpool attach -s "$TESTPOOL1" \
			    "$rebuild_dir/disk-1" "$rebuild_dir/extra"
			log_must zpool offline "$TESTPOOL1" "$rebuild_target"
			;;
		stale)
			# The other original member misses writes, then returns
			# as a rebuild source whose data is never verified.
			log_must zpool offline "$TESTPOOL1" "$rebuild_dir/disk-1"
			log_must cp "$rebuild_dir/expected" \
			    "$rebuild_dir/mnt/file2"
			sync_pool "$TESTPOOL1"
			log_must zpool online "$TESTPOOL1" "$rebuild_dir/disk-1"
			;;
		*)
			# Drop data as well as reporting failure.
			rebuild_test_inject -d "$rebuild_target" \
			    -e noop -T write -f 100
			rebuild_test_inject -d "$rebuild_target" \
			    -e io -T write -f 100
			;;
	esac
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
	rebuild_test_completed '[1-9][0-9]*'
	rebuild_test_faults_fired

	log_must is_pool_replacing "$TESTPOOL1"
	if [[ "$mode" = target_offline ]]; then
		log_must zpool online "$TESTPOOL1" "$rebuild_target"
	fi
	if [[ "$mode" = mirror ]]; then
		# This checks the DTL, not just a race with async detachment.
		log_mustnot zpool detach "$TESTPOOL1" "$rebuild_dir/disk-0"
	fi
	rebuild_test_finish
done

log_pass "Incomplete rebuilds retained repair obligations and diagnostic errors"
