#!/bin/sh
# Report Generator - daily/weekly reports with charts and scheduled push

DATA_DIR="/var/lib/ai-monitor"
DB="$DATA_DIR/metrics.db"
REPORT_DIR="/tmp/ai-monitor-reports"

. /usr/lib/ai-monitor/collector.sh 2>/dev/null || . /usr/bin/ai-monitor-lib-collector.sh 2>/dev/null
[ -f /etc/ai-monitor.conf ] && . /etc/ai-monitor.conf

PUSH_TYPE="${PUSH_TYPE:-none}"
PUSH_TOKEN="${PUSH_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
AI_API_KEY="${AI_API_KEY:-}"
AI_API_URL="${AI_API_URL:-https://api.deepseek.com/chat/completions}"
AI_MODEL="${AI_MODEL:-deepseek-chat}"
REPORT_TO_PUSH="${REPORT_TO_PUSH:-1}"

query_range() {
    local since=$1 metric=$2
    case "$metric" in
        cpu)    sqlite3 "$DB" "SELECT ts,cpu FROM metrics WHERE ts >= $since ORDER BY ts;" 2>/dev/null ;;
        mem)    sqlite3 "$DB" "SELECT ts,mem FROM metrics WHERE ts >= $since ORDER BY ts;" 2>/dev/null ;;
        disk)   sqlite3 "$DB" "SELECT ts,disk FROM metrics WHERE ts >= $since ORDER BY ts;" 2>/dev/null ;;
        temp)   sqlite3 "$DB" "SELECT ts,temp FROM metrics WHERE ts >= $since ORDER BY ts;" 2>/dev/null ;;
        traffic) sqlite3 "$DB" "SELECT ts,rx_bytes,tx_bytes FROM metrics WHERE ts >= $since ORDER BY ts;" 2>/dev/null ;;
        clients) sqlite3 "$DB" "SELECT ts,clients FROM metrics WHERE ts >= $since ORDER BY ts;" 2>/dev/null ;;
        load)   sqlite3 "$DB" "SELECT ts,load1,load5,load15 FROM metrics WHERE ts >= $since ORDER BY ts;" 2>/dev/null ;;
        conns)  sqlite3 "$DB" "SELECT ts,conns FROM metrics WHERE ts >= $since ORDER BY ts;" 2>/dev/null ;;
    esac
}

query_stats() {
    local since=$1
    sqlite3 "$DB" "SELECT ROUND(AVG(cpu),1),MAX(cpu),ROUND(AVG(mem),1),MAX(mem),ROUND(AVG(disk),1),MAX(disk),ROUND(AVG(temp),1),MAX(temp),ROUND(AVG(clients),1),MAX(clients),MAX(processes),MAX(conns),COUNT(*) FROM metrics WHERE ts >= $since;" 2>/dev/null
}

get_peak_traffic() {
    local since=$1
    sqlite3 "$DB" "SELECT ROUND(MAX(rx_bytes)/1073741824.0,2),ROUND(MAX(tx_bytes)/1073741824.0,2) FROM metrics WHERE ts >= $since;" 2>/dev/null
}

get_alerts() {
    local since=$1
    sqlite3 "$DB" "SELECT ts,type,message FROM alerts WHERE ts >= $since ORDER BY ts DESC LIMIT 20;" 2>/dev/null
}

generate_text_report() {
    local period=$1 now=$(date +%s) since emoji title
    case "$period" in
        daily)  since=$((now-86400));  emoji="report"; title="Daily" ;;
        weekly) since=$((now-604800)); emoji="report"; title="Weekly" ;;
        *)      since=$((now-86400));  emoji="report"; title="Report" ;;
    esac
    local stats=$(query_stats $since)
    printf "%s Report - %s\n" "$title" "$(date '+%Y-%m-%d')"
    printf "CPU: Avg %s%% | Max %s%%\n" "$(echo "$stats"|cut -d'|' -f1)" "$(echo "$stats"|cut -d'|' -f2)"
    printf "MEM: Avg %s%% | Max %s%%\n" "$(echo "$stats"|cut -d'|' -f3)" "$(echo "$stats"|cut -d'|' -f4)"
    printf "DISK: Avg %s%% | Max %s%%\n" "$(echo "$stats"|cut -d'|' -f5)" "$(echo "$stats"|cut -d'|' -f6)"
    printf "TEMP: Avg %sC | Max %sC\n" "$(echo "$stats"|cut -d'|' -f7)" "$(echo "$stats"|cut -d'|' -f8)"
    printf "CLIENTS: Avg %s | Max %s\n" "$(echo "$stats"|cut -d'|' -f9)" "$(echo "$stats"|cut -d'|' -f10)"
    printf "SAMPLES: %s\n" "$(echo "$stats"|cut -d'|' -f13)"
    local alerts=$(get_alerts $since | head -3)
    [ -n "$alerts" ] && { printf "\n--- ALERTS ---\n"; echo "$alerts" | while IFS='|' read -r ts type msg; do printf "[%s] %s\n" "$(date -d @$ts '+%H:%M')" "$msg"; done; }
}

generate_html_report() {
    local period=$1 now=$(date +%s) since title
    case "$period" in
        daily)  since=$((now-86400));  title="Daily Report - $(date '+%Y-%m-%d')" ;;
        weekly) since=$((now-604800)); title="Weekly Report - $(date '+%Y-%m-%d')" ;;
        *)      since=$((now-86400));  title="Report - $(date '+%Y-%m-%d')" ;;
    esac
    mkdir -p "$REPORT_DIR"
    local rf="$REPORT_DIR/report_${period}_$(date +%Y%m%d_%H%M%S).html"
    local stats=$(query_stats $since)
    local ac=$(echo "$stats"|cut -d'|' -f1) mc=$(echo "$stats"|cut -d'|' -f2)
    local am=$(echo "$stats"|cut -d'|' -f3) mm=$(echo "$stats"|cut -d'|' -f4)
    local ad=$(echo "$stats"|cut -d'|' -f5) md=$(echo "$stats"|cut -d'|' -f6)
    local at=$(echo "$stats"|cut -d'|' -f7) mt=$(echo "$stats"|cut -d'|' -f8)
    local acl=$(echo "$stats"|cut -d'|' -f9) mcl=$(echo "$stats"|cut -d'|' -f10)
    local mproc=$(echo "$stats"|cut -d'|' -f11) mconn=$(echo "$stats"|cut -d'|' -f12)
    local sp=$(echo "$stats"|cut -d'|' -f13)
    cat > "$rf" <<HTMLEOF
<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$title</title><style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#0d1117;color:#c9d1d9;padding:20px}
h1{color:#58a6ff;margin-bottom:4px;font-size:22px}
.sub{color:#8b949e;font-size:12px;margin-bottom:16px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px;margin-bottom:16px}
.card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:14px}
.card .label{color:#8b949e;font-size:10px;text-transform:uppercase}
.card .value{font-size:26px;font-weight:700;margin:4px 0}
.card .sub{font-size:11px;color:#8b949e}
.gn{color:#3fb950}.yl{color:#d29922}.rd{color:#f85149}.bl{color:#58a6ff}
.bar-wrap{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:12px;margin-bottom:8px}
.bar-wrap h3{color:#f0f6fc;font-size:13px;margin-bottom:6px}
.bar-row{display:flex;align-items:center;gap:8px;margin:3px 0}
.bar-row .bn{width:55px;font-size:10px;color:#8b949e;text-align:right}
.bar-row .bar{height:16px;border-radius:4px}
.bar-row .bv{font-size:10px;color:#c9d1d9;width:45px}
.bc{background:linear-gradient(90deg,#58a6ff,#79c0ff)}.bm{background:linear-gradient(90deg,#3fb950,#56d364)}
.bd{background:linear-gradient(90deg,#d29922,#e3b341)}.bt{background:linear-gradient(90deg,#f85149,#ff7b72)}
.chart{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:14px;margin-bottom:10px}
.chart h3{color:#f0f6fc;font-size:13px;margin-bottom:8px}
.chart svg{width:100%;height:200px}
.footer{margin-top:20px;text-align:center;font-size:10px;color:#484f58}
</style></head><body>
<h1>$title</h1><p class="sub">Samples: ${sp:-N/A} | Generated: $(date '+%Y-%m-%d %H:%M:%S')</p>
<div class="grid">
<div class="card"><div class="label">Avg CPU</div><div class="value bl">${ac:-0}%</div><div class="sub">Max ${mc:-0}%</div></div>
<div class="card"><div class="label">Avg Memory</div><div class="value gn">${am:-0}%</div><div class="sub">Max ${mm:-0}%</div></div>
<div class="card"><div class="label">Disk Usage</div><div class="value yl">${ad:-0}%</div><div class="sub">Max ${md:-0}%</div></div>
<div class="card"><div class="label">Temperature</div><div class="value rd">${at:-0}C</div><div class="sub">Max ${mt:-0}C</div></div>
<div class="card"><div class="label">Clients</div><div class="value bl">${acl:-0}</div><div class="sub">Max ${mcl:-0}</div></div>
<div class="card"><div class="label">Peak Conns</div><div class="value gn">${mconn:-0}</div><div class="sub">Processes ${mproc:-0}</div></div>
</div>
<div class="bar-wrap"><h3>CPU Avg</h3><div class="bar-row"><span class="bn">CPU</span><div class="bar bc" style="width:${ac:-0}%"></div><span class="bv">${ac:-0}%</span></div></div>
<div class="bar-wrap"><h3>Memory Avg</h3><div class="bar-row"><span class="bn">MEM</span><div class="bar bm" style="width:${am:-0}%"></div><span class="bv">${am:-0}%</span></div></div>
<div class="bar-wrap"><h3>Disk Usage</h3><div class="bar-row"><span class="bn">DISK</span><div class="bar bd" style="width:${ad:-0}%"></div><span class="bv">${ad:-0}%</span></div></div>
<div class="footer">AI Monitor for OpenWrt | $title</div>
</body></html>
HTMLEOF
    echo "$rf"
}

generate_chart_json() {
    local since=$1
    # Helper: read query_range output into JSON array
    _build_array() {
        local first=1
        while IFS='|' read -r ts val; do
            [ -z "$ts" ] && continue
            [ $first -eq 0 ] && printf ','
            printf '{"t":%s,"v":%s}' "$ts" "${val:-0}"
            first=0
        done
    }

    # CPU
    local cpu_json=$(query_range $since cpu | _build_array)
    # Memory
    local mem_json=$(query_range $since mem | _build_array)
    # Temperature
    local temp_json=$(query_range $since temp | _build_array)
    # Disk
    local disk_json=$(query_range $since disk | _build_array)
    # Network - convert bytes to MB for chart readability
    local rx_json="" tx_json="" first=1
    while IFS='|' read -r ts rx tx; do
        [ -z "$ts" ] && continue
        [ $first -eq 0 ] && { rx_json="$rx_json,"; tx_json="$tx_json,"; }
        local rx_mb=$(awk "BEGIN{printf \"%.1f\",${rx:-0}/1048576}")
        local tx_mb=$(awk "BEGIN{printf \"%.1f\",${tx:-0}/1048576}")
        rx_json="$rx_json{\"t\":$ts,\"v\":$rx_mb}"
        tx_json="$tx_json{\"t\":$ts,\"v\":$tx_mb}"
        first=0
    done <<NETEOF
$(query_range $since traffic)
NETEOF

    printf '{"cpu":[%s],"mem":[%s],"temp":[%s],"disk":[%s],"rx":[%s],"tx":[%s]}\n' \
        "$cpu_json" "$mem_json" "$temp_json" "$disk_json" "$rx_json" "$tx_json"
}

push_report() {
    local msg="$1"
    [ "$REPORT_TO_PUSH" != "1" ] && return
    [ -z "$PUSH_TOKEN" ] && return
    case "$PUSH_TYPE" in
        serverchan)
            curl -s --connect-timeout 5 -m 10 "https://sctapi.ftqq.com/${PUSH_TOKEN}.send?title=AI%20Monitor%20Report&desp=$(echo "$msg"|python3 -c "import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read()))" 2>/dev/null||echo "$msg")" >/dev/null 2>&1 ;;
        telegram)
            curl -s --connect-timeout 5 -m 10 "https://api.telegram.org/bot${PUSH_TOKEN}/sendMessage" -d "chat_id=$TELEGRAM_CHAT_ID" -d "text=$(echo "$msg"|head -10)" -d "parse_mode=HTML" >/dev/null 2>&1 ;;
    esac
}

ai_summary() {
    local period=$1 now=$(date +%s) since
    case "$period" in daily) since=$((now-86400)) ;; weekly) since=$((now-604800)) ;; *) since=$((now-86400)) ;; esac
    [ -z "$AI_API_KEY" ] || [ "$AI_API_KEY" = "***" ] && return
    local stats=$(query_stats $since)
    local ac=$(echo "$stats"|cut -d'|' -f1) am=$(echo "$stats"|cut -d'|' -f3)
    local al=$(get_alerts $since|wc -l)
    local hrs=$(((now-since)/3600))
    local prompt="OpenWrt ${hrs}h report: CPU avg ${ac}%, Memory avg ${am}%, ${al} alerts. Give a brief summary and advice (under 50 words)."
    curl -s --connect-timeout 10 -m 30 -H "Content-Type: application/json" -H "Authorization: Bearer ***" -d "{\"model\":\"$AI_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$prompt\"}],\"max_tokens\":150,\"temperature\":0.3}" "$AI_API_URL" 2>/dev/null | grep -o '"content":"[^"]*"'|head -1|sed 's/"content":"//;s/"$//'
}

generate_report() {
    local period="${1:-daily}"
    local tr=$(generate_text_report "$period")
    local ai=""
    if [ -n "$AI_API_KEY" ] && [ "$AI_API_KEY" != "***" ]; then
        ai=$(ai_summary "$period")
        [ -n "$ai" ] && tr="$tr\n\nAI: $ai"
    fi
    generate_html_report "$period" >/dev/null 2>&1
    push_report "$tr"
    echo "$tr"
}

list_reports() { ls -1t "$REPORT_DIR"/report_*.html 2>/dev/null | head -20; }
get_report_content() { cat "$1" 2>/dev/null; }
get_chart_data() {
    local period="${1:-daily}" now=$(date +%s) since
    case "$period" in
        hourly) since=$((now-3600)) ;;
        daily)  since=$((now-86400)) ;;
        weekly) since=$((now-604800)) ;;
        *)      since=$((now-86400)) ;;
    esac
    generate_chart_json $since
}
get_client_list() {
    local now=$(date +%s) since=$((now-86400))
    sqlite3 "$DB" "SELECT mac,ip,hostname,last_seen FROM clients WHERE last_seen>=$since ORDER BY last_seen DESC;" 2>/dev/null
}

case "${1:-}" in
    generate)  generate_report "${2:-daily}" ;;
    html)      generate_html_report "${2:-daily}" ;;
    text)      generate_text_report "${2:-daily}" ;;
    push)      push_report "$(generate_text_report "${2:-daily}")" ;;
    ai)        ai_summary "${2:-daily}" ;;
    list)      list_reports ;;
    chart)     get_chart_data "${2:-daily}" ;;
    stats)     query_stats $(($(date +%s)-${2:-86400})) ;;
    clients)   get_client_list ;;
    *)         generate_report "${2:-daily}" ;;
esac
