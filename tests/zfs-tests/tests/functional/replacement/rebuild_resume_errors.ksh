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
#	Imported rebuilds preserve their failed-write accounting
#

verify_runnable "global"
log_assert "Imported rebuilds preserve their failed-write accounting"
rebuild_test_init

log_must set_tunable64 REBUILD_VDEV_LIMIT 1

log_note "Resuming a rebuild after failed writes"
rebuild_test_create 1 disabled
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
log_must zpool replace -s "$TESTPOOL1" "$rebuild_dir/disk-0" "$rebuild_target"
rebuild_test_inject -d "$rebuild_target" -e noop -T write -f 100
rebuild_test_inject -d "$rebuild_target" -e io -T write -f 100
failed=$rebuild_inject_last
rebuild_test_inject -d "$rebuild_dir/disk-0" -D 100:1 -T read
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must rebuild_test_wait_fired $failed
log_must rebuild_test_wait_errors
# Injection handlers prevent export. Stop progress before removing them.
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
log_must rebuild_test_clear_faults
log_must eval "zpool history -i '$TESTPOOL1' >'$rebuild_dir/history'"
log_mustnot grep -E " rebuild .* complete$" "$rebuild_dir/history"
log_must zpool export "$TESTPOOL1"
log_must zpool import -o cachefile=none -d "$rebuild_dir" "$TESTPOOL1"
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
rebuild_test_completed '[1-9][0-9]*'
log_mustnot grep -E " rebuild .* reset$" "$rebuild_dir/history"
log_must rebuild_test_retained
rebuild_test_finish

log_pass "Imported rebuilds preserve their failed-write accounting"
