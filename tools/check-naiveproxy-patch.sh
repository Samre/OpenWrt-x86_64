#!/bin/bash
#
# Exercises the naiveproxy patch logic from diy-part2.sh against the three
# states the feeds/small Makefile has actually been observed in.
#
# This test exists because the first version of that logic coupled the version
# fix and the hash fix behind a single condition:
#
#   if version is already -2:  skip everything
#   elif version is -1:        fix version AND hash
#
# The feed then moved to -2 on its own while leaving the x86_64 hash pointing at
# the deleted -1 archive - a state neither branch handled. The build failed with
# a checksum mismatch after a full compile, because the "skip" branch reported
# success. The logic is now two independent fix-ups, and this test pins that.
#
# Usage: bash tools/check-naiveproxy-patch.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/diy-part2.sh"

NEW_VERSION="154.0.8037.49-2"
OLD_HASH="55a10e6ca08696f9b606e1b3cb1a65aba72253756c5e1769d78edd78d4a1c6ab"
NEW_HASH="25ac92b86474fc62ed0e5008d7009f935115b9ae8a072f1fbafc92790ea283ce"

fail=0
pass() { printf '  PASS %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }

# Pull the naiveproxy variables out of diy-part2.sh so this test cannot drift
# from the script it is testing.
eval "$(grep -E '^NAIVEPROXY_(OLD|NEW)_(VERSION|HASH)=' "$SCRIPT")"

[ "$NAIVEPROXY_OLD_HASH" = "$OLD_HASH" ] || { echo "OLD_HASH differs from the script"; exit 1; }
[ "$NAIVEPROXY_NEW_HASH" = "$NEW_HASH" ] || { echo "NEW_HASH differs from the script"; exit 1; }

# Build a Makefile in a given state. Mirrors the real file's shape: one
# PKG_REAL_VERSION line and an architecture switch where x86_64 is the only
# branch this repository builds.
make_fixture() {
	local dir="$1" version="$2" x86hash="$3"
	mkdir -p "$dir"
	{
		echo "PKG_NAME:=naiveproxy"
		echo "PKG_REAL_VERSION:=$version"
		echo 'PKG_VERSION:=$(subst -,.,$(PKG_REAL_VERSION))'
		echo "PKG_RELEASE:=1"
		echo 'ifeq ($(ARCH_PREBUILT),aarch64_generic)'
		echo "  PKG_HASH:=2de0827b5c07fc19635692b4b21172062072a6e28dcce1b948e7c3b21ffd94e1"
		echo 'else ifeq ($(ARCH_PREBUILT),x86)'
		echo "  PKG_HASH:=898dd52ba02f9737aa31d891e0f9b24c2d066ee6de59d49dd52073f9333fa2da"
		echo 'else ifeq ($(ARCH_PREBUILT),x86_64)'
		echo "  PKG_HASH:=$x86hash"
		echo 'else'
		echo "  PKG_HASH:=dummy"
		echo 'endif'
	} > "$dir/Makefile"
}

# Extract just the naiveproxy block from diy-part2.sh and run it with
# NAIVEPROXY_MK pointed at the fixture. The rest of the script needs an OpenWrt
# tree, so only this block is extracted.
run_block() {
	local mk="$1"
	local block
	# Take the block from its first line down to the closing `fi` of the outer
	# `if [ -f "$NAIVEPROXY_MK" ]`.
	block="$(sed -n '/^NAIVEPROXY_MK=/,$ p' "$SCRIPT" | sed -n '1,/^fi$/p')"

	# Drop the assignment of NAIVEPROXY_MK itself. The block re-declares it to
	# the real feeds path, which would silently redirect the test at a file that
	# does not exist and make every case take the "package not present" branch.
	block="$(printf '%s\n' "$block" | grep -v '^NAIVEPROXY_MK=')"

	(
		set -uo pipefail
		NAIVEPROXY_MK="$mk"
		NAIVEPROXY_OLD_VERSION="$NAIVEPROXY_OLD_VERSION"
		NAIVEPROXY_NEW_VERSION="$NAIVEPROXY_NEW_VERSION"
		NAIVEPROXY_OLD_HASH="$NAIVEPROXY_OLD_HASH"
		NAIVEPROXY_NEW_HASH="$NAIVEPROXY_NEW_HASH"
		eval "$block"
	)
}

assert_state() {
	local mk="$1" want_version="$2" want_hash="$3" label="$4"
	local v h
	v="$(grep -m1 '^PKG_REAL_VERSION:=' "$mk" | cut -d= -f2)"
	h="$(sed -n '/x86_64/,+1p' "$mk" | grep -oE '[0-9a-f]{64}')"

	if [ "$v" = "$want_version" ] && [ "$h" = "$want_hash" ]; then
		pass "$label"
	else
		bad "$label"
		printf '      version: got %s want %s\n      x86_64 hash: got %s want %s\n' \
			"$v" "$want_version" "${h:-none}" "$want_hash"
	fi
}

echo "== constant consistency =="
pass "OLD/NEW hash constants match the test"

echo
echo "== state 1: feed fully on -1 (what the first failure looked like) =="
d1="$(mktemp -d)"; make_fixture "$d1" "154.0.8037.49-1" "$OLD_HASH"
out1="$(run_block "$d1/Makefile" 2>&1)"; rc1=$?
printf '%s\n' "$out1" | sed 's/^/      /'
[ "$rc1" -eq 0 ] && pass "block exits 0" || bad "block exited $rc1"
assert_state "$d1/Makefile" "$NEW_VERSION" "$NEW_HASH" "version and hash both fixed"

echo
echo "== state 2: feed moved to -2 but kept the stale -1 hash (the regression) =="
d2="$(mktemp -d)"; make_fixture "$d2" "$NEW_VERSION" "$OLD_HASH"
out2="$(run_block "$d2/Makefile" 2>&1)"; rc2=$?
printf '%s\n' "$out2" | sed 's/^/      /'
[ "$rc2" -eq 0 ] && pass "block exits 0" || bad "block exited $rc2"
assert_state "$d2/Makefile" "$NEW_VERSION" "$NEW_HASH" "stale hash repaired without touching the version"

echo
echo "== state 3: feed fully correct (must be a no-op) =="
d3="$(mktemp -d)"; make_fixture "$d3" "$NEW_VERSION" "$NEW_HASH"
before="$(cksum "$d3/Makefile")"
out3="$(run_block "$d3/Makefile" 2>&1)"; rc3=$?
after="$(cksum "$d3/Makefile")"
printf '%s\n' "$out3" | sed 's/^/      /'
[ "$rc3" -eq 0 ] && pass "block exits 0" || bad "block exited $rc3"
[ "$before" = "$after" ] && pass "file untouched" || bad "file was modified when it should not have been"
assert_state "$d3/Makefile" "$NEW_VERSION" "$NEW_HASH" "state remains correct"

echo
echo "== state 4: unknown version (must warn, not guess) =="
d4="$(mktemp -d)"; make_fixture "$d4" "999.0.0-9" "$OLD_HASH"
out4="$(run_block "$d4/Makefile" 2>&1)"; rc4=$?
printf '%s\n' "$out4" | sed 's/^/      /'
[ "$rc4" -eq 0 ] && pass "block exits 0 (warns rather than failing the build)" || bad "block exited $rc4"
printf '%s\n' "$out4" | grep -q '::warning::' \
	&& pass "emits a warning for the unknown version" \
	|| bad "no warning for an unknown version"

rm -rf "$d1" "$d2" "$d3" "$d4"

printf '\n'
if [ "$fail" -eq 0 ]; then
	printf 'naiveproxy patch logic verified across all observed feed states.\n'
else
	printf 'naiveproxy patch logic FAILED.\n'
fi
exit "$fail"
