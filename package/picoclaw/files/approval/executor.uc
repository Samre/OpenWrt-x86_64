#!/usr/bin/env ucode
// SPDX-License-Identifier: MIT
//
// PicoClaw approval executor.
//
// Started once per gateway lifetime by the gate hook (see gate.uc). It is the
// ONLY component that runs a previously blocked command, and it runs it because
// an operator approved it in the LuCI app - never because the model asked.
//
// SINGLE INSTANCE
//
// A lock directory is claimed with mkdir(), which is atomic, so a second start
// exits immediately. This matters because the hook restarts whenever the
// gateway does, and two executors would double-run every approval.
//
// WHAT IT DELIVERS
//
// The executed command's output is written into the queue record and into the
// audit log, so the operator can read the result in the web interface, and the
// audit trail shows exactly what ran, why, when, and what it printed.

'use strict';

import { readfile, writefile, mkdir, popen, stat } from 'fs';

const HOME = getenv('PICOCLAW_HOME') ?? '/etc/picoclaw';
const DIR = HOME + '/approvals';
const QUEUE_FILE = DIR + '/pending.json';
const AUDIT_FILE = DIR + '/audit.log';
const LOCK_DIR = DIR + '.executor.lock';
// Records when this executor started. ucode has no getpid(), so a timestamp is
// the honest liveness marker available without guessing at an API.
const STARTED_FILE = DIR + '.executor.started';
// ucode's sleep() takes MILLISECONDS, not seconds (verified against real LuCI
// scripts, which call sleep(100) to wait under a second for popen output).
// Calling sleep(2) here would busy-wait and burn CPU on a router.
const POLL_MS = 2000;
const DEFAULT_TIMEOUT = 60;
const MAX_CAPTURE = 16384;

function log(msg) {
	warn('picoclaw-approval-executor: ' + msg + '\n');
}

function now_iso() {
	return trim(popen('date -u +%Y-%m-%dT%H:%M:%SZ', 'r')?.read?.('line') ?? '');
}

function audit(fields) {
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

function load_queue() {
	const raw = readfile(QUEUE_FILE);
	if (raw == null || length(trim(raw)) == 0)
		return { items: [] };
	try {
		const parsed = json(raw);
		if (type(parsed) == 'object' && parsed != null && type(parsed.items) == 'array')
			return parsed;
	} catch (e) {
		log('queue unreadable: ' + e);
	}
	return { items: [] };
}

function save_queue(q) {
	const tmp = QUEUE_FILE + '.tmp';
	writefile(tmp, sprintf('%.J\n', q));
	if (system('mv -f ' + tmp + ' ' + QUEUE_FILE) != 0) {
		log('failed to replace ' + QUEUE_FILE);
		return false;
	}
	system('chmod 600 ' + QUEUE_FILE);
	return true;
}

// Run one approved command and capture its combined output.
//
// The command was written by an LLM and only reaches this point because a human
// approved this exact string, so it is intentionally run through a shell: the
// operator reviewed a shell command and that is what must execute.
//
// Note the redirect target is a temp file, never the executor's own stdout.
// Writing to stdout here would be harmless (this process is detached from the
// hook's JSON-RPC stream) but it would also lose the output, which is the whole
// point of the record.
function run_command(command, timeout_seconds) {
	const timeout = (timeout_seconds > 0) ? int(timeout_seconds) : DEFAULT_TIMEOUT;
	const outfile = '/tmp/picoclaw-approval-out.' + time();
	const runfile = '/tmp/picoclaw-approval-run.' + time();

	// busybox timeout is available on this firmware's base system.
	const wrapped = 'timeout ' + timeout + ' /bin/sh -c ' + shell_quote(command) +
		' > ' + shell_quote(outfile) + ' 2>&1';
	const started = time();
	const code = system(wrapped + ' ; echo $? > ' + shell_quote(runfile));
	const elapsed = time() - started;

	let output = readfile(outfile) ?? '';
	let exitcode = int(trim(readfile(runfile) ?? '0'));
	if (exitcode == 124 || exitcode == 143)
		output = output + '\n[timed out after ' + timeout + 's]';

	if (length(output) > MAX_CAPTURE)
		output = substr(output, 0, MAX_CAPTURE) + '\n[output truncated at ' + MAX_CAPTURE + ' bytes]';

	system('rm -f ' + shell_quote(outfile) + ' ' + shell_quote(runfile));

	return { output: output, exitcode: exitcode, elapsed: elapsed };
}

// Single-quote for /bin/sh, escaping embedded single quotes the usual way.
function shell_quote(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

function main() {
	// Atomic single-instance claim. mkdir() either creates the directory or
	// fails, with no window in between, so two executors cannot both start.
	if (system('mkdir ' + shell_quote(LOCK_DIR) + ' 2>/dev/null') != 0) {
		log('another executor already holds the lock; exiting');
		return;
	}

	// Timestamp marker, readable by the status page so an operator can tell a
	// running executor from a stale lock directory left by a power cut.
	writefile(STARTED_FILE, now_iso() + '\n');

	log('started, watching ' + QUEUE_FILE);

	// The poll interval is a few seconds, so this loop is idle almost all the
	// time: sleep() blocks rather than spinning.
	while (true) {
		const q = load_queue();
		let changed = false;

		for (let item in q.items) {
			if (item == null || item.status != 'approved')
				continue;

			audit({ event: 'execution_started', request_id: item.id, command: item.command, approved_by: item.decided_by ?? '' });
			log('executing approved request ' + item.id);

			const res = run_command(item.command, item.timeout);

			item.status = 'executed';
			item.executed_at = now_iso();
			item.exitcode = res.exitcode;
			item.output = res.output;
			item.elapsed_seconds = res.elapsed;
			changed = true;

			audit({
				event: 'execution_finished',
				request_id: item.id,
				command: item.command,
				exitcode: res.exitcode,
				elapsed_seconds: res.elapsed,
				output: res.output
			});
			log('request ' + item.id + ' finished with exit code ' + res.exitcode);
		}

		if (changed && !save_queue(q))
			log('could not persist execution results; they remain in the audit log');

		sleep(POLL_MS);
	}
}

main();
