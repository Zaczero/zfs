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

#
# DESCRIPTION:
#	Import validates saved coverage and rejects incomplete legacy state.
#

verify_runnable "global"

function cleanup
{
	rm -rf "$workdir"
}

log_assert "Imported healing progress is trusted only with intact coverage"
workdir=$(mktemp -d "$TEST_BASE_DIR/resilver_resume_state.XXXXXX") ||
    log_fail "cannot create test directory"
log_onexit cleanup
for mode in resume legacy advanced missed; do
	log_must resilver_probe "$workdir" "$mode"
done
log_pass "Imported healing progress preserved its coverage"
