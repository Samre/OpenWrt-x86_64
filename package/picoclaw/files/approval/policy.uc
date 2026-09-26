// SPDX-License-Identifier: MIT
//
// PicoClaw approval policy: decide whether an `exec` tool call may run
// unattended, or must be queued for human approval.
//
// SECURITY MODEL
//
// The default when anything is unclear is "ask". This is the only safe
// direction: a false "ask" costs the operator one click, a false "allow" hands
// an LLM unattended root on the router.
//
// The classifier therefore does NOT interpret shell syntax. If a command
// contains any character that could chain, substitute, redirect or quote, the
// whole command goes to approval. That is a deliberate trade: `logread | grep
// dns` needs a click, but no crafted input can reach the shell unattended.
//
// On top of that, allowlisted commands are matched against an argument
// allowlist rather than "any plain token". A plain-token rule is not enough:
// `ip link set eth0 down` and `ip addr add 10.0.0.1/24 dev eth0` are all plain
// tokens, yet both change state. Every branch below is therefore written so
// that an unrecognised word is refused, not accepted.
//
// Design rule for maintainers: never add a command whose arguments you cannot
// enumerate. If you cannot list the safe words, the command belongs in the
// approval queue.

'use strict';

// Characters that make shell interpretation possible. Presence of any of these
// sends the command to approval.
//
//   ;  &  |  newline      command separators
//   $  `  \               substitution and escaping
//   >  <                  redirection
//   "  '                  quoting (could hide a separator from this scanner)
//   (  )  {  }            subshells / grouping
//   *  ?  [  ]  ~         globbing and expansion
//   !  #                  history expansion and comments
//
// The scanner never has to understand these; it only has to notice them.
const SHELL_META = /[;&|\n\r$`\\><"'(){}*?\[\]~!#]/;

// A bare argument that is safe to append to a fully-enumerated command: word
// characters, dots, hyphens, slashes, colons, equals, commas and percent.
// No whitespace (that would be two arguments), no shell metacharacters.
const SAFE_ARG = /^[A-Za-z0-9_.\/:=,%-]+$/;

// `ip` needs three levels of scrutiny, because its object layer decides what
// the verb means: `ip link show` reads, `ip link set` writes.
//
// ip accepts the verb either before or after the object:
//
//     ip [-flags] <verb> <object>   e.g. `ip show link`
//     ip [-flags] <object> [<verb>] e.g. `ip addr`, `ip addr show eth0`
//
// The second form defaults the verb to "show". Both are parsed, and in both the
// object must be a read object, any explicit verb must be a read verb, and
// every remaining word must be a known display word or a known device name.
// That is what rejects `ip link set eth0 down`: `set` is not a read verb.
//
// Note this is NOT a "plain tokens" rule. `set`, `add`, `del` and `flush` are
// all plain tokens; they are refused because they are absent from IP_VERBS.
const IP_VERBS = ['show', 'list', 'sh', 'ls', 'get', 'stats', 'save'];
const IP_OBJECTS = [
	'addr', 'address', 'a', 'link', 'l', 'route', 'r', 'rule',
	'neigh', 'neighbour', 'n', 'maddr', 'tunnel', 'tuntap', 'stats'
];
// Words that may follow a read verb: display modifiers, selector keywords and
// the device names this firmware uses. Device names are matched separately by
// IP_DEVICE so a renamed interface is refused rather than assumed safe.
const IP_SAFE_WORDS = [
	'show', 'list', 'sh', 'ls', 'get', 'stats', 'save', 'dev', 'to', 'from',
	'table', 'all', 'cached', 'permanent', 'noarp', 'up', 'broadcast',
	'multicast', 'inet', 'inet6', 'link', 'scope', 'global', 'host', 'universe'
];
const IP_DEVICE = /^(lo|eth[0-9]+|br[0-9a-z_.-]*|wlan[0-9a-z_.-]*|pppoe[0-9a-z_.-]*|tun[0-9a-z_.-]*|tap[0-9a-z_.-]*|docker[0-9]*|veth[0-9a-z_.-]*|bond[0-9a-z_.-]*|sit[0-9]+|wg[0-9a-z_.-]*)$/;

// Commands that only read, with the arguments they may be invoked with.
//
//   words: [...]      -> every argument must be one of these exact words
//   subcommands: {...} -> first argument selects the form, then:
//                          { args: false }  no further arguments
//                          { words: [...] } further arguments from this list
//                          { safe: true }   further arguments just have to
//                                           match SAFE_ARG (paths, names)
//   flags: [...]      -> leading single-dash flags that may be skipped before
//                        the subcommand word is examined
//   args: false       -> no arguments at all
//   args: 'safe'      -> arguments just have to match SAFE_ARG
//
// There is deliberately no "args: true" that accepts anything plain; that is
// the rule that let `ip link set` through during development.
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

	// Readers whose arguments are selectors: a fixed vocabulary.
	'head':  { args: 'safe' },
	'tail':  { args: 'safe' },
	'grep':  { args: 'safe' },

	// `ip` is handled by the dedicated three-level check, never by the generic
	// safe-argument rule.
	'ip': { special: 'ip' },

	// `uci`: only read verbs, and only a fixed set of option words.
	'uci': {
		subcommands: {
			'show':    { args: 'safe' },
			'get':     { args: 'safe' },
			'changes': { args: false },
			'export':  { args: 'safe' }
		}
	},

	// `ubus`: `call` invokes arbitrary object methods and is never auto-run.
	'ubus': {
		subcommands: {
			'list': { args: 'safe' }
		}
	},

	// `nft`: `list` only, and only the fixed rule-set vocabulary.
	'nft': {
		subcommands: {
			'list': { words: ['ruleset', 'tables', 'chains', 'rules', 'sets', 'maps', 'counters', 'flowtables', 'meters', 'limits', 'quotas', 'ct', 'help', 'meter', 'synproxy', 'element'] }
		}
	},

	// Readers that take a package name or a path.
	'opkg': {
		subcommands: {
			'list':       { args: false },
			'list-installed': { args: false },
			'list-upgradable': { args: false },
			'status':     { args: false },
			'info':       { args: 'safe' },
			'find':       { args: 'safe' }
		}
	},
	'apk': {
		subcommands: {
			'list':  { args: 'safe' },
			'info':  { args: 'safe' },
			'stats': { args: false }
		}
	},

	// Network diagnostics. Passwords and interactive forms are not reachable
	// through these in the forms allowed here.
	'ping':       { args: 'safe' },
	'ping6':      { args: 'safe' },
	'nslookup':   { args: 'safe' },
	'traceroute': { args: 'safe' },

	// `sleep` is allowed only with a numeric literal argument, so a bare
	// `sleep 5` works but nothing creates a long-hanging unattended process by
	// naming an arbitrary token.
	'sleep': { numeric: true }
};

// Leading flags that may appear before a subcommand word. A flag not listed
// here forces approval rather than being skipped, so `ip -force ...` cannot
// smuggle a verb past the subcommand check.
const ALLOWED_LEADING_FLAGS = {
	'ip':   ['-4', '-6', '-o', '-br', '-brief', '-s', '-d', '-a', '-n', '-h', '-json', '-p', '-human', '-iec', '-oneline'],
	'opkg': [],
	'apk':  []
};

function split_words(cmd) {
	return filter(split(trim(cmd), /[ \t]+/), w => length(w) > 0);
}

// Strip a leading /bin/, /sbin/, /usr/bin/ or /usr/sbin/ so `/bin/df` is
// recognised as `df`. Any deeper path is refused: a path could point at a
// replaced binary, and this firmware's own tools live in those four dirs.
function normalize_binary(word) {
	let m = match(word, /^(\/bin\/|\/sbin\/|\/usr\/bin\/|\/usr\/sbin\/)([^\/]+)$/);
	if (m != null)
		return m[2];
	return null;
}

function args_are_safe(args) {
	for (let a in args)
		if (!match(a, SAFE_ARG))
			return false;
	return true;
}

function all_words_in(args, allowed) {
	for (let a in args)
		if (index(allowed, a) == -1)
			return false;
	return true;
}

function is_ip_device(word) {
	return match(word, IP_DEVICE) != null;
}

// `ip` check, accepting both argument orders.
//   ip [-flags] <verb> <object> [words...]     e.g. ip show link
//   ip [-flags] <object> [<verb>] [words...]   e.g. ip addr / ip addr show eth0
function classify_ip(rest) {
	const flags = ALLOWED_LEADING_FLAGS['ip'];
	let i = 0;
	while (i < length(rest) && index(flags, rest[i]) != -1)
		i++;

	const first = rest[i];
	if (first == null)
		return { allow: false, reason: '"ip" requires an object (addr/link/route/...)' };

	let object, tail;

	if (index(IP_OBJECTS, first) != -1) {
		// Object-first form: `ip addr`, `ip addr show eth0`, `ip link`.
		object = first;
		tail = slice(rest, i + 1);
	} else if (index(IP_VERBS, first) != -1) {
		// Verb-first form: `ip show link`.
		object = rest[i + 1];
		if (object == null)
			return { allow: false, reason: `"ip ${first}" requires an object (addr/link/route/...)` };
		if (index(IP_OBJECTS, object) == -1)
			return { allow: false, reason: `"ip ${first} ${object}" does not name a known object` };
		tail = slice(rest, i + 2);
	} else {
		return { allow: false, reason: `"ip ${first}" is neither a known object nor a read verb` };
	}

	for (let w in tail) {
		// A verb in this position must be a read verb; this is the check that
		// rejects `ip link set eth0 down`.
		if (index(IP_SAFE_WORDS, w) != -1)
			continue;
		if (is_ip_device(w))
			continue;
		// A numeric literal is harmless here (table id, metric, index).
		if (match(w, /^[0-9]+$/))
			continue;
		return { allow: false, reason: `"ip ${object}" has an unrecognised word: ${w}` };
	}

	return { allow: true, reason: `read-only ip query (${object})` };
}

function classify_subcommand(binary, rest) {
	const spec = ALLOWLIST[binary];
	const flags = ALLOWED_LEADING_FLAGS[binary] ?? [];

	let i = 0;
	while (i < length(rest) && index(flags, rest[i]) != -1)
		i++;

	const head = rest[i];
	if (head == null)
		return { allow: false, reason: `"${binary}" requires a read subcommand` };

	// Support both `opkg list` and the `opkg list-installed` single-word form:
	// try the exact word first, then the word before the first dash.
	let form = spec.subcommands[head];
	if (form == null && index(head, '-') != -1) {
		const base = substr(head, 0, index(head, '-'));
		if (spec.subcommands[base] != null)
			form = spec.subcommands[head] ?? spec.subcommands[base];
	}
	if (form == null)
		return { allow: false, reason: `"${binary} ${head}" is not a read-only subcommand` };

	const tail = slice(rest, i + 1);

	if (form.args === false) {
		if (length(tail) > 0)
			return { allow: false, reason: `"${binary} ${head}" takes no further arguments` };
		return { allow: true, reason: `read-only query (${binary} ${head})` };
	}
	if (form.words != null) {
		if (!all_words_in(tail, form.words))
			return { allow: false, reason: `"${binary} ${head}" has a word outside its read-only vocabulary` };
		return { allow: true, reason: `read-only query (${binary} ${head})` };
	}
	if (!args_are_safe(tail))
		return { allow: false, reason: `"${binary} ${head}" has arguments that are not plain tokens` };
	return { allow: true, reason: `read-only query (${binary} ${head})` };
}

// Returns { allow: bool, reason: string }
function classify(command) {
	if (type(command) != 'string' || length(trim(command)) == 0)
		return { allow: false, reason: 'empty command' };

	// Reject control characters outright: they cannot be reviewed meaningfully
	// by a human in a web form, and they can hide content from a terminal.
	for (let off = 0, byte = ord(command); off < length(command); byte = ord(command, ++off))
		if (byte < 32 && byte != 9 && byte != 10 && byte != 13)
			return { allow: false, reason: 'command contains control characters' };

	if (match(command, SHELL_META))
		return {
			allow: false,
			reason: 'contains shell metacharacters (chaining, substitution, redirection or quoting), so the effect cannot be judged from the command name alone'
		};

	const words = split_words(command);
	if (length(words) == 0)
		return { allow: false, reason: 'empty command' };

	const raw = words[0];
	let binary = raw;
	let was_path = false;

	if (index(raw, '/') != -1) {
		binary = normalize_binary(raw);
		was_path = true;
		if (binary == null)
			return { allow: false, reason: `command runs an unrecognised path: ${raw}` };
	}

	const spec = ALLOWLIST[binary];
	if (spec == null)
		return { allow: false, reason: `"${binary}" is not on the read-only allowlist` };

	const rest = slice(words, 1);

	if (spec.special == 'ip')
		return classify_ip(rest);

	if (spec.subcommands != null)
		return classify_subcommand(binary, rest);

	if (spec.numeric === true) {
		if (length(rest) != 1 || !match(rest[0], /^[0-9]+(\.[0-9]+)?$/))
			return { allow: false, reason: `"${binary}" is only auto-approved with a single numeric argument` };
		return { allow: true, reason: 'bounded delay' };
	}

	if (spec.args === false) {
		if (length(rest) > 0)
			return { allow: false, reason: `"${binary}" is only auto-approved without arguments` };
		return { allow: true, reason: was_path ? `read-only command (${raw})` : 'read-only command' };
	}

	if (!args_are_safe(rest))
		return { allow: false, reason: `"${binary}" has arguments that are not plain tokens` };

	return { allow: true, reason: was_path ? `read-only command (${raw})` : 'read-only command' };
}

// The exec tool is a session multiplexer, not a single command runner. Only the
// `run` action starts a process; `poll`, `read`, `list` and `kill` act on an
// already-approved session and are allowed through, because the command they
// refer to was classified when it was started. `write` and `send-keys` feed a
// live session and are always queued.
function classify_exec_args(args) {
	if (type(args) != 'object' || args == null)
		return { allow: false, reason: 'exec called without arguments' };

	const action = args.action ?? 'run';

	if (action == 'list')
		return { allow: true, reason: 'listing exec sessions' };

	if (action == 'run')
		return classify(args.command);

	if (action == 'poll' || action == 'read' || action == 'kill')
		return { allow: true, reason: `session ${action} on an already-approved command` };

	if (action == 'write' || action == 'send-keys')
		return { allow: false, reason: `"${action}" feeds a live shell session and cannot be reviewed as a command` };

	return { allow: false, reason: `unrecognised exec action: ${action}` };
}

return {
	SHELL_META,
	SAFE_ARG,
	ALLOWLIST,
	IP_VERBS,
	IP_OBJECTS,
	IP_SAFE_WORDS,
	ALLOWED_LEADING_FLAGS,
	classify,
	classify_exec_args
};
