#!/usr/bin/env ucode
// SPDX-License-Identifier: MIT
//
// PicoClaw tool-approval gate.
//
// Runs as an out-of-process hook (JSON-RPC over stdio, one message per line).
// PicoClaw starts it, sends hook.hello, then sends hook.before_tool before
// every tool call. See docs/architecture/hooks/hook-json-protocol.md upstream.
//
// WHAT THIS SOLVES
//
// PicoClaw's exec tool gives the model unattended root. Its own denylist only
// matches obviously destructive spellings, and upstream states plainly that the
// hook system cannot suspend a turn and wait for a human. So this gate does the
// only thing that is actually possible: it refuses to let anything unreviewed
// run, records it, tells the user, and lets the operator approve it out of band
// (the LuCI app). The approved command is then executed by the RPC backend, not
// by the model.
//
// WHY respond AND NOT approve_tool
//
// `respond` returns a tool result without executing the tool. Upstream warns in
// pkg/agent/hooks.go that respond BYPASSES approve_tool, so this hook does not
// rely on approve_tool for anything: it is the sole decision point for exec.
// approve_tool is still implemented as a fail-closed backstop in case a future
// upstream version consults it separately.
//
// FAIL-CLOSED
//
// Every ambiguous path denies. If the policy module cannot be loaded, if the
// queue cannot be written, if the request cannot be parsed, the answer is
// "queued" (or an error), never "continue".

'use strict';

import { stdin, readfile, writefile, mkdir, popen, stat } from 'fs';
import * as policy from './policy.uc';

const HOME = getenv('PICOCLAW_HOME') ?? '/etc/picoclaw';
const APPROVALS_DIR = HOME + '/approvals';
const QUEUE_FILE = APPROVALS_DIR + '/pending.json';
const AUDIT_FILE = APPROVALS_DIR + '/audit.log';

// Tools the gate never judges: they cannot spawn a process. Kept explicit so a
// new upstream tool gets queued rather than silently auto-approved.
const PASSTHROUGH_TOOLS = [
	'web_search', 'web_fetch', 'read_file', 'write_file', 'list_dir',
	'edit_file', 'load_image', 'send_file', 'cron', 'spawn', 'spawn_status',
	'delegate', 'skills_search', 'skills_install', 'message', 'reaction'
];

const MAX_PENDING = 50;

function out(obj) {
	// The hook protocol is line-delimited JSON on stdout. Nothing else may be
	// written to stdout: a stray print would corrupt the stream and PicoClaw
	// would drop the hook. Diagnostics go to stderr only.
	printf('%J\n', obj);
}

function log_err(msg) {
	// stderr is forwarded to the gateway log, which is where an operator looks
	// when an approval never appears.
	warn('picoclaw-approval-gate: ' + msg + '\n');
}

function now_iso() {
	// `date` is always present; ucode's time() has no ISO formatter.
	return trim(popen('date -u +%Y-%m-%dT%H:%M:%SZ', 'r')?.read?.('line') ?? '');
}

function ensure_dir() {
	if (stat(APPROVALS_DIR) == null)
		mkdir(APPROVALS_DIR, 0o700);
}

function load_queue() {
	const raw = readfile(QUEUE_FILE);
	if (raw == null || length(trim(raw)) == 0)
		return { items: [] };
	try {
		const parsed = json(raw);
		if (type(parsed) == 'object' && parsed != null && type(parsed.items) == 'array')
			return parsed;
	} catch (e) {
		log_err('pending queue is not valid JSON, starting a fresh one: ' + e);
	}
	return { items: [] };
}

function save_queue(q) {
	ensure_dir();
	// Write to a temporary file and rename, so a crash mid-write cannot leave a
	// truncated queue that would lose pending approvals.
	const tmp = QUEUE_FILE + '.tmp';
	writefile(tmp, sprintf('%.J\n', q));
	if (system('mv -f ' + tmp + ' ' + QUEUE_FILE) != 0) {
		log_err('failed to replace ' + QUEUE_FILE);
		return false;
	}
	system('chmod 600 ' + QUEUE_FILE);
	return true;
}

function audit(fields) {
	ensure_dir();
	// Append-only audit trail. Written even for auto-approved commands, so the
	// record shows what the agent was allowed to do without asking.
	let record = { ts: now_iso() };
	for (let k in fields)
		record[k] = fields[k];

	const f = popen('cat >> ' + AUDIT_FILE, 'w');
	if (f != null) {
		f.write(sprintf('%.J\n', record));
		f.close();
	}
	system('chmod 600 ' + AUDIT_FILE);
}

function make_id() {
	// Short, sortable, collision-resistant enough for a single device.
	return time() + '-' + sprintf('%04x', rand() & 0xffff);
}

function enqueue(tool, args, reason, meta) {
	const q = load_queue();
	const item = {
		id: make_id(),
		ts: now_iso(),
		tool: tool,
		arguments: args,
		command: args?.command ?? '',
		reason: reason,
		session_key: meta?.SessionKey ?? '',
		channel: meta?.Channel ?? '',
		chat_id: meta?.ChatID ?? '',
		status: 'pending'
	};

	// Newest first: the operator sees the most recent request at the top.
	q.items = [item, ...q.items];

	// Bound the queue so a misbehaving agent cannot fill the overlay. Anything
	// dropped is written to the audit trail rather than disappearing.
	if (length(q.items) > MAX_PENDING) {
		const dropped = slice(q.items, MAX_PENDING);
		q.items = slice(q.items, 0, MAX_PENDING);
		for (let d in dropped)
			audit({ event: 'dropped_pending', request_id: d.id, command: d.command, reason: 'queue full' });
		log_err('pending queue full; dropped ' + length(dropped) + ' oldest request(s)');
	}

	if (!save_queue(q)) {
		audit({ event: 'enqueue_failed', command: item.command, reason: reason });
		return null;
	}

	audit({ event: 'queued_for_approval', request_id: item.id, tool: tool, command: item.command, reason: reason });
	return item;
}

function respond_queued(item, tool) {
	const cmd = item?.command ?? '';
	const id = item?.id ?? '(not recorded)';

	let llm = 'BLOCKED: this command was NOT executed and nothing has changed.\n\n';
	llm += 'Command: ' + cmd + '\n';
	llm += 'Reason: ' + (item?.reason ?? 'not auto-approvable') + '\n\n';
	llm += 'It has been queued for the operator to approve as request ' + id + '.\n';
	llm += 'Do not retry it, do not try to achieve the same effect another way, and do not\n';
	llm += 'claim it succeeded. Tell the user it is waiting for approval under\n';
	llm += 'Services -> PicoClaw -> Approvals.';

	let user;
	if (item == null)
		user = 'A command was blocked and could NOT be queued (the approval store is not writable):\n' + cmd;
	else
		user = 'Command awaiting your approval (' + id + '):\n' + cmd + '\nReason: ' + item.reason + '\nApprove it under Services -> PicoClaw -> Approvals.';

	return {
		action: 'respond',
		result: {
			for_llm: llm,
			for_user: user,
			silent: false,
			is_error: false
		}
	};
}

// --- request handlers -------------------------------------------------------

// Start the executor once per gateway lifetime.
//
// The hook process lives as long as the gateway, which runs under procd, so a
// detached child is tied to the same lifetime. The executor claims its own lock
// with mkdir(), so a restart or a second hook cannot produce two executors.
// PATH is passed explicitly because the executor runs approved commands and a
// stripped environment would make common commands unresolvable.
function spawn_executor() {
	if (stat(APPROVALS_DIR) == null)
		mkdir(APPROVALS_DIR, 0o700);

	const script = '/usr/share/picoclaw/approval/executor.uc';
	if (stat(script) == null) {
		log_err('executor script is missing at ' + script + '; approved commands will not run');
		return;
	}

	const cmd = 'PICOCLAW_HOME=' + shell_quote(HOME) +
		' PATH=/usr/sbin:/usr/bin:/sbin:/bin' +
		' /usr/bin/ucode ' + shell_quote(script) +
		' >/dev/null 2>&1 &';

	// A non-zero return here means the shell could not start the child at all.
	if (system(cmd) != 0)
		log_err('failed to start the approval executor');
}

function shell_quote(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

function handle_hello(params) {
	spawn_executor();
	return { ok: true, name: 'picoclaw-approval-gate' };
}

function handle_before_tool(params) {
	const tool = params?.tool ?? '';
	const args = params?.arguments ?? {};
	const meta = params?.meta ?? {};

	// exec is the only tool that can start a process, so it is the only one the
	// policy needs to judge.
	if (tool != 'exec') {
		if (index(PASSTHROUGH_TOOLS, tool) != -1)
			return { action: 'continue' };

		// A tool this file does not know about might do anything. Queue it so a
		// new upstream tool is never silently auto-approved.
		log_err('unknown tool "' + tool + '" is not on the passthrough list; queueing it');
		return respond_queued(enqueue(tool, args, 'unrecognised tool "' + tool + '"', meta), tool);
	}

	const verdict = policy.classify_exec_args(args);

	if (verdict.allow) {
		audit({ event: 'auto_approved', tool: tool, command: args?.command ?? '', reason: verdict.reason });
		return { action: 'continue' };
	}

	return respond_queued(enqueue('exec', args, verdict.reason, meta), tool);
}

// Backstop only. `respond` above bypasses this hook upstream, so it should not
// normally be reached for exec. If it ever is, deny anything not auto-approvable.
function handle_approve_tool(params) {
	const tool = params?.tool ?? '';
	if (tool != 'exec')
		return { approved: index(PASSTHROUGH_TOOLS, tool) != -1 };

	const verdict = policy.classify_exec_args(params?.arguments ?? {});
	if (verdict.allow)
		return { approved: true };

	return { approved: false, reason: 'not auto-approvable (' + verdict.reason + '); approve it in the web interface' };
}

const handlers = {
	'hook.hello': handle_hello,
	'hook.before_tool': handle_before_tool,
	'hook.approve_tool': handle_approve_tool,
	// Interceptors this gate does not use must still answer, or the agent loop
	// stalls waiting for a reply.
	'hook.before_llm': () => ({ action: 'continue' }),
	'hook.after_llm': () => ({ action: 'continue' }),
	'hook.after_tool': () => ({ action: 'continue' })
};

// --- main loop --------------------------------------------------------------

let line;
while ((line = stdin.read('line')) != null) {
	const text = trim(line);
	if (length(text) == 0)
		continue;

	let msg;
	try {
		msg = json(text);
	} catch (e) {
		// A malformed line cannot be answered per-request. Log it and keep
		// serving: exiting would make every later tool call hang until PicoClaw
		// restarts the hook.
		log_err('cannot parse hook request: ' + e);
		continue;
	}

	const id = msg?.id;
	const method = msg?.method ?? '';
	const params = msg?.params ?? {};

	// Notifications carry no id and expect no reply.
	if (id == null || id == 0)
		continue;

	const handler = handlers[method];
	if (handler == null) {
		out({ jsonrpc: '2.0', id: id, error: { code: -32601, message: 'method not found: ' + method } });
		continue;
	}

	try {
		out({ jsonrpc: '2.0', id: id, result: handler(params) });
	} catch (e) {
		// Fail closed: an error must never become "allow".
		log_err('handler ' + method + ' failed: ' + e);
		if (method == 'hook.before_tool') {
			out({
				jsonrpc: '2.0', id: id,
				result: {
					action: 'respond',
					result: {
						for_llm: 'BLOCKED: the approval gate failed while reviewing this command, so it was not executed. Report this to the user.',
						for_user: 'A command was blocked because the approval gate errored. Nothing was executed.',
						silent: false,
						is_error: true
					}
				}
			});
		} else if (method == 'hook.approve_tool') {
			out({ jsonrpc: '2.0', id: id, result: { approved: false, reason: 'approval gate error' } });
		} else {
			out({ jsonrpc: '2.0', id: id, error: { code: -32000, message: '' + e } });
		}
	}
}
