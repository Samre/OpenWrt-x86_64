-- AI Monitor Settings

local m, s, o

m = Map("ai-monitor", translate("AI Monitor"), translate("AI-powered monitoring, reporting and system optimization for OpenWrt."))

-- General Settings
s = m:section(TypedSection, "general", translate("General Settings"))
s.anonymous = true
s.addremove = false

o = s:option(Value, "check_interval", translate("Check Interval"))
o.datatype = "uinteger"
o.default = 300
o.description = translate("Seconds between health checks (default 300 = 5 min)")

-- AI Settings
s = m:section(TypedSection, "ai", translate("AI Settings"))
s.anonymous = true
s.addremove = false

o = s:option(Value, "api_url", translate("API URL"))
o.default = "https://api.deepseek.com/chat/completions"
o.description = translate("AI API endpoint (DeepSeek, OpenAI compatible)")

o = s:option(Value, "api_key", translate("API Key"))
o.password = true
o.description = translate("Your AI API key. Leave empty to disable AI analysis.")

o = s:option(Value, "model", translate("Model"))
o.default = "deepseek-chat"
o.description = translate("Model name (deepseek-chat, gpt-4o-mini, etc.)")

-- Thresholds
s = m:section(TypedSection, "thresholds", translate("Alert Thresholds"))
s.anonymous = true
s.addremove = false

o = s:option(Value, "cpu", translate("CPU (%)"))
o.datatype = "range(0,100)"
o.default = 80

o = s:option(Value, "memory", translate("Memory (%)"))
o.datatype = "range(0,100)"
o.default = 85

o = s:option(Value, "disk", translate("Disk (%)"))
o.datatype = "range(0,100)"
o.default = 90

o = s:option(Value, "temperature", translate("Temperature (C)"))
o.datatype = "range(0,150)"
o.default = 75

-- Push Settings
s = m:section(TypedSection, "push", translate("Push Notifications"))
s.anonymous = true
s.addremove = false

o = s:option(ListValue, "type", translate("Push Type"))
o:value("none", translate("Disabled"))
o:value("serverchan", translate("ServerChan"))
o:value("telegram", translate("Telegram"))
o.default = "none"

o = s:option(Value, "token", translate("Push Token"))
o.password = true
o.description = translate("ServerChan SCKEY or Telegram Bot Token")

o = s:option(Value, "telegram_chat_id", translate("Telegram Chat ID"))
o.description = translate("Required for Telegram push")

-- Report Settings
s = m:section(TypedSection, "report", translate("Report Settings"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "push_enabled", translate("Push Reports"))
o.default = 1
o.description = translate("Send reports via push notification")

o = s:option(Value, "daily_hour", translate("Daily Report Hour"))
o.datatype = "range(0,23)"
o.default = 8
o.description = translate("Hour to generate daily report (0-23)")

o = s:option(Value, "weekly_day", translate("Weekly Report Day"))
o.datatype = "range(1,7)"
o.default = 1
o.description = translate("Day for weekly report (1=Mon, 7=Sun)")

o = s:option(Value, "weekly_hour", translate("Weekly Report Hour"))
o.datatype = "range(0,23)"
o.default = 8

-- Optimize Settings
s = m:section(TypedSection, "optimize", translate("Auto-Optimization"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "auto_enabled", translate("Enable Auto-Optimize"))
o.default = 0
o.description = translate("Automatically optimize system (drop caches, clean logs, kill hung processes)")

o = s:option(Value, "interval", translate("Optimize Interval"))
o.datatype = "uinteger"
o.default = 3600
o.description = translate("Seconds between optimization runs (default 3600 = 1 hour)")

return m
