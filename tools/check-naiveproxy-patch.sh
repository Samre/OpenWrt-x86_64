#!/bin/bash
#
# Exercises the naiveproxy workaround block from diy-part2.sh against the real
# feeds/small Makefile, without needing an OpenWrt tree.
#
# The block cannot simply be sourced from diy-part2.sh (the rest of that script
# needs an OpenWrt checkout), so the assertions are replayed here verbatim and
# cross-checked against the real file.
#
# Usage: bash tools/check-naiveproxy-patch.sh /path/to/fetched/Makefile

set -uo pipefail

MK="${1:?usage: $0 <path to naiveproxy Makefile>}"

NAIVEPROXY_OLD_VERSION="154.0.8037.49-1"
NAIVEPROXY_NEW_VERSION="154.0.8037.49-2"
NAIVEPROXY_OLD_HASH="55a10e6ca08696f9b606e1b3cb1a65aba72253756c5e1769d78edd78d4a1c6ab"
NAIVEPROXY_NEW_HASH="25ac92b86474fc62ed0e5008d7009f935115b9ae8a072f1fbafc92790ea283ce"

fail=0
pass() { printf '  PASS %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

# Baseline: how many PKG_HASH branches the file has BEFORE patching. Comparing
# against this (rather than a hard-coded literal) is what proves the sed did
# not add, remove or duplicate a branch.
HASH_BRANCHES_BEFORE=$(grep -c '^  PKG_HASH:=' "$MK")

echo "== preconditions (the file must look like the block expects) =="
c=$(grep -cF "PKG_REAL_VERSION:=$NAIVEPROXY_OLD_VERSION" "$MK")
[ "$c" -eq 1 ] && pass "PKG_REAL_VERSION occurs once (=$NAIVEPROXY_OLD_VERSION)" || bad "PKG_REAL_VERSION count=$c"

c=$(grep -cF "$NAIVEPROXY_OLD_HASH" "$MK")
[ "$c" -eq 1 ] && pass "old hash occurs exactly once (global sed is safe)" || bad "old hash count=$c"

# This is the assertion that makes the unconditional sed defensible.
echo
echo "== apply the same sed the build script applies =="
sed -i \
	-e "s/^PKG_REAL_VERSION:=${NAIVEPROXY_OLD_VERSION}\$/PKG_REAL_VERSION:=${NAIVEPROXY_NEW_VERSION}/" \
	-e "s/${NAIVEPROXY_OLD_HASH}/${NAIVEPROXY_NEW_HASH}/" \
	"$MK"

echo
echo "== postconditions =="
grep -qF "PKG_REAL_VERSION:=$NAIVEPROXY_NEW_VERSION" "$MK" \
	&& pass "version retargeted to $NAIVEPROXY_NEW_VERSION" || bad "version not retargeted"

if grep -qF "$NAIVEPROXY_OLD_HASH" "$MK"; then
	bad "old (deleted) hash still present"
else
	pass "old hash removed"
fi

c=$(grep -cF "$NAIVEPROXY_NEW_HASH" "$MK")
[ "$c" -eq 1 ] && pass "new hash occurs exactly once" || bad "new hash count=$c"

# The new hash must sit in the x86_64 branch, not somewhere else.
if sed -n '/x86_64/,+1p' "$MK" | grep -qF "$NAIVEPROXY_NEW_HASH"; then
	pass "new hash is inside the x86_64 branch"
else
	bad "new hash is NOT in the x86_64 branch"
fi

echo
echo "== resulting x86_64 branch =="
sed -n '/^else ifeq (\$(ARCH_PREBUILT),x86_64)/,+1p' "$MK"

echo
echo "== other architecture hashes untouched =="
# Comparing before/after proves the global sed touched exactly one branch.
total=$(grep -c '^  PKG_HASH:=' "$MK")
if [ "$total" -eq "$HASH_BRANCHES_BEFORE" ]; then
	pass "$total PKG_HASH branches before and after (none added or removed)"
else
	bad "PKG_HASH branch count changed: $HASH_BRANCHES_BEFORE -> $total"
fi
changed=$(grep -vF "$NAIVEPROXY_NEW_HASH" "$MK" | grep -c '^  PKG_HASH:=')
if [ "$changed" -eq "$((HASH_BRANCHES_BEFORE - 1))" ]; then
	pass "exactly one branch was rewritten"
else
	bad "unexpected number of rewritten branches"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
	printf 'naiveproxy workaround verified.\n'
else
	printf 'naiveproxy workaround FAILED.\n'
fi
exit "$fail"
