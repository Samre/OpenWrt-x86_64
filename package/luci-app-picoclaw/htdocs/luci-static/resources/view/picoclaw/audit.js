'use strict';
'require view';
'require poll';
'require rpc';
'require ui';

/*
 * PicoClaw audit log.
 *
 * Shows the tail of /etc/picoclaw/approvals/audit.log: who approved what, when,
 * and what it printed. Auto-approved read-only commands are recorded here too,
 * so this is the complete record of what the agent was allowed to do without
 * asking.
 */

const callAuditTail = rpc.declare({
	object: 'luci.picoclaw',
	method: 'audit_tail',
	expect: {}
});

return view.extend({
	load: function() {
		return callAuditTail();
	},

	render: function(data) {
		const container = E('pre', {
			'style': 'padding:10px; background:#fff; border:1px solid #ddd; ' +
				'max-height:70vh; overflow:auto; white-space:pre-wrap; word-break:break-all; font-size:12px'
		});

		function refresh() {
			return callAuditTail().then(function(res) {
				const text = (res && res.log) || '';
				container.textContent = text.length ? text : '(audit log is empty)';
			});
		}

		container.textContent = (data && data.log && data.log.length) ? data.log : '(audit log is empty)';

		poll.add(function() {
			return refresh();
		}, 10);

		return E([], [
			E('h2', {}, [ 'PicoClaw audit log' ]),
			E('p', { 'class': 'cbi-section-descr' }, [
				'Newest entries are at the bottom. This file grows without bound and is ',
				'only tailed here, so download it if you need the full history.'
			]),
			(data && data.truncated)
				? E('div', { 'class': 'alert-message warning' }, [ 'Showing the tail of a larger log.' ])
				: E([]),
			container
		]);
	}
});
