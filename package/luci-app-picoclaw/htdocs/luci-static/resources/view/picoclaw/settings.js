'use strict';
'require view';
'require form';

/*
 * PicoClaw settings.
 *
 * Scope note: this edits /etc/config/picoclaw only, which holds process and
 * environment knobs. API keys and channel tokens live in
 * /etc/picoclaw/config.json and are deliberately NOT editable here, so that a
 * secret never travels through the browser or into the UCI commit history. The
 * page links to the LuCI file editor for that file instead.
 */

return view.extend({
	render: function() {
		const m = new form.Map('picoclaw', 'PicoClaw',
			'PicoClaw is an AI agent. These settings control how its service starts. ' +
			'Model credentials and message-channel tokens are kept separately in ' +
			'/etc/picoclaw/config.json.');

		/* --- service --- */
		let s = m.section(form.NamedSection, 'config', 'basic', 'Service');
		s.anonymous = true;

		let o = s.option(form.Flag, 'enabled', 'Enable PicoClaw',
			'Starts the gateway at boot. Disabling this stops the agent entirely, ' +
			'including message channels.');
		o.rmempty = false;

		o = s.option(form.Flag, 'logger', 'Forward gateway output to the system log',
			'Lets you read agent logs with logread -e picoclaw.');
		o.rmempty = false;

		o = s.option(form.Value, 'delay', 'Start delay (seconds)',
			'Applied only when the device booted less than two minutes ago, so the ' +
			'clock and network are up before the agent starts.');
		o.datatype = 'uinteger';
		o.placeholder = '0';

		/* --- gateway --- */
		s = m.section(form.NamedSection, 'gateway', 'gateway', 'Gateway');
		s.anonymous = true;

		o = s.option(form.Value, 'host', 'Listen address',
			'Keep this on 127.0.0.1. The gateway serves the agent Web UI and its API ' +
			'without authentication; binding it to a LAN or WAN address exposes both, ' +
			'and the agent can run commands. Reach the UI over SSH instead: ' +
			'ssh -L 18790:127.0.0.1:18790 root@this-router');
		o.datatype = 'host';
		o.placeholder = '127.0.0.1';
		o.rmempty = false;

		o = s.option(form.Value, 'port', 'Listen port');
		o.datatype = 'port';
		o.placeholder = '18790';

		/* --- agent --- */
		s = m.section(form.NamedSection, 'agent', 'agent', 'Agent');
		s.anonymous = true;

		o = s.option(form.Value, 'workspace', 'Workspace directory',
			'Where the agent keeps sessions, memory and skills. On a small overlay, ' +
			'point this at an external disk so history survives a reflash.');
		o.datatype = 'directory';
		o.placeholder = '/etc/picoclaw/workspace';

		o = s.option(form.Flag, 'restrict_to_workspace', 'Restrict the agent to its workspace',
			'Leave this enabled. With it off, the agent file tools can read and write ' +
			'anywhere on the router, including /etc/config.');
		o.default = '1';
		o.rmempty = false;

		/* --- heartbeat --- */
		s = m.section(form.NamedSection, 'heartbeat', 'heartbeat', 'Heartbeat');
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', 'Enable heartbeat',
			'Lets the agent wake on an interval and act on its own, which calls the ' +
			'model around the clock and costs tokens. Off by default.');
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'interval', 'Heartbeat interval (minutes)');
		o.datatype = 'uinteger';
		o.depends('enabled', '1');
		o.placeholder = '30';

		return m.render();
	}
});
