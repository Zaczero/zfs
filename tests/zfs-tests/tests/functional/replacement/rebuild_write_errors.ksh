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
#	Failed destination writes count as rebuild errors
#

verify_runnable "global"
log_assert "Failed destination writes count as rebuild errors"
rebuild_test_init

for mode in mirror mirror_failfast mirror_scrub target_offline draid \
    draid_speculative; do
	log_note "Testing $mode rebuild outcome"
	case "$mode" in
		mirror|mirror_failfast|mirror_scrub) rebuild_test_create 1 disabled ;;
		target_offline) rebuild_test_create 2 disabled mirror ;;
		draid) rebuild_test_create 5 disabled draid2:3d:5c:0s ;;
		draid_speculative) rebuild_test_create 3 disabled draid1:2d:3c:0s ;;
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
			log_must truncate -s 512M "$rebuild_dir/disk-extra"
			log_must zpool attach -s "$TESTPOOL1" \
			    "$rebuild_dir/disk-1" "$rebuild_dir/disk-extra"
			log_must zpool offline "$TESTPOOL1" "$rebuild_target"
			;;
		mirror_failfast)
			# Failfast errors are not retried, so the first failure
			# of each repair write is final.
			rebuild_test_inject -F -d "$rebuild_target" \
			    -e noop -T write -f 100
			rebuild_test_inject -F -d "$rebuild_target" \
			    -e io -T write -f 100
			;;
		mirror_scrub)
			# The scrub that follows cannot tell a silently dropped
			# repair from a successful one, so report every failure.
			rebuild_test_inject -d "$rebuild_target" \
			    -e io -T write -f 100
			;;
		*)
			# Drop data as well as reporting failure.
			rebuild_test_inject -d "$rebuild_target" \
			    -e noop -T write -f 100
			rebuild_test_inject -d "$rebuild_target" \
			    -e io -T write -f 100
			;;
	esac
	[[ "$mode" = mirror_scrub ]] &&
	    log_must set_tunable32 REBUILD_SCRUB_ENABLED 1
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
	rebuild_test_completed '[1-9][0-9]*'
	log_must rebuild_test_wait_fired $rebuild_inject_ids
	if [[ "$mode" = mirror_scrub ]]; then
		# Whichever pass follows the rebuild fails the same repairs
		# and must not retire them.
		log_must rebuild_test_wait scrub
		log_must rebuild_test_wait resilver
		log_must set_tunable32 REBUILD_SCRUB_ENABLED 0
	fi

	log_must rebuild_test_retained
	if [[ "$mode" = target_offline ]]; then
		log_must zpool online "$TESTPOOL1" "$rebuild_target"
	fi
	if [[ "$mode" = mirror* ]]; then
		# This checks the DTL, not just a race with async detachment.
		log_mustnot zpool detach "$TESTPOOL1" "$rebuild_dir/disk-0"
	fi
	if [[ "$mode" = mirror_failfast ]]; then
		# The failfast errors also fail ordinary writes to the new
		# device. Check only the rebuild's own accounting.
		log_must rebuild_test_clear_faults
		destroy_pool "$TESTPOOL1"
		rebuild_pool_created=0
		continue
	fi
	rebuild_test_finish
done


log_pass "Failed destination writes count as rebuild errors"
