#!/bin/sh
# AI Butler - Intelligent system monitoring, analysis & notification
# Powered by Netdata API + LLM
set -e
ND_URL="http://localhost:19999"

[ -f /etc/ai-monitor.conf ] && . /etc/ai-monitor.conf

AI_API_KEY="${AI_API_KEY:-}"
AI_API_URL="${AI_API_URL:-https://api.deepseek.com/chat/completions}"
AI_MODEL="${AI_MODEL:-deepseek-chat}"
PUSH_TYPE="${PUSH_TYPE:-none}"
PUSH_TOKEN="${PUSH_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# ── System snapshot from Netdata (single python3 call) ──
snapshot() {
    python3 -c "
import json,urllib.request,sys
base='${ND_URL}/api/v1'
result={}
def last_val(ch):
    try:
        url=f'{base}/data?chart={ch}&after=-60&points=1&format=json'
        d=json.load(urllib.request.urlopen(url,timeout=5))
        pts=d.get('data',[[]])[0]
        return round(pts[-1][1],1) if pts and pts[-1][1] else 0
    except: return 0
def avg_val(ch,sec=300):
    try:
        url=f'{base}/data?chart={ch}&after=-{sec}&points=0&format=json'
        d=json.load(urllib.request.urlopen(url,timeout=5))
        pts=[p[1] for p in d.get('data',[[]])[0] if p[1] is not None]
        return round(sum(pts)/len(pts),1) if pts else 0
    except: return 0
result['cpu']=avg_val('system.cpu',60)
result['cpu_max']=avg_val('system.cpu',300)
result['ram']=last_val('system.ram')
result['disk']=last_val('disk_space._')
result['temp']=last_val('sensors.temperature_*')
result['uptime_h']=round(last_val('system.uptime')/3600,1)
result['load']=last_val('system.load')
result['processes']=last_val('system.processes')
result['conns']=last_val('ipv4.sockstat_sockets')
try:
    url=f'{base}/data?chart=net.*&after=-60&points=2&format=json'
    d=json.load(urllib.request.urlopen(url,timeout=5))
    pts=d.get('data',[[]])[0]
    if len(pts)>=2:
        result['net_mbps']=round((pts[-1][1]-pts[0][1])*8/60/1024/1024,2) if pts[-1][1] and pts[0][1] else 0
    else: result['net_mbps']=0
except: result['net_mbps']=0
print(json.dumps(result,ensure_ascii=False))
" 2>/dev/null
}

get_alarms() {
    python3 -c "
import json,urllib.request
try:
    d=json.load(urllib.request.urlopen('${ND_URL}/api/v1/alarms?active',timeout=5))
    alarms=[]
    for k,v in d.get('alarms',{}).items():
        if v.get('status') in ('WARNING','CRITICAL'):
            alarms.append(f'{v[\"status\"]}: {k} - {v.get(\"info\",\"\")}')
    print('\n'.join(alarms) if alarms else '')
except: pass
" 2>/dev/null
}

# ── Extract all fields from snapshot in ONE call ──
parse_snap() {
    echo "$1" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for k in ['cpu','ram','disk','temp','load','processes','conns','uptime_h','net_mbps','cpu_max']:
    print(f'{k}={d.get(k,0)}')
" 2>/dev/null
}

# ── Numeric compare using awk (busybox guaranteed, no bc needed) ──
gt() { awk "BEGIN{print ($1>$2)}" 2>/dev/null; }

# ── AI Butler ──
ai_butler() {
    local mode="${1:-check}"
    local snap=$(snapshot)
    local alarms=$(get_alarms)
    [ -z "$snap" ] && { echo "Netdata unreachable"; return 1; }
    
    eval "$(parse_snap "$snap")"
    
    local score=100
    [ "$(gt "$cpu" 80)" = "1" ] && score=$((score-20))
    [ "$(gt "$ram" 85)" = "1" ] && score=$((score-20))
    [ "$(gt "$disk" 90)" = "1" ] && score=$((score-15))
    [ "$(gt "$temp" 70)" = "1" ] && score=$((score-15))
    [ -n "$alarms" ] && score=$((score-15))
    [ $score -lt 0 ] && score=0
    
    local health="🟢"
    [ $score -lt 80 ] && health="🟡"
    [ $score -lt 50 ] && health="🔴"
    
    case "$mode" in
        check)
            printf "${health} Health: %d/100 | CPU: %s%% | RAM: %s%% | Disk: %s%% | Temp: %s°C\n" \
                "$score" "$cpu" "$ram" "$disk" "$temp"
            printf "Uptime: %.0fh | Procs: %s | Conns: %s | Net: %.1f Mbps\n" \
                "$uptime_h" "$processes" "$conns" "$net_mbps"
            [ -n "$alarms" ] && printf "\n⚠️ Alarms:\n%s\n" "$alarms"
            ;;
        report)
            printf "## System Health Report - %s\n\n" "$(date '+%Y-%m-%d %H:%M')"
            printf "**Health Score: %s %d/100**\n\n" "$health" "$score"
            printf "| Metric | Value | Status |\n|------|--------|------|\n"
            local s; s="✅"; [ "$(gt "$cpu" 70)" = "1" ] && s="⚠️"; [ "$(gt "$cpu" 90)" = "1" ] && s="🔴"
            printf "| CPU | %s%% | %s |\n" "$cpu" "$s"
            s="✅"; [ "$(gt "$ram" 75)" = "1" ] && s="⚠️"; [ "$(gt "$ram" 90)" = "1" ] && s="🔴"
            printf "| RAM | %s%% | %s |\n" "$ram" "$s"
            s="✅"; [ "$(gt "$disk" 85)" = "1" ] && s="⚠️"; [ "$(gt "$disk" 95)" = "1" ] && s="🔴"
            printf "| Disk | %s%% | %s |\n" "$disk" "$s"
            printf "| Temp | %s°C | %s |\n" "$temp" "$([ "$(gt "$temp" 65)" = "1" ] && echo '⚠️' || echo '✅')"
            printf "| Net | %.1f Mbps | -\n" "$net_mbps"
            printf "| Procs | %s | -\n" "$processes"
            printf "| Conns | %s | -\n" "$conns"
            printf "| Uptime | %.0f h | -\n" "$uptime_h"
            [ -n "$alarms" ] && printf "\n### ⚠️ Active Alarms\n%s\n" "$alarms"
            ;;
    esac
}

# ── AI deep analysis ──
ai_deep_analysis() {
    [ -z "$AI_API_KEY" ] || [ "$AI_API_KEY" = "***" ] && { echo "AI not configured"; return; }
    
    local snap=$(snapshot)
    eval "$(parse_snap "$snap")"
    local alarms=$(get_alarms)
    
    local prompt="OpenWrt router health report:
CPU: ${cpu}%, RAM: ${ram}%, Disk: ${disk}%, Temp: ${temp}°C
Uptime: ${uptime_h}h, Procs: ${processes}, Net: ${net_mbps} Mbps
Alarms: ${alarms:-none}

Analyze and give brief advice in Chinese (under 80 words):"

    local payload=$(python3 -c "
import json,sys
prompt=sys.argv[1]
print(json.dumps({
    'model':'${AI_MODEL}',
    'messages':[{
        'role':'system',
        'content':'OpenWrt router butler. Be concise, practical, Chinese.'
    },{
        'role':'user',
        'content':prompt
    }],
    'max_tokens':300,
    'temperature':0.5
}))
" "$prompt" 2>/dev/null)

    curl -s --connect-timeout 10 -m 30 \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${AI_API_KEY}" \
        -d "$payload" \
        "$AI_API_URL" 2>/dev/null | \
        sed -n 's/.*"content"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# ── Smart notification ──
smart_notify() {
    local level="${1:-info}" msg="$2"
    [ -z "$PUSH_TOKEN" ] || [ "$PUSH_TYPE" = "none" ] && return
    
    local title="Router Butler"
    case "$level" in
        critical) title="🚨 $title - CRITICAL" ;;
        warning)  title="⚠️ $title - Warning" ;;
        *)        title="ℹ️ $title" ;;
    esac
    
    case "$PUSH_TYPE" in
        serverchan)
            curl -s --connect-timeout 5 -m 10 \
                --data-urlencode "title=$title" \
                --data-urlencode "desp=$msg" \
                "https://sctapi.ftqq.com/${PUSH_TOKEN}.send" >/dev/null 2>&1 ;;
        telegram)
            curl -s --connect-timeout 5 -m 10 \
                "https://api.telegram.org/bot${PUSH_TOKEN}/sendMessage" \
                --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
                --data-urlencode "text=$title%0A%0A$msg" >/dev/null 2>&1 ;;
    esac
}

# ── Proactive health monitor (cron) ──
health_monitor() {
    # Timeout protection: kill self after 55s to prevent cron pileup
    (sleep 55 && kill $$ 2>/dev/null) &
    local watchdog=$!
    
    local snap=$(snapshot)
    [ -z "$snap" ] && { kill $watchdog 2>/dev/null; return 0; }
    
    eval "$(parse_snap "$snap")"
    
    local alerts=""
    [ "$(gt "$cpu" 90)" = "1" ] && alerts="$alerts\n- CPU ${cpu}% (critical)"
    [ "$(gt "$cpu" 75)" = "1" ] && [ "$(gt 90 "$cpu")" = "1" ] && alerts="$alerts\n- CPU ${cpu}% (high)"
    [ "$(gt "$ram" 90)" = "1" ] && alerts="$alerts\n- RAM ${ram}% (critical)"
    [ "$(gt "$disk" 95)" = "1" ] && alerts="$alerts\n- Disk ${disk}% (critical)"
    [ "$(gt "$temp" 75)" = "1" ] && alerts="$alerts\n- Temp ${temp}°C (high)"
    
    if [ -n "$alerts" ]; then
        local level="warning"
        echo "$alerts" | grep -q "critical" && level="critical"
        local ai_advice=$(ai_deep_analysis 2>/dev/null)
        local msg="$(ai_butler check)\n\n⚠️ Detected:$alerts"
        [ -n "$ai_advice" ] && msg="$msg\n\n🤖 AI: $ai_advice"
        smart_notify "$level" "$msg"
    fi
    
    kill $watchdog 2>/dev/null
}

# ── CLI ──
case "${1:-}" in
    check)    ai_butler check ;;
    report)   ai_butler report ;;
    analyze)  ai_deep_analysis ;;
    monitor)  health_monitor ;;
    notify)   smart_notify "${2:-info}" "${3:-}" ;;
    *)
        echo "AI Butler - Router Intelligent Butler"
        echo "  check   - Quick health check"
        echo "  report  - Full health report"
        echo "  analyze - AI deep analysis"
        echo "  monitor - Proactive alert check (for cron)"
        ;;
esac
