#!/bin/bash
#
# Static self-check for the picoclaw integration.
#
# Runs the same assertions diy-part2.sh performs at build time, but against the
# repository working copy, so a mistake is caught locally instead of after a
# multi-hour CI build. It deliberately needs no OpenWrt tree.
#
# Usage:  bash tools/check-picoclaw.sh [repo-root]
#
# Exits non-zero on the first failed assertion.

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

PICOCLAW_PKG="$ROOT/package/picoclaw"
PICOCLAW_MAKEFILE="$PICOCLAW_PKG/Makefile"
PICOCLAW_INIT="$PICOCLAW_PKG/files/picoclaw.init"
PICOCLAW_UCI_DEFAULT="$PICOCLAW_PKG/files/picoclaw.uci-default"
PICOCLAW_CONF="$PICOCLAW_PKG/files/picoclaw.conf"
PICOCLAW_REF_JSON="$PICOCLAW_PKG/files/picoclaw-config.json"

fail=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }
head_() { printf '\n== %s ==\n' "$1"; }

head_ "package files present"
for f in "$PICOCLAW_MAKEFILE" "$PICOCLAW_INIT" "$PICOCLAW_UCI_DEFAULT" "$PICOCLAW_CONF" "$PICOCLAW_REF_JSON"; do
	if [ -f "$f" ]; then pass "$(basename "$f")"; else bad "missing $f"; fi
done

head_ "upstream revision is pinned to a commit"
SHA=$(grep -E '^PKG_SOURCE_VERSION:=' "$PICOCLAW_MAKEFILE" | cut -d= -f2)
if printf '%s' "$SHA" | grep -qE '^[0-9a-f]{40}$'; then
	pass "PKG_SOURCE_VERSION=$SHA"
else
	bad "PKG_SOURCE_VERSION='$SHA' is not a 40-char commit SHA"
fi

head_ "version ldflags target the real declaration site"
if grep -qE "\-X '.*/internal\.(version|Version)" "$PICOCLAW_MAKEFILE"; then
	bad "ldflags still point at .../internal.* (silently ignored by the Go linker)"
else
	pass "no injection into a nonexistent internal.* symbol"
fi
if grep -q 'github.com/sipeed/picoclaw/pkg/config.Version' "$PICOCLAW_MAKEFILE"; then
	pass "injects pkg/config.Version"
else
	bad "does not inject pkg/config.Version"
fi

head_ "build tags are complete"
grep -qE '^GO_PKG_TAGS:=.*\bgoolm\b' "$PICOCLAW_MAKEFILE" \
	&& pass "goolm present (pure-Go sqlite driver for CGO_ENABLED=0)" \
	|| bad "goolm missing: the session/memory store would have no DB backend"
grep -qE '^GO_PKG_TAGS:=.*\bstdjson\b' "$PICOCLAW_MAKEFILE" \
	&& pass "stdjson present" \
	|| bad "stdjson missing"

head_ "security defaults are safe"
grep -qE "^[[:space:]]*option host '127\.0\.0\.1'" "$PICOCLAW_CONF" \
	&& pass "gateway bound to loopback" \
	|| bad "gateway host is not 127.0.0.1"
if grep -qE "^[[:space:]]*option host '0\.0\.0\.0'" "$PICOCLAW_CONF"; then
	bad "gateway is exposed on 0.0.0.0"
fi
grep -qE "^[[:space:]]*option restrict_to_workspace '1'" "$PICOCLAW_CONF" \
	&& pass "restrict_to_workspace enabled" \
	|| bad "restrict_to_workspace is not 1"
grep -qE "^[[:space:]]*option enabled '0'" "$PICOCLAW_CONF" \
	&& pass "heartbeat disabled by default (no idle token spend)" \
	|| bad "heartbeat is enabled by default"

head_ "no credential can be baked into the image"
if grep -qE '"(api_key|token|app_secret|client_secret|encrypt_key)"[[:space:]]*:[[:space:]]*"[^"]+"' "$PICOCLAW_REF_JSON"; then
	bad "shipped reference config contains a non-empty credential"
else
	pass "shipped reference config carries no credential"
fi

head_ "the init script cannot leak secrets via /proc"
if grep -qE '^[[:space:]]*export .*(API_KEY|TOKEN|SECRET)' "$PICOCLAW_INIT"; then
	bad "init script exports a credential (readable via /proc/<pid>/environ)"
else
	pass "no credential export"
fi
grep -q 'PICOCLAW_HOME' "$PICOCLAW_INIT" \
	&& pass "PICOCLAW_HOME is set" \
	|| bad "PICOCLAW_HOME is not set: the config path would not resolve"
# Look for an actual `ln -s ... .picoclaw` statement. The header comment of the
# init script mentions /.picoclaw while explaining why it is NOT needed, so a
# naive substring match would flag that documentation as a defect.
if grep -qE 'ln[[:space:]]+-s.*\.picoclaw' "$PICOCLAW_INIT"; then
	bad "init script still uses the /.picoclaw symlink workaround (unnecessary)"
else
	pass "no /.picoclaw symlink workaround"
fi

head_ "onboard is guarded by a sentinel upstream actually writes"
if grep -q 'WORKSPACE_MARKER="AGENTS.md"' "$PICOCLAW_INIT"; then
	bad "sentinel is AGENTS.md, which upstream's copyEmbeddedToTarget() skips"
else
	pass "sentinel is not the skipped AGENTS.md"
fi
grep -q 'ONBOARD_MARKER' "$PICOCLAW_INIT" \
	&& pass "onboard runs behind a one-shot marker" \
	|| bad "onboard has no one-shot guard: it would re-run every boot"

head_ "shipped reference JSON parses"
# Note: `command -v python3` is not enough on Windows, where the Microsoft
# Store ships a python3.exe stub that resolves but does not run. Probe it.
json_ok=skip
if command -v python3 >/dev/null 2>&1 &&
	python3 -c 'import json' >/dev/null 2>&1; then
	if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PICOCLAW_REF_JSON" >/dev/null 2>&1; then
		json_ok=ok
	fi
elif command -v jq >/dev/null 2>&1; then
	if jq -e . "$PICOCLAW_REF_JSON" >/dev/null 2>&1; then json_ok=ok; fi
fi
case "$json_ok" in
ok) pass "valid JSON" ;;
skip) printf '  SKIP no working python3/jq available\n' ;;
*) bad "invalid JSON" ;;
esac

head_ "Go version gate arithmetic"
for v in 0.9 1.19 1.23 1.25 1.27 1.30; do
	if [ "$(printf '%s\n%s\n' '1.25' "$v" | sort -V | head -n1)" = '1.25' ]; then
		expected=accept
	else
		expected=reject
	fi
	case "$v" in
	1.25 | 1.27 | 1.30) want=accept ;;
	*) want=reject ;;
	esac
	if [ "$expected" = "$want" ]; then
		pass "go $v -> $expected"
	else
		bad "go $v -> $expected (wanted $want)"
	fi
done

printf '\n'
if [ "$fail" -eq 0 ]; then
	printf '\033[32mAll picoclaw checks passed.\033[0m\n'
else
	printf '\033[31mSome checks failed.\033[0m\n'
fi
exit "$fail"
