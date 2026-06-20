#!/bin/sh
# AI Monitor for OpenWrt v2 - AI-powered monitoring, reporting, and optimization
# Orchestrates: collector, reporter, optimizer modules

CONFIG_FILE="/etc/ai-monitor.conf"
LOG_FILE="/var/log/ai-monitor.log"
LIB_DIR="/usr/lib/ai-monitor"
STATE_DIR="/var/lib/ai-monitor"
STATE_FILE="$STATE_DIR/daemon.state"

# Defaults (overridden by config)
CHECK_INTERVAL="${CHECK_INTERVAL:-300}"
AI_API_URL="${AI_API_URL:-https://api.deepseek.com/chat/completions}"
AI_API_KEY="${AI_API_KEY:-}"
AI_MODEL="${AI_MODEL:-deepseek-chat}"
PUSH_TYPE="${PUSH_TYPE:-none}"
PUSH_TOKEN="${PUSH_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
CPU_THRESHOLD="${CPU_THRESHOLD:-80}"
MEM_THRESHOLD="${MEM_THRESHOLD:-85}"
DISK_THRESHOLD="${DISK_THRESHOLD:-90}"
TEMP_THRESHOLD="${TEMP_THRESHOLD:-75}"
REPORT_TO_PUSH="${REPORT_TO_PUSH:-1}"
AUTO_OPTIMIZE="${AUTO_OPTIMIZE:-0}"
OPTIMIZE_INTERVAL="${OPTIMIZE_INTERVAL:-3600}"
REPORT_DAILY_HOUR="${REPORT_DAILY_HOUR:-8}"
REPORT_WEEKLY_DAY="${REPORT_WEEKLY_DAY:-1}"
REPORT_WEEKLY_HOUR="${REPORT_WEEKLY_HOUR:-8}"

# Source lib modules
for lib in "$LIB_DIR"/collector.sh "$LIB_DIR"/reporter.sh "$LIB_DIR"/optimizer.sh; do
    [ -f "$lib" ] && . "$lib"
done

log_msg() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; echo "$1"; }

# State management
load_state() {
    mkdir -p "$STATE_DIR"
    touch "$STATE_FILE"
    . "$STATE_FILE" 2>/dev/null
    LAST_REPORT_DAILY="${LAST_REPORT_DAILY:-0}"
    LAST_REPORT_WEEKLY="${LAST_REPORT_WEEKLY:-0}"
    LAST_OPTIMIZE="${LAST_OPTIMIZE:-0}"
}

save_state() {
    cat > "$STATE_FILE" <<EOF
LAST_REPORT_DAILY=$LAST_REPORT_DAILY
LAST_REPORT_WEEKLY=$LAST_REPORT_WEEKLY
LAST_OPTIMIZE=$LAST_OPTIMIZE
EOF
}

# Collect system stats
collect_stats() {
    CPU=$(collect_cpu)
    MEM=$(collect_mem)
    DISK=$(collect_disk)
    TEMP=$(collect_temp)
    TRAFFIC=$(collect_traffic)
    RX=$(echo "$TRAFFIC" | awk '{print $1}')
    TX=$(echo "$TRAFFIC" | awk '{print $2}')
    CONNS=$(collect_connections)
    PROC=$(collect_processes)
    CLIENTS=$(collect_clients)
    LOAD=$(collect_load)
    UPTIME=$(awk '{printf "%.0f", $1/86400}' /proc/uptime)
}

# Detect anomalies
detect_anomalies() {
    ALERTS=""
    [ "${CPU%.*}" -gt "$CPU_THRESHOLD" ] 2>/dev/null && ALERTS="$ALERTS\n- CPU ${CPU}% (threshold ${CPU_THRESHOLD}%)"
    [ "${MEM%.*}" -gt "$MEM_THRESHOLD" ] 2>/dev/null && ALERTS="$ALERTS\n- Memory ${MEM}% (threshold ${MEM_THRESHOLD}%)"
    [ "${DISK%.*}" -gt "$DISK_THRESHOLD" ] 2>/dev/null && ALERTS="$ALERTS\n- Disk ${DISK}% (threshold ${DISK_THRESHOLD}%)"
    [ "${TEMP%.*}" -gt "$TEMP_THRESHOLD" ] 2>/dev/null && ALERTS="$ALERTS\n- Temperature ${TEMP}C (threshold ${TEMP_THRESHOLD}C)"
    echo "$ALERTS"
}

# AI analysis for alerts
ask_ai() {
    [ -z "$AI_API_KEY" ] || [ "$AI_API_KEY" = "sk-your-key-here" ] && return 1
    local resp=$(curl -s --connect-timeout 10 -m 30 \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AI_API_KEY" \
        -d "{\"model\":\"$AI_MODEL\",\"messages\":[{\"role\":\"system\",\"content\":\"OpenWrt AI assistant. Reply in Chinese, under 100 chars.\"},{\"role\":\"user\",\"content\":\"$1\"}],\"max_tokens\":200,\"temperature\":0.3}" \
        "$AI_API_URL" 2>/dev/null)
    echo "$resp" | grep -o '"content":"[^"]*"' | head -1 | sed 's/"content":"//;s/"//' | sed 's/\\n/ /g'
}

# Push notification
push_notify() {
    local title="$1" msg="$2"
    [ -z "$PUSH_TOKEN" ] || [ "$PUSH_TYPE" = "none" ] && return
    case "$PUSH_TYPE" in
        serverchan)
            curl -s --connect-timeout 5 -m 10 \
                "https://sctapi.ftqq.com/${PUSH_TOKEN}.send?title=$(echo "$title"|sed 's/ /%20/g')&desp=$(echo "$msg"|sed 's/ /%20/g;s/\n/%0A/g')" \
                >/dev/null 2>&1 ;;
        telegram)
            curl -s --connect-timeout 5 -m 10 \
                "https://api.telegram.org/bot${PUSH_TOKEN}/sendMessage" \
                -d "chat_id=$TELEGRAM_CHAT_ID" -d "text=$(echo "$title\n\n$msg"|head -15)" \
                -d "parse_mode=HTML" >/dev/null 2>&1 ;;
    esac
}

# Check if we should run daily report
should_daily_report() {
    local now=$(date +%s) today=$(date +%Y%m%d) hour=$(date +%H)
    [ "$hour" != "$REPORT_DAILY_HOUR" ] && return 1
    [ "$LAST_REPORT_DAILY" = "$today" ] && return 1
    return 0
}

# Check if we should run weekly report
should_weekly_report() {
    local now=$(date +%s) week=$(date +%Y%W) hour=$(date +%H) day=$(date +%u)
    [ "$day" != "$REPORT_WEEKLY_DAY" ] && return 1
    [ "$hour" != "$REPORT_WEEKLY_HOUR" ] && return 1
    [ "$LAST_REPORT_WEEKLY" = "$week" ] && return 1
    return 0
}

# Check if we should optimize
should_optimize() {
    local now=$(date +%s)
    [ "$AUTO_OPTIMIZE" != "1" ] && return 1
    [ $((now - LAST_OPTIMIZE)) -lt "$OPTIMIZE_INTERVAL" ] && return 1
    return 0
}

# Main check cycle
run_check() {
    collect_stats
    local ts=$(date +%s)

    # Log snapshot
    log_msg "[SNAP] CPU:${CPU}% MEM:${MEM}% DISK:${DISK}% TEMP:${TEMP}C CLIENTS:${CLIENTS} CONNS:${CONNS}"

    # Save to DB
    snapshot

    # Check anomalies
    local alerts=$(detect_anomalies)
    if [ -n "$alerts" ]; then
        log_msg "[ALERT] $alerts"

        # Save alert to DB
        local alert_msg=$(echo "$alerts" | tr '\n' ' ')
        sqlite3 "$DB" "INSERT INTO alerts(ts,type,message) VALUES($ts,'threshold','$alert_msg');" 2>/dev/null

        # AI analysis
        local prompt=$(printf "OpenWrt alert: CPU %s%%, MEM %s%%, DISK %s%%, TEMP %sC. %s. Analyze cause and give fix advice." \
            "$CPU" "$MEM" "$DISK" "$TEMP" "$alerts")
        local ai_advice=$(ask_ai "$prompt")

        # Push alert
        local notify_msg=$(printf "CPU: %s%% | MEM: %s%% | DISK: %s%% | TEMP: %sC\nClients: %s | Conns: %s | Uptime: %sd\n\nAlerts:%s" \
            "$CPU" "$MEM" "$DISK" "$TEMP" "$CLIENTS" "$CONNS" "$UPTIME" "$alerts")
        [ -n "$ai_advice" ] && notify_msg="$notify_msg\n\nAI: $ai_advice"
        push_notify "Router Alert" "$notify_msg"
    fi

    # Daily report
    if should_daily_report; then
        log_msg "[REPORT] Generating daily report..."
        generate_report "daily"
        LAST_REPORT_DAILY=$(date +%Y%m%d)
        save_state
    fi

    # Weekly report
    if should_weekly_report; then
        log_msg "[REPORT] Generating weekly report..."
        generate_report "weekly"
        LAST_REPORT_WEEKLY=$(date +%Y%W)
        save_state
    fi

    # Auto optimize
    if should_optimize; then
        log_msg "[OPTIMIZE] Running auto-optimization..."
        run_optimize >> "$LOG_FILE" 2>&1
        LAST_OPTIMIZE=$(date +%s)
        save_state
    fi
}

# Load config override
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# Initialize
load_state
mkdir -p "$STATE_DIR"

case "${1:-}" in
    --once)
        run_check
        ;;
    --test)
        collect_stats
        echo "=== System Snapshot ==="
        echo "CPU=${CPU}% MEM=${MEM}% DISK=${DISK}% TEMP=${TEMP}C"
        echo "Clients=${CLIENTS} Connections=${CONNS} Processes=${PROC}"
        echo "Load=${LOAD} Uptime=${UPTIME}d"
        echo ""
        echo "=== Anomaly Check ==="
        detect_anomalies
        echo ""
        echo "=== AI Test ==="
        ask_ai "OpenWrt CPU 85%, MEM 70%, what should I check?" && echo "" || echo "AI not configured"
        echo ""
        echo "=== DB Stats ==="
        sqlite3 "$DB" "SELECT COUNT(*) as samples FROM metrics;" 2>/dev/null && echo " samples in DB" || echo "No DB yet"
        ;;
    --report)
        generate_report "${2:-daily}"
        ;;
    --optimize)
        run_optimize
        ;;
    --snapshot)
        json_snapshot
        ;;
    *)
        log_msg "[START] AI Monitor daemon v2 (interval=${CHECK_INTERVAL}s)"
        while true; do
            run_check
            sleep "$CHECK_INTERVAL"
        done
        ;;
esac
