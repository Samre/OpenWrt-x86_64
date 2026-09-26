#!/bin/bash
#
# Drift check between the real ucode policy and the Node harness that tests it.
#
# tools/test-approval-policy.mjs is a hand transcription of
# package/picoclaw/files/approval/policy.uc, because ucode is not available
# off-device. The tests are only meaningful while the two agree, so this script
# compares the parts that encode policy decisions: the command allowlist, the
# subcommand keys, the ip vocabulary, the shell metacharacter class and the
# argument pattern.
#
# It is a structural comparison, not an evaluator: it cannot prove the two files
# behave identically, only that nobody changed a decision in one place only.
#
# Deliberately uses POSIX tools only. An earlier revision shelled out to `node`
# for extraction; on a Windows host `node` on PATH is a shim script that bash
# cannot execute, so every comparison silently returned empty and the check
# reported a failure that looked like drift. Extraction must not depend on a
# runtime that the shell may not be able to launch.
#
# Usage: bash tools/check-approval-policy-drift.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UC="$ROOT/package/picoclaw/files/approval/policy.uc"
MJS="$ROOT/tools/test-approval-policy.mjs"

fail=0
pass() { printf '  PASS %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }

for f in "$UC" "$MJS"; do
	[ -f "$f" ] || { echo "missing $f"; exit 1; }
done

# Quoted members of a top-level array constant, sorted, space separated.
array_members() {
	sed -n "/^const $2 = \[/,/^\];/p" "$1" \
		| grep -oE "'[^']+'" \
		| tr -d "'" \
		| sort \
		| tr '\n' ' ' \
		| sed 's/ *$//'
}

# Keys of a nested object constant, selected by indentation depth.
#
# Depth is counted in leading tabs, not characters, and the two levels in these
# files are distinct: ALLOWLIST command names sit at one tab, subcommand names
# at three. An earlier revision used two tabs for subcommands and therefore
# matched nothing, which the caller now treats as a failure rather than a pass.
object_keys() {
	local file="$1" name="$2" depth="$3"
	local tabs
	tabs="$(printf '\t%.0s' $(seq 1 "$depth"))"

	sed -n "/^const $name = {/,/^};/p" "$file" \
		| grep -oE "^${tabs}'[^']+':" \
		| tr -d "'	:" \
		| sort -u \
		| tr '\n' ' ' \
		| sed 's/ *$//'
}

# The members of a regex character class, as a sorted character set. Escapes and
# the surrounding delimiters are removed first: the .uc writes \/ and \[ where
# the .mjs writes / and [, and that difference is not behavioural.
char_class_members() {
	grep -F "const $2" "$1" \
		| sed -e 's/^[^/]*\///' -e 's/\/[^/]*$//' \
		| tr -d '\\' \
		| tr -d '[]' \
		| tr -d '\n' \
		| grep -o . \
		| sort \
		| tr -d '\n'
}

# Keys of the nested subcommand maps: a quoted key indented by three tabs, which
# is the depth both files use for this level.
subcommand_keys() {
	object_keys "$1" ALLOWLIST 3
}

compare() {
	local desc="$1" u="$2" m="$3"
	if [ -z "$u" ] || [ -z "$m" ]; then
		# An empty extraction is never a pass: it would make the check vacuous.
		bad "$desc could not be extracted from one of the files"
		printf '      uc : [%s]\n      mjs: [%s]\n' "$u" "$m"
		return
	fi
	if [ "$u" = "$m" ]; then
		pass "$desc"
	else
		bad "$desc differs"
		printf '      uc : %s\n      mjs: %s\n' "$u" "$m"
	fi
}

echo "== policy constants =="
compare "command allowlist keys" "$(object_keys "$UC" ALLOWLIST 1)" "$(object_keys "$MJS" ALLOWLIST 1)"
compare "ip read verbs"          "$(array_members "$UC" IP_VERBS)"  "$(array_members "$MJS" IP_VERBS)"
compare "ip objects"             "$(array_members "$UC" IP_OBJECTS)" "$(array_members "$MJS" IP_OBJECTS)"
compare "ip safe words"          "$(array_members "$UC" IP_SAFE_WORDS)" "$(array_members "$MJS" IP_SAFE_WORDS)"
compare "shell metacharacter class" "$(char_class_members "$UC" SHELL_META)" "$(char_class_members "$MJS" SHELL_META)"
compare "argument character class"  "$(char_class_members "$UC" SAFE_ARG)"   "$(char_class_members "$MJS" SAFE_ARG)"

echo
echo "== subcommand keys =="
compare "subcommand keys" "$(subcommand_keys "$UC")" "$(subcommand_keys "$MJS")"

printf '\n'
if [ "$fail" -eq 0 ]; then
	printf 'policy.uc and the test harness agree structurally.\n'
else
	printf 'DRIFT DETECTED: update both files together.\n'
fi
exit "$fail"
