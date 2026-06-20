module("luci.controller.ai-monitor", package.seeall)

function index()
    entry({"admin", "services", "ai-monitor"}, alias("admin", "services", "ai-monitor", "settings"), _("AI Monitor"), 60).dependent = true
    entry({"admin", "services", "ai-monitor", "settings"}, cbi("ai-monitor/settings"), _("Settings"), 10).leaf = true
    entry({"admin", "services", "ai-monitor", "status"}, template("ai-monitor/status"), _("Status"), 20).leaf = true
    entry({"admin", "services", "ai-monitor", "log"}, call("action_log"), _("View Log"), 30).leaf = true
end

function action_log()
    local log = luci.sys.exec("tail -n 50 /var/log/ai-monitor.log 2>/dev/null")
    luci.template.render("ai-monitor/log", {log = log})
end
