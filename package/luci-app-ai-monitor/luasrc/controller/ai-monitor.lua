module("luci.controller.ai-monitor", package.seeall)

function index()
    entry({"admin", "services", "ai-monitor"}, alias("admin", "services", "ai-monitor", "dashboard"), _("AI Monitor"), 60).dependent = true
    entry({"admin", "services", "ai-monitor", "dashboard"}, template("ai-monitor/dashboard"), _("Dashboard"), 10).leaf = true
    entry({"admin", "services", "ai-monitor", "settings"}, cbi("ai-monitor/settings"), _("Settings"), 20).leaf = true
    entry({"admin", "services", "ai-monitor", "status"}, template("ai-monitor/status"), _("Status"), 30).leaf = true
    entry({"admin", "services", "ai-monitor", "log"}, call("action_log"), _("Log"), 40).leaf = true
    entry({"admin", "services", "ai-monitor", "chart_data"}, call("action_chart_data")).leaf = true
end

function action_log()
    local log = luci.sys.exec("tail -n 50 /var/log/ai-monitor.log 2>/dev/null")
    luci.template.render("ai-monitor/log", {log = log})
end

function action_chart_data()
    local period = luci.http.formvalue("period") or "daily"
    local data = luci.sys.exec("/usr/lib/ai-monitor/reporter.sh chart " .. period .. " 2>/dev/null")
    luci.http.prepare_content("application/json")
    luci.http.write(data or '{"cpu":[],"mem":[],"temp":[]}')
end
