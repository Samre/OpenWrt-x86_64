#!/bin/sh
# AI Butler - Intelligent system monitoring, analysis & notification
# Powered by Netdata API + LLM

ND_URL="http://localhost:19999"

[ -f /etc/ai-monitor.conf ] && . /etc/ai-monitor.conf

AI_API_KEY="${AI_API_KEY:-}"
AI_API_URL="${AI_API_URL:-https://api.deepseek.com/chat/completions}"
AI_MODEL="${AI_MODEL:-deepseek-chat}"
PUSH_TYPE="${PUSH_TYPE:-none}"
PUSH_TOKEN="${PUSH_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# ── System snapshot from Netdata ──
snapshot() {
    python3 -c "
import json,urllib.request,sys
base='${ND_URL}/api/v1'
charts={
    'cpu':     'system.cpu',
    'ram':     'system.ram',
    'disk':    'disk_space._',
    'temp':    'sensors.temperature_*',
    'net':     'net.*',
    'uptime':  'system.uptime',
    'load':    'system.load',
    'processes':'system.processes',
    'ipv4_conn':'ipv4.sockstat_sockets',
}
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

# Traffic (MB/s rate estimate from net chart)
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

# ── Get active alarms from Netdata ──
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

# ── AI Butler: comprehensive system analysis ──
ai_butler() {
    local mode="${1:-check}"
    local snap=$(snapshot)
    local alarms=$(get_alarms)
    
    [ -z "$snap" ] && { echo "Netdata unreachable"; return 1; }
    
    local cpu=$(echo "$snap" | python3 -c "import sys,json;print(json.load(sys.stdin)['cpu'])")
    local ram=$(echo "$snap" | python3 -c "import sys,json;print(json.load(sys.stdin)['ram'])")
    local disk=$(echo "$snap" | python3 -c "import sys,json;print(json.load(sys.stdin)['disk'])")
    local temp=$(echo "$snap" | python3 -c "import sys,json;print(json.load(sys.stdin)['temp'])")
    local load=$(echo "$snap" | python3 -c "import sys,json;print(json.load(sys.stdin)['load'])")
    local procs=$(echo "$snap" | python3 -c "import sys,json;print(json.load(sys.stdin)['processes'])")
    local conns=$(echo "$snap" | python3 -c "import sys,json;print(json.load(sys.stdin)['conns'])")
    local uptime=$(echo "$snap" | python3 -c "import sys,json;print(json.load(sys.stdin)['uptime_h'])")
    local net_mbps=$(echo "$snap" | python3 -c "import sys,json;print(json.load(sys.stdin)['net_mbps'])")
    
    # Health score (0-100)
    local score=100
    [ "$(echo "$cpu > 80" | bc 2>/dev/null)" = "1" ] && score=$((score-20))
    [ "$(echo "$ram > 85" | bc 2>/dev/null)" = "1" ] && score=$((score-20))
    [ "$(echo "$disk > 90" | bc 2>/dev/null)" = "1" ] && score=$((score-15))
    [ "$(echo "$temp > 70" | bc 2>/dev/null)" = "1" ] && score=$((score-15))
    [ -n "$alarms" ] && score=$((score-15))
    [ $score -lt 0 ] && score=0
    
    local health="🟢"
    [ $score -lt 80 ] && health="🟡"
    [ $score -lt 50 ] && health="🔴"
    
    case "$mode" in
        check)
            # Brief health check
            printf "${health} 健康评分: %d/100 | CPU: %s%% | 内存: %s%% | 磁盘: %s%% | 温度: %s°C\n" \
                "$score" "$cpu" "$ram" "$disk" "$temp"
            printf "运行时间: %.0fh | 进程: %s | 连接: %s | 网络: %.1f Mbps\n" \
                "$uptime" "$procs" "$conns" "$net_mbps"
            [ -n "$alarms" ] && printf "\n⚠️ 告警:\n%s\n" "$alarms"
            ;;
        report)
            # Full report for daily/weekly
            printf "## 🏠 系统健康报告 - %s\n\n" "$(date '+%Y-%m-%d %H:%M')"
            printf "**健康评分: %s %d/100**\n\n" "$health" "$score"
            printf "| 指标 | 当前值 | 状态 |\n|------|--------|------|\n"
            local s="✅"; [ "$(echo "$cpu > 70" | bc 2>/dev/null)" = "1" ] && s="⚠️"; [ "$(echo "$cpu > 90" | bc 2>/dev/null)" = "1" ] && s="🔴"
            printf "| CPU | %s%% | %s |\n" "$cpu" "$s"
            s="✅"; [ "$(echo "$ram > 75" | bc 2>/dev/null)" = "1" ] && s="⚠️"; [ "$(echo "$ram > 90" | bc 2>/dev/null)" = "1" ] && s="🔴"
            printf "| 内存 | %s%% | %s |\n" "$ram" "$s"
            s="✅"; [ "$(echo "$disk > 85" | bc 2>/dev/null)" = "1" ] && s="⚠️"; [ "$(echo "$disk > 95" | bc 2>/dev/null)" = "1" ] && s="🔴"
            printf "| 磁盘 | %s%% | %s |\n" "$disk" "$s"
            printf "| 温度 | %s°C | %s |\n" "$temp" "$([ "$(echo "$temp > 65" | bc 2>/dev/null)" = "1" ] && echo '⚠️' || echo '✅')"
            printf "| 网络 | %.1f Mbps | -\n" "$net_mbps"
            printf "| 进程 | %s | -\n" "$procs"
            printf "| 连接数 | %s | -\n" "$conns"
            printf "| 运行时间 | %.0f h | -\n" "$uptime"
            [ -n "$alarms" ] && printf "\n### ⚠️ 活动告警\n%s\n" "$alarms"
            ;;
    esac
}

# ── AI deep analysis ──
ai_deep_analysis() {
    [ -z "$AI_API_KEY" ] || [ "$AI_API_KEY" = "***" ] && { echo "AI未配置"; return; }
    
    local snap=$(snapshot)
    local alarms=$(get_alarms)
    local report=$(ai_butler report)
    
    local prompt="你是 OpenWrt 软路由的 AI 管家。根据以下系统数据进行分析：

$report

活动告警:
${alarms:-无}

请用中文回复（100字以内）：
1. 系统整体状态如何
2. 有没有需要关注的问题
3. 给出1-2条实用的优化建议"

    curl -s --connect-timeout 10 -m 30 \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${AI_API_KEY}" \
        -d "$(python3 -c "import json; print(json.dumps({'model':'${AI_MODEL}','messages':[{'role':'system','content':'你是一个专业的OpenWrt路由器管家，会主动发现系统问题并给出实用建议。回复要简洁直接，用中文。'},{'role':'user','content':'${prompt}'}],'max_tokens':300,'temperature':0.5}))")" \
        "$AI_API_URL" 2>/dev/null | \
        sed -n 's/.*"content"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# ── Smart notification dispatcher ──
smart_notify() {
    local level="${1:-info}" msg="$2"
    [ -z "$PUSH_TOKEN" ] || [ "$PUSH_TYPE" = "none" ] && return
    
    local title="🏠 路由器管家"
    case "$level" in
        critical) title="🚨 $title - 严重告警" ;;
        warning)  title="⚠️ $title - 警告" ;;
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

# ── Proactive health monitor (for cron/daemon) ──
health_monitor() {
    local snap=$(snapshot)
    local cpu=$(echo "$snap" | python3 -c "import sys,json;print(json.load(sys.stdin)['cpu'])")
    local ram=$(echo "$snap" | python3 -c "import sys,json;print(json.load(sys.stdin)['ram'])")
    local disk=$(echo "$snap" | python3 -c "import sys,json;print(json.load(sys.stdin)['disk'])")
    local temp=$(echo "$snap" | python3 -c "import sys,json;print(json.load(sys.stdin)['temp'])")
    
    local alerts=""
    [ "$(echo "$cpu > 90" | bc 2>/dev/null)" = "1" ] && alerts="$alerts\n- CPU 使用率 ${cpu}%（严重）"
    [ "$(echo "$cpu > 75" | bc 2>/dev/null)" = "1" ] && [ "$(echo "$cpu <= 90" | bc 2>/dev/null)" = "1" ] && alerts="$alerts\n- CPU 使用率 ${cpu}%（偏高）"
    [ "$(echo "$ram > 90" | bc 2>/dev/null)" = "1" ] && alerts="$alerts\n- 内存使用率 ${ram}%（严重）"
    [ "$(echo "$disk > 95" | bc 2>/dev/null)" = "1" ] && alerts="$alerts\n- 磁盘使用率 ${disk}%（严重）"
    [ "$(echo "$temp > 75" | bc 2>/dev/null)" = "1" ] && alerts="$alerts\n- 温度 ${temp}°C（过高）"
    
    if [ -n "$alerts" ]; then
        local level="warning"
        echo "$alerts" | grep -q "严重" && level="critical"
        local ai_advice=$(ai_deep_analysis 2>/dev/null)
        local msg="$(ai_butler check)\n\n⚠️ 检测到问题:$alerts"
        [ -n "$ai_advice" ] && msg="$msg\n\n🤖 AI建议: $ai_advice"
        smart_notify "$level" "$msg"
    fi
}

# ── CLI interface ──
case "${1:-}" in
    check)      ai_butler check ;;        # 快速健康检查
    report)     ai_butler report ;;        # 完整报告
    analyze)    ai_deep_analysis ;;        # AI 深度分析
    monitor)    health_monitor ;;          # 主动告警检查
    notify)     smart_notify "${2:-info}" "${3:-}" ;;  # 手动推送
    *)
        echo "AI Butler - 路由器智能管家"
        echo "  check    - 快速健康检查"
        echo "  report   - 完整健康报告"
        echo "  analyze  - AI 深度分析"
        echo "  monitor  - 主动告警（适合 cron）"
        ;;
esac
