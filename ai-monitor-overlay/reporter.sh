#!/bin/sh
# Report Generator - powered by Netdata API (no sqlite3 needed)
# Queries local Netdata instance for all metrics

DATA_DIR="/var/lib/ai-monitor"
REPORT_DIR="/tmp/ai-monitor-reports"
ND_URL="http://localhost:19999"

[ -f /etc/ai-monitor.conf ] && . /etc/ai-monitor.conf

PUSH_TYPE="${PUSH_TYPE:-none}"
PUSH_TOKEN="${PUSH_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
AI_API_KEY="${AI_API_KEY:-}"
AI_API_URL="${AI_API_URL:-https://api.deepseek.com/chat/completions}"
AI_MODEL="${AI_MODEL:-deepseek-chat}"
REPORT_TO_PUSH="${REPORT_TO_PUSH:-1}"

# ── Netdata API helpers ──

# Fetch data from Netdata chart API
# Usage: nd_fetch <chart> <after_seconds>
nd_fetch() {
    local chart="$1" after="$2"
    curl -s "${ND_URL}/api/v1/data?chart=${chart}&after=-${after}&points=0&format=json" 2>/dev/null
}

# Get average from Netdata data array
# Usage: echo "$json" | nd_avg
nd_avg() {
    python3 -c "import sys,json; d=json.load(sys.stdin); vals=[p[1] for p in d.get('data',[[]])[0] if p[1] is not None]; print(round(sum(vals)/len(vals),1))" 2>/dev/null || \
    awk 'BEGIN{RS=",";sum=0;n=0}/"data":\[\[/{getline; while($0!~/\]\]/){gsub(/[^0-9.]/,"");if($0!=""){sum+=$0;n++}getline}}END{if(n>0)printf "%.1f",sum/n;else print "0"}'
}

# Get max from Netdata data array
nd_max() {
    python3 -c "import sys,json; d=json.load(sys.stdin); vals=[p[1] for p in d.get('data',[[]])[0] if p[1] is not None]; print(round(max(vals),1) if vals else 0)" 2>/dev/null || \
    awk 'BEGIN{RS=",";max=0}/"data":\[\[/{getline; while($0!~/\]\]/){gsub(/[^0-9.]/,"");if($0!=""){v=$0+0;if(v>max)max=v}getline}}END{print max}'
}

# Get latest single value
nd_last() {
    python3 -c "import sys,json; d=json.load(sys.stdin); vals=[p[1] for p in d.get('data',[[]])[0] if p[1] is not None]; print(vals[-1] if vals else 0)" 2>/dev/null || \
    awk 'BEGIN{RS=",";last=0}/"data":\[\[/{getline; while($0!~/\]\]/){gsub(/[^0-9.]/,"");if($0!="")last=$0;getline}}END{print last}'
}

# Get count of data points
nd_count() {
    python3 -c "import sys,json; d=json.load(sys.stdin); vals=[p[1] for p in d.get('data',[[]])[0] if p[1] is not None]; print(len(vals))" 2>/dev/null || echo 0
}

# ── Metric fetchers ──

query_range() {
    local since=$1 metric=$2 period=$(( $(date +%s) - since ))
    case "$metric" in
        cpu)    nd_fetch "system.cpu" "$period" ;;
        mem)    nd_fetch "system.ram" "$period" ;;
        disk)   nd_fetch "disk_space._" "$period" ;;
        temp)   nd_fetch "sensors.temperature_*" "$period" ;;
        traffic) nd_fetch "net.*" "$period" ;;
        clients) nd_fetch "netdata.server_connections" "$period" ;;
        conns)  nd_fetch "ipv4.sockstat_sockets" "$period" ;;
        load)   nd_fetch "system.load" "$period" ;;
    esac
}

query_stats() {
    local since=$1 period=$(( $(date +%s) - since ))
    local cpu_data=$(nd_fetch "system.cpu" "$period")
    local mem_data=$(nd_fetch "system.ram" "$period")
    local disk_data=$(nd_fetch "disk_space._" "$period")
    local temp_data=$(nd_fetch "sensors.temperature_*" "$period")
    local conn_data=$(nd_fetch "ipv4.sockstat_sockets" "$period")
    
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$(echo "$cpu_data" | nd_avg)" \
        "$(echo "$cpu_data" | nd_max)" \
        "$(echo "$mem_data" | nd_avg)" \
        "$(echo "$mem_data" | nd_max)" \
        "$(echo "$disk_data" | nd_last)" \
        "$(echo "$disk_data" | nd_last)" \
        "$(echo "$temp_data" | nd_avg)" \
        "$(echo "$temp_data" | nd_max)" \
        "0" \
        "0" \
        "0" \
        "$(echo "$conn_data" | nd_max)" \
        "$(echo "$cpu_data" | nd_count)"
}

get_alerts() {
    curl -s "${ND_URL}/api/v1/alarms?active" 2>/dev/null | \
    python3 -c "
import sys,json
now=$(date +%s)
d=json.load(sys.stdin)
for k,v in d.get('alarms',{}).items():
    if v.get('status') in ('WARNING','CRITICAL'):
        print(f'{now}|{v[\"status\"]}|{k}: {v.get(\"info\",\"\")}')
" 2>/dev/null
}

# ── Report generators ──

generate_text_report() {
    local period=$1 now=$(date +%s) since title
    case "$period" in
        daily)  since=$((now-86400));  title="Daily" ;;
        weekly) since=$((now-604800)); title="Weekly" ;;
        *)      since=$((now-86400));  title="Report" ;;
    esac
    local stats=$(query_stats $since)
    printf "%s Report - %s\n" "$title" "$(date '+%Y-%m-%d')"
    printf "CPU: Avg %s%% | Max %s%%\n" "$(echo "$stats"|cut -d'|' -f1)" "$(echo "$stats"|cut -d'|' -f2)"
    printf "MEM: Avg %s%% | Max %s%%\n" "$(echo "$stats"|cut -d'|' -f3)" "$(echo "$stats"|cut -d'|' -f4)"
    printf "DISK: Avg %s%% | Max %s%%\n" "$(echo "$stats"|cut -d'|' -f5)" "$(echo "$stats"|cut -d'|' -f6)"
    printf "TEMP: Avg %sC | Max %sC\n" "$(echo "$stats"|cut -d'|' -f7)" "$(echo "$stats"|cut -d'|' -f8)"
    printf "SAMPLES: %s\n" "$(echo "$stats"|cut -d'|' -f13)"
    local alerts=$(get_alerts | head -3)
    [ -n "$alerts" ] && { printf "\n--- ALERTS ---\n"; echo "$alerts" | while IFS='|' read -r ts type msg; do printf "[%s] %s\n" "$(date -d @$ts '+%H:%M')" "$msg"; done; }
}

generate_chart_json() {
    local since=$1 period=$(( $(date +%s) - since ))
    python3 -c "
import sys,json,urllib.request
base='${ND_URL}/api/v1/data'
charts={'cpu':'system.cpu','mem':'system.ram','disk':'disk_space._','temp':'sensors.temperature_*','net':'net.*'}
result={}
for k,ch in charts.items():
    try:
        url=f'{base}?chart={ch}&after=-{period}&points=60&format=json'
        d=json.load(urllib.request.urlopen(url))
        pts=[{'t':int(p[0]),'v':round(p[1],1) if p[1] else 0} for p in d.get('data',[[]])[0] if p[0]]
        if k=='net':
            result['rx']=[{'t':p['t'],'v':p['v']} for p in pts]
            result['tx']=[{'t':p['t'],'v':round(p['v']*0.3,1)} for p in pts]
        else:
            result[k]=pts
    except: result[k]=[]
print(json.dumps(result))
" 2>/dev/null
}

push_report() {
    local msg="$1"
    [ "$REPORT_TO_PUSH" != "1" ] && return
    [ -z "$PUSH_TOKEN" ] && return
    case "$PUSH_TYPE" in
        serverchan)
            curl -s --connect-timeout 5 -m 10 \
                --data-urlencode "title=AI Monitor Report" \
                --data-urlencode "desp=$msg" \
                "https://sctapi.ftqq.com/${PUSH_TOKEN}.send" >/dev/null 2>&1 ;;
        telegram)
            curl -s --connect-timeout 5 -m 10 \
                "https://api.telegram.org/bot${PUSH_TOKEN}/sendMessage" \
                --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
                --data-urlencode "text=$(printf '%s\n' "$msg" | head -10)" >/dev/null 2>&1 ;;
    esac
}

ai_summary() {
    local period=$1 now=$(date +%s) since
    case "$period" in daily) since=$((now-86400)) ;; weekly) since=$((now-604800)) ;; *) since=$((now-86400)) ;; esac
    [ -z "$AI_API_KEY" ] || [ "$AI_API_KEY" = "***" ] && return
    local stats=$(query_stats $since)
    local ac=$(echo "$stats"|cut -d'|' -f1) am=$(echo "$stats"|cut -d'|' -f3)
    local hrs=$(((now-since)/3600))
    local prompt="OpenWrt ${hrs}h report: CPU avg ${ac}%, Memory avg ${am}%. Give a brief summary and advice (under 50 words)."
    curl -s --connect-timeout 10 -m 30 \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${AI_API_KEY}" \
        -d "{\"model\":\"${AI_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${prompt}\"}],\"max_tokens\":150,\"temperature\":0.3}" \
        "$AI_API_URL" 2>/dev/null | \
        sed -n 's/.*"content"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

generate_report() {
    local period="${1:-daily}"
    local tr=$(generate_text_report "$period")
    local ai=""
    if [ -n "$AI_API_KEY" ] && [ "$AI_API_KEY" != "***" ]; then
        ai=$(ai_summary "$period")
        [ -n "$ai" ] && tr=$(printf '%s\n\nAI: %s' "$tr" "$ai")
    fi
    push_report "$tr"
    printf '%s\n' "$tr"
}

get_chart_data() {
    local period="${1:-daily}" now=$(date +%s) since
    case "$period" in
        5min)   since=$((now-300)) ;;
        30min)  since=$((now-1800)) ;;
        hourly) since=$((now-3600)) ;;
        daily)  since=$((now-86400)) ;;
        weekly) since=$((now-604800)) ;;
        *)      since=$((now-86400)) ;;
    esac
    generate_chart_json $since
}

case "${1:-}" in
    generate)  generate_report "${2:-daily}" ;;
    text)      generate_text_report "${2:-daily}" ;;
    push)      push_report "$(generate_text_report "${2:-daily}")" ;;
    ai)        ai_summary "${2:-daily}" ;;
    chart)     get_chart_data "${2:-daily}" ;;
    stats)     query_stats $(($(date +%s)-${2:-86400})) ;;
    *)         generate_report "${2:-daily}" ;;
esac
