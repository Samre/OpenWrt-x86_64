#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Runs with the repository's working directory set to the OpenWrt tree
# (the workflow does `cd openwrt` before invoking this script).
# Every edit below is validated: a missing target or a no-op substitution
# must fail the build instead of silently shipping an unpatched firmware.

set -euo pipefail

# Preprocessor marker inserted into the shortcut-fe sources; also used to keep
# the insertion idempotent when the script runs more than once.
SFE_SUPPORT_IPV6_MARK="SFE_SUPPORT_IPV6 1"

# --- Default LAN IP ---------------------------------------------------------
# The firmware ships 192.168.216.10 instead of the upstream 192.168.1.1.
# WARNING: config_generate only creates /etc/config/network when no network
# config exists yet. Always confirm the address on a real image before release.
CONFIG_GENERATE="package/base-files/files/bin/config_generate"
[ -f "$CONFIG_GENERATE" ] \
  || { echo "::error::missing $CONFIG_GENERATE — upstream layout changed"; exit 1; }

if grep -qF '192.168.216.10' "$CONFIG_GENERATE"; then
  echo "  default LAN IP: already 192.168.216.10"
else
  before=$(md5sum "$CONFIG_GENERATE" | cut -d' ' -f1)
  sed -i 's/192\.168\.1\.1/192.168.216.10/g' "$CONFIG_GENERATE"
  after=$(md5sum "$CONFIG_GENERATE" | cut -d' ' -f1)
  if [ "$before" = "$after" ]; then
    echo "::error::default IP substitution did not change ${CONFIG_GENERATE}"
    exit 1
  fi
  grep -qF '192.168.216.10' "$CONFIG_GENERATE" \
    || { echo "::error::default IP substitution not verifiable in ${CONFIG_GENERATE}"; exit 1; }
  echo "  default LAN IP: 192.168.1.1 -> 192.168.216.10"
fi

# --- Clear the published default root password ------------------------------
# Upstream writes a well-known hash into /etc/shadow. If that hash is ever
# rotated upstream our sed stops matching, and the firmware would ship with a
# publicly known root credential. Hard-fail instead of shipping it.
DEFAULT_SETTINGS="package/lean/default-settings/files/zzz-default-settings"
[ -f "$DEFAULT_SETTINGS" ] \
  || { echo "::error::missing $DEFAULT_SETTINGS — upstream layout changed"; exit 1; }

if grep -qF 'V4UetPzk' "$DEFAULT_SETTINGS"; then
  before=$(md5sum "$DEFAULT_SETTINGS" | cut -d' ' -f1)
  sed -i 's/\$1\$V4UetPzk\$CYXluq4wUazHjmCDBCqXF\.//g' "$DEFAULT_SETTINGS"
  after=$(md5sum "$DEFAULT_SETTINGS" | cut -d' ' -f1)
  if [ "$before" = "$after" ]; then
    echo "::error::default password hash still present but the substitution changed nothing in ${DEFAULT_SETTINGS}"
    exit 1
  fi
  if grep -qF 'V4UetPzk' "$DEFAULT_SETTINGS"; then
    echo "::error::default password hash still present in ${DEFAULT_SETTINGS}"
    exit 1
  fi
  echo "  root password hash: cleared (login without password until changed)"
else
  echo "  root password hash: not present, nothing to clear"
fi

# --- shortcut-fe kernel compatibility ---------------------------------------
# The pinned source still uses APIs that Linux 6.18 dropped or renamed:
#   * timer_setup() callbacks use from_timer(), removed in 6.10
#     (timer_container_of() replaced it).
#   * del_timer_sync() was renamed timer_delete_sync().
# Without these rewrites the kmod-shortcut-fe/kmod-shortcut-fe-cm packages in
# .config fail to compile.
SHORTCUT_SRC="${SHORTCUT_SRC:-package/qca/shortcut-fe/shortcut-fe/src}"
if [ ! -d "$SHORTCUT_SRC" ]; then
  echo "::error::${SHORTCUT_SRC} is missing but .config selects kmod-shortcut-fe/kmod-shortcut-fe-cm"
  exit 1
fi

# IPv6 entry points: sfe_cm.h chooses with `#ifdef SFE_SUPPORT_IPV6` between an
# extern declaration and a do-nothing static-inline stub. The package Makefile
# passes EXTRA_CFLAGS+="-DSFE_SUPPORT_IPV6", but the package builds three
# modules (shortcut-fe, shortcut-fe-ipv6, shortcut-fe-cm) from this one source
# tree and the macro does not reach every translation unit. Whichever unit
# reaches sfe_cm.h without it defines stubs whose names collide with the real
# functions in sfe_ipv6.c:
#
#   sfe_ipv6.c:1015: error: redefinition of 'sfe_ipv6_mark_rule'
#   sfe_cm.h:206: note: previous definition of 'sfe_ipv6_destroy_all_rules_for_dev'
#
# Defining the macro once in sfe.h, which every .c file includes before
# sfe_cm.h, makes all units agree. The #ifndef guard keeps it a no-op where the
# command line already provides it.
for src in sfe_ipv4.c sfe_ipv6.c sfe_cm.c; do
  [ -f "$SHORTCUT_SRC/$src" ] || { echo "::error::missing $SHORTCUT_SRC/$src"; exit 1; }
done
grep -q '^#include "sfe\.h"' "$SHORTCUT_SRC/sfe_ipv4.c" \
  || { echo "::error::sfe_ipv4.c no longer includes sfe.h; the SFE_SUPPORT_IPV6 define would not be visible"; exit 1; }
grep -q '^#include "sfe\.h"' "$SHORTCUT_SRC/sfe_ipv6.c" \
  || { echo "::error::sfe_ipv6.c no longer includes sfe.h; the SFE_SUPPORT_IPV6 define would not be visible"; exit 1; }
grep -q '^#include "sfe\.h"' "$SHORTCUT_SRC/sfe_cm.c" \
  || { echo "::error::sfe_cm.c no longer includes sfe.h; the SFE_SUPPORT_IPV6 define would not be visible"; exit 1; }

if ! grep -q "$SFE_SUPPORT_IPV6_MARK" "$SHORTCUT_SRC/sfe.h"; then
  # Anchor on the first code line in sfe.h. Anchoring on the license text is
  # unsafe: "OF THIS SOFTWARE" occurs twice in that comment block and sed
  # inserts before the first match, which would bury the define in a comment.
  grep -q '^#define DEBUG_LEVEL' "$SHORTCUT_SRC/sfe.h" \
    || { echo "::error::cannot locate the sfe.h insertion point (no DEBUG_LEVEL define)"; exit 1; }
  sed -i '/^#define DEBUG_LEVEL/i #ifndef SFE_SUPPORT_IPV6\n#define SFE_SUPPORT_IPV6 1\n#endif' "$SHORTCUT_SRC/sfe.h"
  echo "  sfe.h: SFE_SUPPORT_IPV6 defined for every translation unit"
fi
grep -q "$SFE_SUPPORT_IPV6_MARK" "$SHORTCUT_SRC/sfe.h" \
  || { echo "::error::SFE_SUPPORT_IPV6 missing from sfe.h"; exit 1; }
# Exactly one copy, and after the license block so it cannot land inside a
# comment (both would break or silently disable the define).
n=$(grep -c "$SFE_SUPPORT_IPV6_MARK" "$SHORTCUT_SRC/sfe.h")
[ "$n" -eq 1 ] || { echo "::error::SFE_SUPPORT_IPV6 appears ${n} times in sfe.h"; exit 1; }
define_line=$(grep -n "$SFE_SUPPORT_IPV6_MARK" "$SHORTCUT_SRC/sfe.h" | cut -d: -f1)
license_end=$(grep -n '^[[:space:]]*\*/' "$SHORTCUT_SRC/sfe.h" | head -n1 | cut -d: -f1)
[ -n "$license_end" ] \
  || { echo "::error::could not locate the end of the sfe.h license block"; exit 1; }
[ "$define_line" -gt "$license_end" ] \
  || { echo "::error::SFE_SUPPORT_IPV6 landed inside the sfe.h license comment"; exit 1; }

# from_timer(si, tl, timer) -> container_of(tl, struct sfe_ipvN, timer)
# del_timer_sync(&si->timer) -> timer_delete_sync(&si->timer)
# Only rewrite what is still old, so re-running the script is harmless.
for entry in sfe_ipv4.c:sfe_ipv4 sfe_ipv6.c:sfe_ipv6; do
  file="${entry%%:*}"
  struct_name="${entry##*:}"
  path="$SHORTCUT_SRC/$file"

  if grep -qE '\bfrom_timer[[:space:]]*\(' "$path"; then
    sed -i "s/from_timer(si, tl, timer)/container_of(tl, struct ${struct_name}, timer)/g" "$path"
    echo "  ${file}: from_timer() -> container_of()"
  fi
  if grep -qE '\bdel_timer_sync[[:space:]]*\(' "$path"; then
    sed -i 's/del_timer_sync(\&si->timer)/timer_delete_sync(\&si->timer)/g' "$path"
    echo "  ${file}: del_timer_sync() -> timer_delete_sync()"
  fi

  if grep -qE '\bfrom_timer[[:space:]]*\(' "$path"; then
    echo "::error::from_timer() still present in ${path} — source pattern changed, update the sed pattern"
    exit 1
  fi
  if grep -qE '\bdel_timer_sync[[:space:]]*\(' "$path"; then
    echo "::error::del_timer_sync() still present in ${path} — source pattern changed, update the sed pattern"
    exit 1
  fi
done

grep -qE '\bcontainer_of\(tl, struct sfe_ipv4, timer\)' "$SHORTCUT_SRC/sfe_ipv4.c" \
  || { echo "::error::container_of replacement missing from sfe_ipv4.c"; exit 1; }
grep -qE '\bcontainer_of\(tl, struct sfe_ipv6, timer\)' "$SHORTCUT_SRC/sfe_ipv6.c" \
  || { echo "::error::container_of replacement missing from sfe_ipv6.c"; exit 1; }
grep -qE '\btimer_delete_sync[[:space:]]*\(' "$SHORTCUT_SRC/sfe_ipv4.c" \
  || { echo "::error::timer_delete_sync replacement missing from sfe_ipv4.c"; exit 1; }
grep -qE '\btimer_delete_sync[[:space:]]*\(' "$SHORTCUT_SRC/sfe_ipv6.c" \
  || { echo "::error::timer_delete_sync replacement missing from sfe_ipv6.c"; exit 1; }

# sfe_cm.c reads the "no window check" conntrack setting. Linux 6.18 removed it
# from struct nf_tcp_net entirely, while the source still guards the read with
# `>= 5.15` and so takes that branch:
#     sfe_cm.c:514: error: 'struct nf_tcp_net' has no member named 'tcp_no_window_check'
# Drop the removed member and leave the equivalent tcp_be_liberal test, which
# still determines SFE_CREATE_FLAG_NO_SEQ_CHECK on every supported kernel.
SFE_CM="$SHORTCUT_SRC/sfe_cm.c"
if grep -qF 'tcp_no_window_check' "$SFE_CM"; then
  before=$(md5sum "$SFE_CM" | cut -d' ' -f1)
  sed -i \
    -e '/^[[:space:]]*struct net \*net=NULL;$/d' \
    -e '/^[[:space:]]*struct nf_tcp_net \*tn=NULL;$/d' \
    -e '\|^#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 15, 0)$|,\|^#endif$|c\
if ((ct->proto.tcp.seen[0].flags \& IP_CT_TCP_FLAG_BE_LIBERAL)' \
    "$SFE_CM"
  after=$(md5sum "$SFE_CM" | cut -d' ' -f1)
  [ "$before" != "$after" ] \
    || { echo "::error::6.18 nf_tcp_net patch changed nothing in ${SFE_CM}"; exit 1; }
  echo "  sfe_cm.c: dropped the nf_tcp_net->tcp_no_window_check read (removed in 6.18)"
fi

# Assert the result compiles on the 6.18 header: no reference to the removed
# member may survive in either branch, and the remaining condition must still
# decide SFE_CREATE_FLAG_NO_SEQ_CHECK.
if grep -qF 'tcp_no_window_check' "$SFE_CM"; then
  echo "::error::${SFE_CM} still references tcp_no_window_check, which Linux 6.18 does not provide"
  exit 1
fi
grep -qF 'if ((ct->proto.tcp.seen[0].flags & IP_CT_TCP_FLAG_BE_LIBERAL)' "$SFE_CM" \
  || { echo "::error::liberal-flag condition missing from ${SFE_CM}"; exit 1; }

# --- PicoClaw (AI agent) ----------------------------------------------------
# The package itself lives in package/picoclaw/ in this repository and is moved
# into the tree by the workflow's "Load custom configuration" step. Everything
# below is a precondition or a post-condition check, because the two previous
# AI integration attempts in this repository failed silently:
#
#   * a third-party Makefile injected version ldflags into a source path that
#     upstream had moved, which the Go linker ignores without any error;
#   * the same Makefile sed-patched a helper function that no longer existed,
#     so the binary would have ignored PICOCLAW_HOME.
#
# Neither produced a build failure. They produced a broken firmware.

PICOCLAW_PKG="package/picoclaw"
PICOCLAW_MAKEFILE="$PICOCLAW_PKG/Makefile"
PICOCLAW_INIT="$PICOCLAW_PKG/files/picoclaw.init"
PICOCLAW_UCI_DEFAULT="$PICOCLAW_PKG/files/picoclaw.uci-default"
PICOCLAW_CONF="$PICOCLAW_PKG/files/picoclaw.conf"
PICOCLAW_REF_JSON="$PICOCLAW_PKG/files/picoclaw-config.json"

for f in "$PICOCLAW_MAKEFILE" "$PICOCLAW_INIT" "$PICOCLAW_UCI_DEFAULT" "$PICOCLAW_CONF" "$PICOCLAW_REF_JSON"; do
  [ -f "$f" ] || { echo "::error::$f is missing; the AI agent package would not be built"; exit 1; }
done

# 1. The pinned upstream commit must be an explicit SHA, never a branch. A
#    floating revision is what let the third-party patches rot unnoticed.
PICOCLAW_SHA=$(grep -E '^PKG_SOURCE_VERSION:=' "$PICOCLAW_MAKEFILE" | cut -d= -f2)
if ! printf '%s' "$PICOCLAW_SHA" | grep -qE '^[0-9a-f]{40}$'; then
  echo "::error::PKG_SOURCE_VERSION in $PICOCLAW_MAKEFILE is '${PICOCLAW_SHA}', expected a 40-char commit SHA"
  exit 1
fi
echo "  picoclaw: pinned to ${PICOCLAW_SHA}"

# 2. The version ldflags must target the package that actually declares the
#    variables. Upstream moved them from cmd/picoclaw/internal to pkg/config;
#    -X on an unknown symbol is silently ignored by the linker, so a wrong path
#    here ships a binary reporting a permanently wrong version.
if grep -qE "\-X '.*/internal\.(version|Version)" "$PICOCLAW_MAKEFILE"; then
  echo "::error::$PICOCLAW_MAKEFILE injects version ldflags into .../internal.*, which no longer declares them"
  exit 1
fi
grep -q "github.com/sipeed/picoclaw/pkg/config.Version" "$PICOCLAW_MAKEFILE" \
  || { echo "::error::$PICOCLAW_MAKEFILE does not inject pkg/config.Version"; exit 1; }
echo "  picoclaw: version ldflags target pkg/config"

# 3. goolm must be in the build tags. OpenWrt compiles Go packages with
#    CGO_ENABLED=0, and goolm is the pure-Go driver for modernc.org/sqlite;
#    without it the session/memory store has no database backend.
grep -qE '^GO_PKG_TAGS:=.*\bgoolm\b' "$PICOCLAW_MAKEFILE" \
  || { echo "::error::$PICOCLAW_MAKEFILE must build with the goolm tag (pure-Go sqlite)"; exit 1; }
grep -qE '^GO_PKG_TAGS:=.*\bstdjson\b' "$PICOCLAW_MAKEFILE" \
  || { echo "::error::$PICOCLAW_MAKEFILE must build with the stdjson tag"; exit 1; }
echo "  picoclaw: build tags include goolm,stdjson"

# 4. The Go toolchain in the feed must satisfy the module's `go` directive.
#    This is the check that makes the "requires Go 1.25, SDK ships 1.23" trap
#    fail loudly instead of as an obscure compile error deep in the log.
GO_MAKEFILE="feeds/packages/lang/golang/golang/Makefile"
if [ -f "$GO_MAKEFILE" ]; then
  GO_VER=$(grep -E '^GO_VERSION_MAJOR_MINOR:=' "$GO_MAKEFILE" | head -n1 | cut -d= -f2 | tr -d '[:space:]')
  [ -n "$GO_VER" ] || { echo "::error::cannot read GO_VERSION_MAJOR_MINOR from $GO_MAKEFILE"; exit 1; }
  echo "  go toolchain in feed: $GO_VER"
  # The module declares `go 1.25.13`; require >= 1.25 from the feed toolchain.
  if [ "$(printf '%s\n%s\n' "1.25" "$GO_VER" | sort -V | head -n1)" != "1.25" ]; then
    echo "::error::feed Go toolchain is $GO_VER but picoclaw needs >= 1.25"
    echo "::error::lede's packages feed normally ships a newer Go; if not, replace feeds/packages/lang/golang"
    exit 1
  fi
  echo "  picoclaw: Go toolchain $GO_VER satisfies the module requirement (>= 1.25)"
else
  echo "::warning::$GO_MAKEFILE not found; skipped the Go version precondition"
fi

# 5. Select the package. This has to happen here rather than in the committed
#    .config: the workflow reconciles .config against make defconfig and fails
#    the build for any symbol whose package is not in an installed feed, and
#    package/picoclaw is only moved into the tree in this same step.
if ! grep -qE '^CONFIG_PACKAGE_picoclaw=y$' .config; then
  printf '\n# AI agent added by %s\nCONFIG_PACKAGE_picoclaw=y\n' "$(basename "$0")" >>.config
  echo "  .config: CONFIG_PACKAGE_picoclaw=y added"
fi
grep -qE '^CONFIG_PACKAGE_picoclaw=y$' .config \
  || { echo "::error::failed to enable CONFIG_PACKAGE_picoclaw in .config"; exit 1; }

# 6. The reference JSON must parse. It ships in the image, and a malformed one
#    would only be noticed by an operator on a flashed device.
#    `command -v` alone is not a sufficient probe: on some systems python3
#    resolves to a stub that exits without running.
json_checked=0
if command -v jq >/dev/null 2>&1 && jq -e . "$PICOCLAW_REF_JSON" >/dev/null 2>&1; then
  json_checked=1
elif command -v python3 >/dev/null 2>&1 &&
  python3 -c 'import json' >/dev/null 2>&1 &&
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PICOCLAW_REF_JSON" >/dev/null 2>&1; then
  json_checked=1
elif command -v jq >/dev/null 2>&1 || (command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1); then
  echo "::error::$PICOCLAW_REF_JSON is not valid JSON"
  exit 1
else
  echo "::warning::neither jq nor a working python3 available; skipped the JSON validation"
fi
[ "$json_checked" -eq 1 ] && echo "  picoclaw: reference config JSON is valid"

# 7. Security posture. The firmware must ship with the gateway on loopback and
#    the file tools confined to the workspace. These are asserted rather than
#    trusted, because the third-party package shipped the opposite defaults.
grep -qE "^[[:space:]]*option host '127\.0\.0\.1'" "$PICOCLAW_CONF" \
  || { echo "::error::$PICOCLAW_CONF must default the gateway host to 127.0.0.1"; exit 1; }
grep -qE "^[[:space:]]*option restrict_to_workspace '1'" "$PICOCLAW_CONF" \
  || { echo "::error::$PICOCLAW_CONF must default restrict_to_workspace to 1"; exit 1; }
if grep -qE "^[[:space:]]*option host '0\.0\.0\.0'" "$PICOCLAW_CONF"; then
  echo "::error::$PICOCLAW_CONF exposes the gateway on 0.0.0.0"
  exit 1
fi
echo "  picoclaw: gateway bound to loopback, workspace restricted"

# 8. The init script must not export secrets into the process environment,
#    which is readable via /proc/<pid>/environ on an unpatched kernel.
if grep -qE '^[[:space:]]*export .*(API_KEY|TOKEN|SECRET)' "$PICOCLAW_INIT"; then
  echo "::error::$PICOCLAW_INIT exports a credential; it must stay in /etc/picoclaw/config.json"
  exit 1
fi
grep -q 'PICOCLAW_HOME' "$PICOCLAW_INIT" \
  || { echo "::error::$PICOCLAW_INIT does not set PICOCLAW_HOME, so the config path would not resolve"; exit 1; }
echo "  picoclaw: init script sets PICOCLAW_HOME and exports no credentials"

# --- PicoClaw approval gate -------------------------------------------------
# The gate is what stops the agent from running arbitrary commands as root
# without review. If any piece below is missing, the firmware would still build
# and boot - with the agent silently ungated. That is precisely the kind of
# silent degradation the rest of this script exists to prevent.

APPROVAL_DIR="$PICOCLAW_PKG/files/approval"
GATE_UC="$APPROVAL_DIR/gate.uc"
POLICY_UC="$APPROVAL_DIR/policy.uc"
EXECUTOR_UC="$APPROVAL_DIR/executor.uc"

for f in "$GATE_UC" "$POLICY_UC" "$EXECUTOR_UC"; do
  [ -f "$f" ] || { echo "::error::$f is missing; the agent would run commands without approval"; exit 1; }
done

# The gate must be registered at first boot, or it never runs at all.
grep -q 'hooks.processes' "$PICOCLAW_UCI_DEFAULT" \
  || { echo "::error::$PICOCLAW_UCI_DEFAULT does not register the approval hook in config.json"; exit 1; }
grep -q 'picoclaw_approval' "$PICOCLAW_UCI_DEFAULT" \
  || { echo "::error::$PICOCLAW_UCI_DEFAULT does not name the approval hook process"; exit 1; }
grep -q 'intercept' "$PICOCLAW_UCI_DEFAULT" \
  || { echo "::error::$PICOCLAW_UCI_DEFAULT registers the hook without intercept stages"; exit 1; }

# gate.uc imports policy.uc by relative path, which only resolves because the
# hook config sets Dir to the approval directory. Both halves must agree.
grep -qE "import \* as policy from '\./policy\.uc'" "$GATE_UC" \
  || { echo "::error::$GATE_UC does not import ./policy.uc as expected"; exit 1; }
grep -q 'dir: "/usr/share/picoclaw/approval"' "$PICOCLAW_UCI_DEFAULT" \
  || { echo "::error::the hook Dir is not /usr/share/picoclaw/approval, so the policy import would fail"; exit 1; }

# The gate must start the executor, or approvals would sit in "approved" forever.
grep -q 'executor.uc' "$GATE_UC" \
  || { echo "::error::$GATE_UC never starts the executor; approved commands would never run"; exit 1; }

# All three scripts must be installed.
for f in gate.uc policy.uc executor.uc; do
  grep -q "files/approval/$f" "$PICOCLAW_MAKEFILE" \
    || { echo "::error::$PICOCLAW_MAKEFILE does not install $f"; exit 1; }
done
echo "  picoclaw: approval gate present, registered with a matching Dir, and installed"

# --- LuCI approval interface ------------------------------------------------
# The gate blocks the agent by design; without a UI the operator would have no
# way to approve anything, so the agent would be permanently unable to act.

LUCI_PICOCLAW_PKG="package/luci-app-picoclaw"
LUCI_PICOCLAW_MAKEFILE="$LUCI_PICOCLAW_PKG/Makefile"
LUCI_PICOCLAW_ACL="$LUCI_PICOCLAW_PKG/root/usr/share/rpcd/acl.d/luci-app-picoclaw.json"
LUCI_PICOCLAW_RPC="$LUCI_PICOCLAW_PKG/root/usr/share/rpcd/ucode/picoclaw.uc"
LUCI_PICOCLAW_MENU="$LUCI_PICOCLAW_PKG/root/usr/share/luci/menu.d/luci-app-picoclaw.json"
LUCI_PICOCLAW_VIEW="$LUCI_PICOCLAW_PKG/htdocs/luci-static/resources/view/picoclaw/approvals.js"

for f in "$LUCI_PICOCLAW_MAKEFILE" "$LUCI_PICOCLAW_ACL" "$LUCI_PICOCLAW_RPC" "$LUCI_PICOCLAW_MENU" "$LUCI_PICOCLAW_VIEW"; do
  [ -f "$f" ] || { echo "::error::$f is missing; the approval queue would have no user interface"; exit 1; }
done

grep -qE '^LUCI_DEPENDS:=.*\+picoclaw' "$LUCI_PICOCLAW_MAKEFILE" \
  || { echo "::error::$LUCI_PICOCLAW_MAKEFILE does not depend on picoclaw"; exit 1; }

# ACL scope. The third-party app this replaces grants uci "*" plus exec on
# /bin/ash, which is equivalent to handing the web interface a root shell.
# Assert this app does not, because a later edit could reintroduce it.
if grep -qE '"\*"' "$LUCI_PICOCLAW_ACL"; then
  echo "::error::$LUCI_PICOCLAW_ACL grants a wildcard scope; it must request only what it needs"
  exit 1
fi
if grep -qE '/bin/(ash|sh)' "$LUCI_PICOCLAW_ACL"; then
  echo "::error::$LUCI_PICOCLAW_ACL grants shell execution, which is equivalent to root"
  exit 1
fi
grep -qE '"uci": \[ "picoclaw" \]' "$LUCI_PICOCLAW_ACL" \
  || { echo "::error::$LUCI_PICOCLAW_ACL does not scope UCI access to the picoclaw section"; exit 1; }
echo "  luci-app-picoclaw: ACL scoped to the picoclaw section, no wildcard, no shell exec"

# Select the app. As with picoclaw itself this has to happen after package/ has
# been staged into the tree, or `make defconfig` would drop the symbol.
if ! grep -qE '^CONFIG_PACKAGE_luci-app-picoclaw=y$' .config; then
  printf 'CONFIG_PACKAGE_luci-app-picoclaw=y\n' >>.config
  echo "  .config: CONFIG_PACKAGE_luci-app-picoclaw=y added"
fi
grep -qE '^CONFIG_PACKAGE_luci-app-picoclaw=y$' .config \
  || { echo "::error::failed to enable CONFIG_PACKAGE_luci-app-picoclaw in .config"; exit 1; }

# 11. No credential may be baked into the image. Catch a key committed into the
#     shipped reference config before it is published in a release tarball.
if grep -qE '"(api_key|token|app_secret|client_secret|encrypt_key)"[[:space:]]*:[[:space:]]*"[^"]+"' "$PICOCLAW_REF_JSON"; then
  echo "::error::$PICOCLAW_REF_JSON contains a non-empty credential; it would ship inside the firmware"
  exit 1
fi
echo "  picoclaw: no credentials present in the shipped reference config"

# --- naiveproxy: pinned release was deleted upstream -------------------------
# feeds/small pins PKG_REAL_VERSION:=154.0.8037.49-1. Upstream published
# 154.0.8037.49-2 on 2026-09-25 and removed the -1 release in the same
# operation, so the pinned archive is a 404:
#
#   ERROR: package/feeds/small/naiveproxy failed to build.
#   curl: (22) The requested URL returned error: 404
#   .../download/v154.0.8037.49-1/naiveproxy-v154.0.8037.49-1-openwrt-x86_64.tar.xz
#
# This is unrelated to any change in this repository, but it aborts `make
# world` before later packages are reached, so it has to be worked around to
# get a build at all. Only the x86_64 hash is touched: that is the only
# architecture this repository builds, and the other 20 branches in the
# Makefile are left exactly as the feed ships them.
#
# Remove this block once kenzok8/small moves to -2 on its own.
NAIVEPROXY_MK="feeds/small/naiveproxy/Makefile"
NAIVEPROXY_OLD_VERSION="154.0.8037.49-1"
NAIVEPROXY_NEW_VERSION="154.0.8037.49-2"
NAIVEPROXY_OLD_HASH="55a10e6ca08696f9b606e1b3cb1a65aba72253756c5e1769d78edd78d4a1c6ab"
NAIVEPROXY_NEW_HASH="25ac92b86474fc62ed0e5008d7009f935115b9ae8a072f1fbafc92790ea283ce"

if [ -f "$NAIVEPROXY_MK" ]; then
  if grep -qF "$NAIVEPROXY_NEW_VERSION" "$NAIVEPROXY_MK"; then
    echo "  naiveproxy: already on ${NAIVEPROXY_NEW_VERSION} (feed was updated upstream); no patch needed"
  elif grep -qF "PKG_REAL_VERSION:=${NAIVEPROXY_OLD_VERSION}" "$NAIVEPROXY_MK"; then
    # The substitutions below are unconditional sed replacements, so assert
    # first that each target occurs exactly once. If upstream ever reuses the
    # same hash for a second architecture, a global replace would silently
    # rewrite that branch too and produce a checksum failure at download time
    # on a package unrelated to naiveproxy.
    old_hash_count=$(grep -cF "$NAIVEPROXY_OLD_HASH" "$NAIVEPROXY_MK")
    [ "$old_hash_count" -eq 1 ] \
      || { echo "::error::expected exactly one x86_64 naiveproxy hash ${NAIVEPROXY_OLD_HASH}, found ${old_hash_count}; refusing a global replace"; exit 1; }
    old_version_count=$(grep -cF "PKG_REAL_VERSION:=${NAIVEPROXY_OLD_VERSION}" "$NAIVEPROXY_MK")
    [ "$old_version_count" -eq 1 ] \
      || { echo "::error::expected exactly one PKG_REAL_VERSION line, found ${old_version_count}"; exit 1; }

    # Retarget the release and the matching x86_64 archive hash together; the
    # two must move as a pair or PKG_HASH verification fails on download.
    sed -i \
      -e "s/^PKG_REAL_VERSION:=${NAIVEPROXY_OLD_VERSION}\$/PKG_REAL_VERSION:=${NAIVEPROXY_NEW_VERSION}/" \
      -e "s/${NAIVEPROXY_OLD_HASH}/${NAIVEPROXY_NEW_HASH}/" \
      "$NAIVEPROXY_MK"

    grep -qF "PKG_REAL_VERSION:=${NAIVEPROXY_NEW_VERSION}" "$NAIVEPROXY_MK" \
      || { echo "::error::naiveproxy version substitution did not apply to ${NAIVEPROXY_MK}"; exit 1; }
    if grep -qF "$NAIVEPROXY_OLD_HASH" "$NAIVEPROXY_MK"; then
      echo "::error::naiveproxy still carries the deleted archive hash ${NAIVEPROXY_OLD_HASH}"
      exit 1
    fi
    new_hash_count=$(grep -cF "$NAIVEPROXY_NEW_HASH" "$NAIVEPROXY_MK")
    [ "$new_hash_count" -eq 1 ] \
      || { echo "::error::expected exactly one updated naiveproxy hash, found ${new_hash_count}"; exit 1; }
    # Guard against a future feed layout change moving the hash to another
    # architecture branch while leaving this check silently satisfied.
    sed -n '/x86_64/,+1p' "$NAIVEPROXY_MK" | grep -qF "$NAIVEPROXY_NEW_HASH" \
      || { echo "::error::the updated hash is not inside the x86_64 branch of ${NAIVEPROXY_MK}"; exit 1; }
    echo "  naiveproxy: ${NAIVEPROXY_OLD_VERSION} -> ${NAIVEPROXY_NEW_VERSION} (release deleted upstream, 404)"
  else
    echo "::warning::naiveproxy is pinned to neither ${NAIVEPROXY_OLD_VERSION} nor ${NAIVEPROXY_NEW_VERSION}; the feed changed shape, re-check this block"
  fi
else
  echo "  naiveproxy: feed package not present, skipping"
fi

echo "All DIY part 2 edits verified."
