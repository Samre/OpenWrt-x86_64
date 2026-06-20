local m, s, o

m = Map("ai-monitor", translate("AI Monitor Settings"),
    translate("AI-powered system monitoring with push notifications"))

s = m:section(NamedSection, "general", "ai-monitor", translate("General"))
o = s:option(Value, "check_interval", translate("Check Interval (s)"))
o.default = "600"; o.datatype = "uinteger"

s = m:section(NamedSection, "ai", "ai-monitor", translate("AI Settings"))
o = s:option(Value, "api_key", translate("API Key")); o.password = true
o = s:option(Value, "api_url", translate("API URL"))
o.default = "https://api.deepseek.com/chat/completions"
o = s:option(Value, "model", translate("Model"))
o.default = "deepseek-chat"
o:value("deepseek-chat", "DeepSeek V3")
o:value("deepseek-reasoner", "DeepSeek R1")
o:value("gpt-4o-mini", "OpenAI GPT-4o-mini")

s = m:section(NamedSection, "push", "ai-monitor", translate("Push Notification"))
o = s:option(ListValue, "type", translate("Push Type"))
o:value("serverchan", "ServerChan (WeChat)")
o:value("telegram", "Telegram Bot")
o:value("none", "Disabled")
o = s:option(Value, "token", translate("Push Token")); o.password = true
o:depends("type", "serverchan"); o:depends("type", "telegram")
o = s:option(Value, "telegram_chat_id", translate("Telegram Chat ID"))
o:depends("type", "telegram")

s = m:section(NamedSection, "thresholds", "ai-monitor", translate("Alert Thresholds"))
o = s:option(Value, "cpu", translate("CPU (%)"))
o.default = "80"; o.datatype = "range(0,100)"
o = s:option(Value, "memory", translate("Memory (%)"))
o.default = "85"; o.datatype = "range(0,100)"
o = s:option(Value, "disk", translate("Disk (%)"))
o.default = "90"; o.datatype = "range(0,100)"
o = s:option(Value, "temperature", translate("Temperature (C)"))
o.default = "75"; o.datatype = "range(0,120)"

return m
