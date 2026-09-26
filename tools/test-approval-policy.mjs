#!/usr/bin/env node
'use strict';

/*
 * Test harness for the PicoClaw approval policy.
 *
 * ucode is not available off-device, so this file is a faithful transcription
 * of package/picoclaw/files/approval/policy.uc into JavaScript. The two must
 * stay in sync: change the classifier there, change it here, re-run.
 * tools/check-approval-policy.sh compares the two structurally (allowlist keys,
 * subcommand sets, metacharacter class) so drift is reported instead of being
 * silently untested.
 *
 * The tests exist because the first version of this policy allowed
 * `ip link set eth0 down`: the subcommand `link` was allowlisted but the verb
 * that followed it was not checked. Every case below with an unrecognised word
 * is there to keep that class of bug from coming back.
 */

const SHELL_META = /[;&|\n\r$`\\><"'(){}*?[\]~!#]/;
const SAFE_ARG = /^[A-Za-z0-9_./:=,%-]+$/;

const IP_VERBS = ['show', 'list', 'sh', 'ls', 'get', 'stats', 'save'];
const IP_OBJECTS = [
	'addr', 'address', 'a', 'link', 'l', 'route', 'r', 'rule',
	'neigh', 'neighbour', 'n', 'maddr', 'tunnel', 'tuntap', 'stats'
];
const IP_SAFE_WORDS = [
	'show', 'list', 'sh', 'ls', 'get', 'stats', 'save', 'dev', 'to', 'from',
	'table', 'all', 'cached', 'permanent', 'noarp', 'up', 'broadcast',
	'multicast', 'inet', 'inet6', 'link', 'scope', 'global', 'host', 'universe'
];
const IP_DEVICE = /^(lo|eth[0-9]+|br[0-9a-z_.-]*|wlan[0-9a-z_.-]*|pppoe[0-9a-z_.-]*|tun[0-9a-z_.-]*|tap[0-9a-z_.-]*|docker[0-9]*|veth[0-9a-z_.-]*|bond[0-9a-z_.-]*|sit[0-9]+|wg[0-9a-z_.-]*)$/;

const ALLOWLIST = {
	'df':            { args: 'safe' },
	'free':          { args: false },
	'uptime':        { args: false },
	'date':          { args: 'safe' },
	'hostname':      { args: false },
	'uname':         { args: 'safe' },
	'ps':            { args: 'safe' },
	'pwd':           { args: false },
	'id':            { args: false },
	'whoami':        { args: false },
	'cat':           { args: 'safe' },
	'ls':            { args: 'safe' },
	'wc':            { args: 'safe' },
	'which':         { args: 'safe' },
	'logread':       { args: 'safe' },
	'dmesg':         { args: 'safe' },
	'mount':         { args: false },
	'iptables-save': { args: false },
	'true':          { args: false },
	'false':         { args: false },
	'head':          { args: 'safe' },
	'tail':          { args: 'safe' },
	'grep':          { args: 'safe' },
	'ip':            { special: 'ip' },
	'uci': {
		subcommands: {
			'show':    { args: 'safe' },
			'get':     { args: 'safe' },
			'changes': { args: false },
			'export':  { args: 'safe' }
		}
	},
	'ubus': {
		subcommands: { 'list': { args: 'safe' } }
	},
	'nft': {
		subcommands: {
			'list': { words: ['ruleset', 'tables', 'chains', 'rules', 'sets', 'maps', 'counters', 'flowtables', 'meters', 'limits', 'quotas', 'ct', 'help', 'meter', 'synproxy', 'element'] }
		}
	},
	'opkg': {
		subcommands: {
			'list':            { args: false },
			'list-installed':  { args: false },
			'list-upgradable': { args: false },
			'status':          { args: false },
			'info':            { args: 'safe' },
			'find':            { args: 'safe' }
		}
	},
	'apk': {
		subcommands: {
			'list':  { args: 'safe' },
			'info':  { args: 'safe' },
			'stats': { args: false }
		}
	},
	'ping':       { args: 'safe' },
	'ping6':      { args: 'safe' },
	'nslookup':   { args: 'safe' },
	'traceroute': { args: 'safe' },
	'sleep':      { numeric: true }
};

const ALLOWED_LEADING_FLAGS = {
	'ip':   ['-4', '-6', '-o', '-br', '-brief', '-s', '-d', '-a', '-n', '-h', '-json', '-p', '-human', '-iec', '-oneline'],
	'opkg': [],
	'apk':  []
};

function splitWords(cmd) {
	return cmd.trim().split(/[ \t]+/).filter(w => w.length > 0);
}

function normalizeBinary(word) {
	const m = /^(\/bin\/|\/sbin\/|\/usr\/bin\/|\/usr\/sbin\/)([^/]+)$/.exec(word);
	return m != null ? m[2] : null;
}

function argsAreSafe(args) { return args.every(a => SAFE_ARG.test(a)); }
function allWordsIn(args, allowed) { return args.every(a => allowed.indexOf(a) !== -1); }
function isIpDevice(w) { return IP_DEVICE.test(w); }

function classifyIp(rest) {
	const flags = ALLOWED_LEADING_FLAGS['ip'];
	let i = 0;
	while (i < rest.length && flags.indexOf(rest[i]) !== -1) i++;

	const first = rest[i];
	if (first === undefined) return { allow: false, reason: '"ip" requires an object' };

	let object, tail;
	if (IP_OBJECTS.indexOf(first) !== -1) {
		object = first;
		tail = rest.slice(i + 1);
	} else if (IP_VERBS.indexOf(first) !== -1) {
		object = rest[i + 1];
		if (object === undefined) return { allow: false, reason: `"ip ${first}" requires an object` };
		if (IP_OBJECTS.indexOf(object) === -1) return { allow: false, reason: `"ip ${first} ${object}" does not name a known object` };
		tail = rest.slice(i + 2);
	} else {
		return { allow: false, reason: `"ip ${first}" is neither a known object nor a read verb` };
	}

	for (const w of tail) {
		if (IP_SAFE_WORDS.indexOf(w) !== -1) continue;
		if (isIpDevice(w)) continue;
		if (/^[0-9]+$/.test(w)) continue;
		return { allow: false, reason: `"ip ${object}" has an unrecognised word: ${w}` };
	}
	return { allow: true, reason: `read-only ip query (${object})` };
}

function classifySubcommand(binary, rest) {
	const spec = ALLOWLIST[binary];
	const flags = ALLOWED_LEADING_FLAGS[binary] ?? [];
	let i = 0;
	while (i < rest.length && flags.indexOf(rest[i]) !== -1) i++;

	const head = rest[i];
	if (head === undefined) return { allow: false, reason: `"${binary}" requires a read subcommand` };

	let form = spec.subcommands[head];
	if (form === undefined && head.indexOf('-') !== -1) {
		const base = head.slice(0, head.indexOf('-'));
		if (spec.subcommands[head] !== undefined) form = spec.subcommands[head];
		else if (spec.subcommands[base] !== undefined) form = spec.subcommands[base];
	}
	if (form === undefined) return { allow: false, reason: `"${binary} ${head}" is not a read-only subcommand` };

	const tail = rest.slice(i + 1);
	if (form.args === false) {
		return tail.length > 0
			? { allow: false, reason: `"${binary} ${head}" takes no further arguments` }
			: { allow: true, reason: `read-only query (${binary} ${head})` };
	}
	if (form.words !== undefined) {
		return allWordsIn(tail, form.words)
			? { allow: true, reason: `read-only query (${binary} ${head})` }
			: { allow: false, reason: `"${binary} ${head}" has a word outside its read-only vocabulary` };
	}
	return argsAreSafe(tail)
		? { allow: true, reason: `read-only query (${binary} ${head})` }
		: { allow: false, reason: `"${binary} ${head}" has arguments that are not plain tokens` };
}

function classify(command) {
	if (typeof command !== 'string' || command.trim().length === 0)
		return { allow: false, reason: 'empty command' };

	for (const ch of command) {
		const b = ch.codePointAt(0);
		if (b < 32 && b !== 9 && b !== 10 && b !== 13)
			return { allow: false, reason: 'command contains control characters' };
	}
	if (SHELL_META.test(command)) return { allow: false, reason: 'contains shell metacharacters' };

	const words = splitWords(command);
	if (words.length === 0) return { allow: false, reason: 'empty command' };

	const raw = words[0];
	let binary = raw, wasPath = false;
	if (raw.indexOf('/') !== -1) {
		binary = normalizeBinary(raw);
		wasPath = true;
		if (binary == null) return { allow: false, reason: `unrecognised path: ${raw}` };
	}

	const spec = ALLOWLIST[binary];
	if (spec == null) return { allow: false, reason: `"${binary}" is not on the read-only allowlist` };

	const rest = words.slice(1);
	if (spec.special === 'ip') return classifyIp(rest);
	if (spec.subcommands != null) return classifySubcommand(binary, rest);

	if (spec.numeric === true) {
		return (rest.length === 1 && /^[0-9]+(\.[0-9]+)?$/.test(rest[0]))
			? { allow: true, reason: 'bounded delay' }
			: { allow: false, reason: `"${binary}" is only auto-approved with a single numeric argument` };
	}
	if (spec.args === false) {
		return rest.length > 0
			? { allow: false, reason: `"${binary}" is only auto-approved without arguments` }
			: { allow: true, reason: 'read-only command' };
	}
	return argsAreSafe(rest)
		? { allow: true, reason: 'read-only command' }
		: { allow: false, reason: `"${binary}" has arguments that are not plain tokens` };
}

function classifyExecArgs(args) {
	if (typeof args !== 'object' || args == null) return { allow: false, reason: 'no arguments' };
	const action = args.action ?? 'run';
	if (action === 'list') return { allow: true, reason: 'listing exec sessions' };
	if (action === 'run') return classify(args.command);
	if (action === 'poll' || action === 'read' || action === 'kill')
		return { allow: true, reason: `session ${action} on an already-approved command` };
	if (action === 'write' || action === 'send-keys')
		return { allow: false, reason: `"${action}" feeds a live shell session` };
	return { allow: false, reason: `unrecognised exec action: ${action}` };
}

/* ------------------------------------------------------------------ tests */

let pass = 0, fail = 0;
const failures = [];
const allow = (cmd, note) => {
	const r = classify(cmd);
	if (r.allow) pass++;
	else { fail++; failures.push(`EXPECTED ALLOW, got ASK: ${JSON.stringify(cmd)} (${r.reason})${note ? ' [' + note + ']' : ''}`); }
};
const ask = (cmd, note) => {
	const r = classify(cmd);
	if (!r.allow) pass++;
	else { fail++; failures.push(`EXPECTED ASK, got ALLOW: ${JSON.stringify(cmd)}${note ? ' [' + note + ']' : ''}`); }
};

// --- auto-approved: plain read-only diagnostics -----------------------------
allow('df -h');
allow('df');
allow('free');
allow('uptime');
allow('ps w');
allow('cat /proc/loadavg');
allow('ls /etc/config');
allow('logread');
allow('logread -e dnsmasq');
allow('ip addr');
allow('ip addr show eth0');
allow('ip -4 addr show eth0', 'leading flag then verb then object');
allow('ip link show');
allow('ip link show dev eth0');
allow('ip route');
allow('ip route show table all');
allow('/bin/df -h', 'standard path form normalised');
allow('/usr/bin/uptime');
allow('/sbin/ip addr');
allow('uci show');
allow('uci get network.lan.ipaddr');
allow('uci changes');
allow('ubus list');
allow('opkg list-installed');
allow('opkg status');
allow('iptables-save');
allow('dmesg');
allow('nft list ruleset');
allow('ping -c 1 1.1.1.1');
allow('nslookup example.com');
allow('traceroute 1.1.1.1');
allow('which ucode');
allow('sleep 5');
// A long sleep is NOT dangerous on its own (it changes no state, and the exec
// tool applies its own timeout), so the policy allows it. Recorded explicitly
// so the intent is visible rather than looking like a gap.
allow('sleep 99999', 'long sleep is bounded by the exec timeout, not by policy');
allow('head -n 20 /var/log/messages');
allow('tail -n 50 /var/log/picoclaw.log');
allow('wc -l /etc/config/network');

// --- queued: state changes (the class of bug the first version had) ---------
ask('ip link set eth0 down', 'write verb after an allowlisted object');
ask('ip link set eth0 up');
ask('ip addr add 10.0.0.1/24 dev eth0', 'add after an allowlisted object');
ask('ip addr del 10.0.0.1/24 dev eth0');
ask('ip route del default');
ask('ip route add default via 10.0.0.1');
ask('ip -6 addr add fd00::1/64 dev br-lan');
ask('ip link delete br-lan');
ask('ip addr flush dev eth0');
ask('ip link set dev eth0 mtu 1400');
ask('uci set network.lan.ipaddr=10.0.0.1');
ask('uci commit');
ask('uci delete network.wan');
ask('uci add firewall rule');
ask('uci rename network.lan=lan2');
ask('uci import network');
ask('ubus call network reload', 'ubus call invokes arbitrary methods');
ask('opkg install curl');
ask('opkg remove firewall');
ask('apk add curl');
ask('nft flush ruleset');
ask('nft add rule inet fw4 input drop');
ask('reboot');
ask('halt');
ask('/etc/init.d/network restart');
ask('service network restart');
ask('mount /dev/sda1 /mnt');
ask('echo hi', 'echo is not on the allowlist');
ask('rm -rf /tmp/x');
// Reading a sensitive file is read-only, so it is auto-approved. Recorded
// explicitly: this is intended, not an oversight. The gate protects against
// CHANGES; keeping an LLM from reading /etc/shadow is not its job, and the
// router's shadow file is a local root-only file the agent already runs beside.
allow('cat /etc/shadow', 'reading is read-only by design; the gate guards changes');
// The same file must not be writable without approval.
ask('cat /etc/shadow > /tmp/x', 'writing is a change');
ask('cp /etc/shadow /tmp/x', 'cp is not on the allowlist');
ask('chmod 777 /etc/shadow');

// --- queued: shell metacharacters -------------------------------------------
ask('df -h; reboot', 'separator');
ask('df -h && reboot');
ask('df -h | grep sda');
ask('logread > /tmp/x');
ask('logread >> /etc/config/network');
ask('cat /etc/shadow # comment');
ask('`reboot`');
ask('$(reboot)');
ask('df -h &');
ask('ls *');
ask('cat /etc/passwd?.bak');
ask("cat '/etc/shadow'", 'quoting hides content from the scanner');
ask('cat "/etc/shadow"');
ask('cat /etc/sha\\dow', 'backslash escape');
ask('ls ~');
ask('cat /etc/passwd\necho pwned', 'newline separator');
ask('printf "a" > /etc/config/network');
ask('(reboot)');
ask('{ reboot; }');
ask('ls [a-z]*');

// --- queued: malformed, unknown or unreviewable -----------------------------
ask('', 'empty');
ask('   ', 'whitespace only');
ask(null, 'null');
ask(undefined, 'undefined');
ask(42, 'number');
ask('../../bin/sh');
ask('/tmp/df -h', 'unlisted absolute path');
ask('/opt/bin/df -h');
ask('./df');
ask('df\u0001-h', 'control character');
ask('sleep abc', 'non-numeric sleep');
ask('sleep 5 6', 'extra argument');

// --- exec action multiplexing ----------------------------------------------
const execCases = [
	[{ action: 'run', command: 'df -h' }, true, 'run read-only'],
	[{ action: 'run', command: 'reboot' }, false, 'run write'],
	[{ action: 'run', command: 'df -h | sh' }, false, 'run with pipe'],
	[{ action: 'list' }, true, 'list sessions'],
	[{ action: 'poll', session_id: 'x' }, true, 'poll existing session'],
	[{ action: 'read', session_id: 'x' }, true, 'read existing session'],
	[{ action: 'kill', session_id: 'x' }, true, 'kill existing session'],
	[{ action: 'write', session_id: 'x', data: 'rm -rf /\n' }, false, 'write into live session'],
	[{ action: 'send-keys', session_id: 'x', keys: 'enter' }, false, 'send-keys into live session'],
	[{ action: 'bogus' }, false, 'unknown action'],
	[{}, false, 'run with no command'],
	[null, false, 'null args']
];
for (const [args, want, note] of execCases) {
	const r = classifyExecArgs(args);
	if (r.allow === want) pass++;
	else { fail++; failures.push(`exec ${JSON.stringify(args)} -> allow=${r.allow}, wanted ${want} (${note})`); }
}

/* ----------------------------------------------------------------- report */

console.log(`=== approval policy: ${pass + fail} cases, ${pass} passed, ${fail} failed ===`);
if (fail) {
	console.log('\nFailures:');
	for (const f of failures) console.log('  - ' + f);
	process.exit(1);
}
console.log('all policy cases behave as intended');
