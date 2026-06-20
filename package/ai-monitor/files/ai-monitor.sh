#!/bin/sh
# AI Monitor for OpenWrt - AI-powered system monitoring with push notifications

CONFIG_FILE="/etc/ai-monitor.conf"
LOG_FILE="/var/log/ai-monitor.log"

AI_API_URL="${AI_API_URL:-https://api.deepseek.com/chat/completions}"
AI_API_KEY="${AI_API_KEY:-sk-your-key-here}"
AI_MODEL="${AI_MODEL:-deepseek-chat}"
PUSH_TOKEN="${PUSH_TOKEN:-}"
PUSH_TYPE="${PUSH_TYPE:-serverchan}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
CHECK_INTERVAL="${CHECK_INTERVAL:-600}"
CPU_THRESHOLD="${CPU_THRESHOLD:-80}"
MEM_THRESHOLD="${MEM_THRESHOLD:-85}"
DISK_THRESHOLD="${DISK_THRESHOLD:-90}"
TEMP_THRESHOLD="${TEMP_THRESHOLD:-75}"

log_msg() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; echo "$1"; }

collect_stats() {
    CPU=$(top -bn1 2>/dev/null | grep "CPU:" | awk '{print $2}' | sed 's/%//')
    [ -z "$CPU" ] && CPU=$(cat /proc/loadavg | awk '{printf "%.0f", $1*100}')
    MEM=$(free | grep Mem | awk '{printf "%.0f", $3/$2*100}')
    DISK=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
    TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.0f", $1/1000}')
    [ -z "$TEMP" ] && TEMP="N/A"
    UPTIME=$(awk '{printf "%.0f", $1/86400}' /proc/uptime)
    CONNS=$(cat /proc/net/nf_conntrack 2>/dev/null | wc -l)
}

detect_anomalies() {
    ALERTS=""
    [ "${CPU%.*}" -gt "$CPU_THRESHOLD" ] 2>/dev/null && ALERTS="$ALERTS\n- CPU ${CPU}% (limit ${CPU_THRESHOLD}%)"
    [ "${MEM%.*}" -gt "$MEM_THRESHOLD" ] 2>/dev/null && ALERTS="$ALERTS\n- MEM ${MEM}% (limit ${MEM_THRESHOLD}%)"
    [ "${DISK%.*}" -gt "$DISK_THRESHOLD" ] 2>/dev/null && ALERTS="$ALERTS\n- DISK ${DISK}% (limit ${DISK_THRESHOLD}%)"
    [ "${TEMP%.*}" -gt "$TEMP_THRESHOLD" ] 2>/dev/null && ALERTS="$ALERTS\n- TEMP ${TEMP}C (limit ${TEMP_THRESHOLD}C)"
    echo "$ALERTS"
}

ask_ai() {
    [ "$AI_API_KEY" = "sk-your-key-here" ] && return 1
    [ -z "$AI_API_KEY" ] && return 1
    local resp=$(curl -s --connect-timeout 10 -m 30 -H "Content-Type: application/json" -H "Authorization: Bearer $AI_API_KEY" -d "{\"model\":\"$AI_MODEL\",\"messages\":[{\"role\":\"system\",\"content\":\"OpenWrt AI运维助手，简洁中文回答，限制100字。\"},{\"role\":\"user\",\"content\":\"$1\"}],\"max_tokens\":200,\"temperature\":0.3}" "$AI_API_URL" 2>/dev/null)
    echo "$resp" | grep -o '"content":"[^"]*"' | head -1 | sed 's/"content":"//;s/"//' | sed 's/\\n/\n/g'
}

push_notify() {
    local title="$1" msg="$2"
    [ -z "$PUSH_TOKEN" ] && return
    case "$PUSH_TYPE" in
        serverchan)
            curl -s --connect-timeout 5 -m 10 "https://sctapi.ftqq.com/${PUSH_TOKEN}.send?title=$title&desp=$msg" >/dev/null 2>&1 ;;
        telegram)
            curl -s --connect-timeout 5 -m 10 "https://api.telegram.org/bot${PUSH_TOKEN}/sendMessage" -d "chat_id=$TELEGRAM_CHAT_ID" -d "text=$title%0A$msg" -d "parse_mode=HTML" >/dev/null 2>&1 ;;
    esac
}

run_check() {
    collect_stats
    local stats=$(printf "CPU:%s%% MEM:%s%% DISK:%s%% TEMP:%sC UPTIME:%sd CONNS:%s" "$CPU" "$MEM" "$DISK" "$TEMP" "$UPTIME" "$CONNS")
    log_msg "[CHECK] $stats"

    local alerts=$(detect_anomalies)
    if [ -n "$alerts" ]; then
        log_msg "[ALERT] $alerts"
        local prompt=$(printf "OpenWrt状态：%s。异常：%s。请分析原因并给出处理建议。" "$stats" "$alerts")
        local ai_advice=$(ask_ai "$prompt")
        local notify_msg=$(printf "Router Alert\n\n%s\n\n%s" "$stats" "$alerts")
        [ -n "$ai_advice" ] && notify_msg="$notify_msg\n\nAI: $ai_advice"
        push_notify "Router Alert" "$notify_msg"
    fi
}

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

case "${1:-}" in
    --once) run_check ;;
    --test)
        collect_stats
        echo "CPU=${CPU}% MEM=${MEM}% DISK=${DISK}% TEMP=${TEMP}C UPTIME=${UPTIME}d CONNS=${CONNS}"
        detect_anomalies
        echo "Testing AI..."
        ask_ai "OpenWrt CPU 85%, MEM 70%, suggestions?" && echo "" || echo "AI not configured"
        ;;
    *)  log_msg "[START] AI Monitor daemon"
        while true; do run_check; sleep "$CHECK_INTERVAL"; done ;;
esac
