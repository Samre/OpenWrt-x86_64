'use strict';
'require view';
'require poll';
'require rpc';
'require ui';

/*
 * PicoClaw approval queue.
 *
 * Every command the agent wanted to run but was not allowed to run unattended
 * lands here. Approving a record does NOT run it from the browser: the RPC
 * backend only flips the record to `approved`, and the root executor daemon
 * picks it up and runs it. This page therefore cannot be used to execute
 * anything that is not already in the queue.
 */

const callList = rpc.declare({
	object: 'luci.picoclaw',
	method: 'list',
	expect: {}
});

const callApprove = rpc.declare({
	object: 'luci.picoclaw',
	method: 'approve',
	params: [ 'id' ],
	expect: { ok: false }
});

const callDeny = rpc.declare({
	object: 'luci.picoclaw',
	method: 'deny',
	params: [ 'id' ],
	expect: { ok: false }
});

const callForget = rpc.declare({
	object: 'luci.picoclaw',
	method: 'forget',
	params: [ 'id' ],
	expect: { ok: false }
});

const callExecutorStatus = rpc.declare({
	object: 'luci.picoclaw',
	method: 'executor_status',
	expect: {}
});

const STATUS_LABEL = {
	pending:  [ 'label', 'Pending approval' ],
	approved: [ 'label', 'Approved, running…' ],
	executed: [ 'label', 'Executed' ],
	denied:   [ 'label', 'Denied' ]
};

function statusBadge(status) {
	const spec = STATUS_LABEL[status] || [ 'label', status ];
	return E('span', { 'class': 'ifacebox ' + spec[0] }, spec[1]);
}

function shortTime(ts) {
	return ts ? ts.replace('T', ' ').replace('Z', ' UTC') : '—';
}

function renderItem(item, refresh) {
	/*
	 * Everything below is built with E() and passed as text nodes. The command
	 * string is model-generated, so it must never be interpreted as markup:
	 * E() escapes it, which is why there is no innerHTML anywhere in this file.
	 */
	const rows = [
		E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'style': 'white-space:nowrap' }, [ statusBadge(item.status) ]),
			E('td', { 'class': 'td' }, [ shortTime(item.ts) ]),
			E('td', { 'class': 'td' }, [ item.channel || '—' ])
		])
	];

	const code = E('pre', {
		'style': 'margin:0; padding:8px; background:#f5f5f5; border:1px solid #ddd; ' +
			'white-space:pre-wrap; word-break:break-all; font-size:12px'
	}, [ item.command || '(no command)' ]);

	const reason = E('div', { 'style': 'margin-top:6px; color:#666; font-size:12px' }, [
		'Reason: ' + (item.reason || 'not recorded')
	]);

	let result = E([]);
	if (item.status === 'executed') {
		result = E('div', { 'style': 'margin-top:8px' }, [
			E('div', { 'style': 'font-size:12px; color:#666' }, [
				'Exit code ' + (item.exitcode === null ? '?' : item.exitcode) +
				(item.elapsed_seconds !== null ? ' · ' + item.elapsed_seconds + 's' : '') +
				(item.executed_at ? ' · ' + shortTime(item.executed_at) : '')
			]),
			E('pre', {
				'style': 'margin:4px 0 0 0; padding:8px; background:#fff; border:1px solid #ddd; ' +
					'max-height:300px; overflow:auto; white-space:pre-wrap; word-break:break-all; font-size:12px'
			}, [ item.output && item.output.length ? item.output : '(no output)' ])
		]);
	}

	const actions = [];
	if (item.status === 'pending') {
		actions.push(E('button', {
			'class': 'btn cbi-button cbi-button-apply',
			'click': ui.createHandlerFn(null, function() {
				return callApprove(item.id).then(function(res) {
					if (!res || res.ok !== true)
						ui.addNotification(null, E('p', {}, [ 'Approve failed: ' + ((res && res.error) || 'unknown error') ]), 'error');
					else
						ui.addNotification(null, E('p', {}, [ 'Approved. The command will run shortly.' ]), 'info');
					return refresh();
				});
			})
		}, [ 'Approve and run' ]));

		actions.push(E('button', {
			'class': 'btn cbtn cbi-button cbi-button-remove',
			'click': ui.createHandlerFn(null, function() {
				return callDeny(item.id).then(function(res) {
					if (!res || res.ok !== true)
						ui.addNotification(null, E('p', {}, [ 'Deny failed: ' + ((res && res.error) || 'unknown error') ]), 'error');
					return refresh();
				});
			})
		}, [ 'Deny' ]));
	}
	else if (item.status === 'denied' || item.status === 'executed') {
		actions.push(E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, function() {
				return callForget(item.id).then(function() { return refresh(); });
			})
		}, [ 'Remove from list' ]));
	}
	else {
		actions.push(E('em', {}, [ 'waiting for the executor…' ]));
	}

	return E('div', {
		'style': 'border:1px solid #ddd; padding:10px; margin-bottom:10px; background:#fff'
	}, [
		E('table', { 'class': 'table', 'style': 'width:auto; margin-bottom:6px' }, [ E('tbody', {}, rows) ]),
		code,
		reason,
		result,
		E('div', { 'style': 'margin-top:8px' }, actions)
	]);
}

return view.extend({
	load: function() {
		return Promise.all([ callList(), callExecutorStatus() ]);
	},

	render: function(data) {
		const self = this;
		const container = E('div', { 'id': 'picoclaw-approvals' });

		function refresh() {
			return callList().then(function(res) {
				return callExecutorStatus().then(function(exec) {
					self.renderInto(container, res, exec, refresh);
				});
			});
		}

		this.renderInto(container, data[0], data[1], refresh);

		// A queued command is useless if nobody notices it, so keep the page
		// live while it is open.
		poll.add(function() {
			return refresh();
		}, 5);

		return E([], [
			E('h2', {}, [ 'PicoClaw approvals' ]),
			E('p', { 'class': 'cbi-section-descr' }, [
				'Commands the agent asked to run but was not allowed to run unattended. ',
				'Approving a command runs it as root on this router. Read it before you approve it: ',
				'the agent may have proposed it on the basis of content it fetched from the network.'
			]),
			container
		]);
	},

	renderInto: function(container, res, exec, refresh) {
		const items = (res && res.items) || [];
		const counts = (res && res.counts) || { pending: 0, executed: 0, denied: 0, total: 0 };

		const children = [];

		if (exec && exec.running !== true) {
			/*
			 * Without the executor, approvals would sit in "approved" and never
			 * run. Say so instead of showing a queue that silently does nothing.
			 */
			children.push(E('div', {
				'class': 'alert-message warning',
				'style': 'margin-bottom:10px'
			}, [
				'The approval executor is not running, so approved commands will not be executed. ',
				'Restart the service with ', E('code', {}, [ '/etc/init.d/picoclaw restart' ]), '.'
			]));
		}

		children.push(E('p', {}, [
			E('strong', {}, [ String(counts.pending) ]), ' pending · ',
			E('strong', {}, [ String(counts.executed) ]), ' executed · ',
			E('strong', {}, [ String(counts.denied) ]), ' denied'
		]));

		if (items.length === 0) {
			children.push(E('p', { 'class': 'cbi-section-descr' }, [
				'Nothing has been queued. Commands that only read status (for example ',
				E('code', {}, [ 'df -h' ]), ', ', E('code', {}, [ 'logread' ]), ', ',
				E('code', {}, [ 'ip addr' ]), ') run without asking, so they never appear here.'
			]));
		}
		else {
			for (let i = 0; i < items.length; i++)
				children.push(renderItem(items[i], refresh));
		}

		container.content = children;
		container.render();
	}
});
