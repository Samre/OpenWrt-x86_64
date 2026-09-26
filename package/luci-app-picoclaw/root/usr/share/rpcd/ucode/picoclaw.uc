#!/usr/bin/env ucode
// SPDX-License-Identifier: MIT
//
// PicoClaw approval queue RPC backend (rpcd / ubus).
//
// SECURITY BOUNDARY
//
// This backend deliberately does NOT execute anything. It only moves a queue
// record between states. Execution is the job of the root executor daemon, which
// polls for records in the `approved` state. That split means the web layer can
// never be talked into running a command: the worst an attacker who reaches this
// RPC can do is approve something already sitting in the queue, and every such
// action is written to the audit log with a timestamp.
//
// TOOL ALLOWLIST
//
// Only `exec` and `cron` records may be approved. The gate queues unknown tools
// rather than auto-approving them, so without this check a record for an
// arbitrary tool name could be approved here and then... still not executed,
// because the executor only understands shell commands. The check exists so the
// queue cannot become a vector for approving anything that is not a reviewed
// shell command.
//
// No method takes a path, a filename or a shell fragment. The record id is
// matched by string equality against the queue, so it cannot traverse anywhere.

'use strict';

import { readfile, writefile, popen, stat } from 'fs';

const HOME = getenv('PICOCLAW_HOME') ?? '/etc/picoclaw';
const DIR = HOME + '/approvals';
const QUEUE_FILE = DIR + '/pending.json';
const AUDIT_FILE = DIR + '/audit.log';

// Only these tool records can be approved into execution.
const APPROVABLE_TOOLS = ['exec', 'cron'];

// Maximum bytes of audit log returned to the browser, newest last.
const AUDIT_TAIL_BYTES = 32768;

function now_iso() {
	return trim(popen('date -u +%Y-%m-%dT%H:%M:%SZ', 'r')?.read?.('line') ?? '');
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
		return { items: [] };
	}
	return { items: [] };
}

function save_queue(q) {
	const tmp = QUEUE_FILE + '.tmp';
	writefile(tmp, sprintf('%.J\n', q));
	if (system('mv -f ' + tmp + ' ' + QUEUE_FILE) != 0)
		die('failed to persist the approval queue\n');
	system('chmod 600 ' + QUEUE_FILE);
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

function find_item(q, id) {
	if (type(id) != 'string' || length(id) == 0)
		return null;
	for (let it in q.items)
		if (it != null && it.id == id)
			return it;
	return null;
}

// Who approved it. rpcd exposes the session owner; falling back to a constant
// keeps the record honest rather than guessing.
function actor(request) {
	const user = request?.session?.username ?? request?.username;
	return (type(user) == 'string' && length(user) > 0) ? user : 'unknown';
}

// Strip the fields the browser does not need, so a large captured output is not
// shipped on every poll. Full output stays available through audit_tail.
function project(item) {
	return {
		id: item.id,
		ts: item.ts,
		tool: item.tool,
		command: item.command,
		reason: item.reason,
		channel: item.channel,
		status: item.status,
		decided_at: item.decided_at ?? null,
		decided_by: item.decided_by ?? null,
		executed_at: item.executed_at ?? null,
		exitcode: item.exitcode ?? null,
		elapsed_seconds: item.elapsed_seconds ?? null,
		output: item.output ?? null
	};
}

const methods = {
	list: {
		call: function() {
			const q = load_queue();
			let pending = 0, executed = 0, denied = 0;
			for (let it in q.items) {
				if (it?.status == 'pending') pending++;
				else if (it?.status == 'executed') executed++;
				else if (it?.status == 'denied') denied++;
			}
			return {
				items: map(q.items, project),
				counts: { pending: pending, executed: executed, denied: denied, total: length(q.items) }
			};
		}
	},

	approve: {
		args: { id: 'id' },
		call: function(request) {
			const id = request?.args?.id;
			const q = load_queue();
			const item = find_item(q, id);
			if (item == null)
				return { ok: false, error: 'no such request' };
			if (item.status != 'pending')
				return { ok: false, error: 'request is already ' + item.status };
			if (index(APPROVABLE_TOOLS, item.tool ?? '') == -1)
				return { ok: false, error: 'tool "' + (item.tool ?? '') + '" cannot be approved for execution' };

			// An empty command must never be handed to the executor: `sh -c ''`
			// succeeds and would record a meaningless "executed" entry.
			if (type(item.command) != 'string' || length(trim(item.command)) == 0)
				return { ok: false, error: 'request has no command to run' };

			item.status = 'approved';
			item.decided_at = now_iso();
			item.decided_by = actor(request);
			save_queue(q);
			audit({ event: 'approved', request_id: item.id, tool: item.tool, command: item.command, by: item.decided_by });
			return { ok: true, id: item.id, status: item.status };
		}
	},

	deny: {
		args: { id: 'id' },
		call: function(request) {
			const id = request?.args?.id;
			const q = load_queue();
			const item = find_item(q, id);
			if (item == null)
				return { ok: false, error: 'no such request' };
			if (item.status != 'pending')
				return { ok: false, error: 'request is already ' + item.status };

			item.status = 'denied';
			item.decided_at = now_iso();
			item.decided_by = actor(request);
			save_queue(q);
			audit({ event: 'denied', request_id: item.id, tool: item.tool, command: item.command, by: item.decided_by });
			return { ok: true, id: item.id, status: item.status };
		}
	},

	// Remove a decided record. Pending records cannot be deleted this way, so a
	// request cannot be made to vanish without a decision being recorded.
	forget: {
		args: { id: 'id' },
		call: function(request) {
			const id = request?.args?.id;
			const q = load_queue();
			const item = find_item(q, id);
			if (item == null)
				return { ok: false, error: 'no such request' };
			if (item.status == 'pending' || item.status == 'approved')
				return { ok: false, error: 'refusing to drop a request that has not finished (' + item.status + ')' };

			q.items = filter(q.items, it => it == null || it.id != id);
			save_queue(q);
			audit({ event: 'forgotten', request_id: id, status: item.status, by: actor(request) });
			return { ok: true };
		}
	},

	audit_tail: {
		call: function() {
			const raw = readfile(AUDIT_FILE);
			if (raw == null)
				return { log: '' };
			// Return the tail only: the file grows without bound and the browser
			// must not be asked to render all of it.
			const text = (length(raw) > AUDIT_TAIL_BYTES)
				? substr(raw, length(raw) - AUDIT_TAIL_BYTES)
				: raw;
			return { log: text, truncated: length(raw) > AUDIT_TAIL_BYTES };
		}
	},

	executor_status: {
		call: function() {
			// The lock directory is created with mkdir by the executor and is the
			// only reliable sign that it is alive. A timestamp file next to it
			// records when it started, so a stale lock left by a power cut can be
			// told apart from a running executor.
			const started = readfile(DIR + '.executor.started');
			return {
				running: stat(DIR + '.executor.lock') != null,
				started_at: (started != null) ? trim(started) : null,
				queue_file: QUEUE_FILE,
				audit_file: AUDIT_FILE
			};
		}
	}
};

return { 'luci.picoclaw': methods };
