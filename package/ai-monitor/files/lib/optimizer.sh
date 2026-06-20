#!/bin/sh
# AI Optimizer - process analysis, memory cleanup, AI-driven optimization

DATA_DIR="/var/lib/ai-monitor"
DB="$DATA_DIR/metrics.db"

. /usr/lib/ai-monitor/collector.sh 2>/dev/null || . /usr/bin/ai-monitor-lib-collector.sh 2>/dev/null
[ -f /etc/ai-monitor.conf ] && . /etc/ai-monitor.conf

AI_API_KEY="${AI_API_KEY:-}"
AI_API_URL="${AI_API_URL:-https://api.deepseek.com/chat/completions}"
AI_MODEL="${AI_MODEL:-deepseek-chat}"
PUSH_TYPE="${PUSH_TYPE:-none}"
PUSH_TOKEN="${PUSH_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
AUTO_OPTIMIZE="${AUTO_OPTIMIZE:-0}"
OPTIMIZE_INTERVAL="${OPTIMIZE_INTERVAL:-3600}"

# Get top processes by CPU
top_cpu_procs() {
    local limit="${1:-10}"
    ps ww 2>/dev/null | sort -rn -k3 | head -n "$limit" | while read -r user pid vsz rss _ comm; do
        [ "$pid" = "PID" ] && continue
        printf "%s|%s|%s|%s\n" "$pid" "$rss" "$vsz" "$comm"
    done
}

# Get top processes by memory (RSS)
top_mem_procs() {
    local limit="${1:-10}"
    ps ww 2>/dev/null | sort -rn -k4 | head -n "$limit" | while read -r user pid vsz rss _ comm; do
        [ "$pid" = "PID" ] && continue
        printf "%s|%s|%s|%s\n" "$pid" "$rss" "$vsz" "$comm"
    done
}

# Check for zombie processes
zombie_procs() {
    ps ww 2>/dev/null | grep -E '^.*Z' | while read -r line; do
        echo "$line" | awk '{print $1,$(NF)}'
    done
}

# Memory info
mem_info() {
    free 2>/dev/null | awk '
        /Mem:/ { total=$2; used=$3; free=$4; shared=$5; buff_cache=$6; available=$7 }
        /Swap:/ { swap_total=$2; swap_used=$3; swap_free=$4 }
        END {
            printf "total=%d used=%d free=%d avail=%d shared=%d bc=%d swap_total=%d swap_used=%d\n",
                total,used,free,available,shared,buff_cache,swap_total,swap_used
        }'
}

# Drop caches (safe on OpenWrt)
drop_caches() {
    local level="${1:-3}"
    echo "$level" > /proc/sys/vm/drop_caches 2>/dev/null && echo "Cache dropped (level $level)" || echo "Failed to drop caches"
}

# Clear systemd/journald logs if present
clean_logs() {
    local freed=0
    if [ -d /var/log ]; then
        local before=$(df /var 2>/dev/null | awk 'NR==2{print $3}')
        find /var/log -name "*.gz" -mtime +7 -delete 2>/dev/null
        find /var/log -name "*.old" -delete 2>/dev/null
        journalctl --vacuum-size=10M 2>/dev/null
        local after=$(df /var 2>/dev/null | awk 'NR==2{print $3}')
        freed=$((before - after))
    fi
    echo "Logs cleaned, freed ~${freed}KB"
}

# Kill hung processes (> threshold CPU for > threshold time)
kill_hung_procs() {
    local cpu_threshold="${1:-90}"
    local killed=0
    ps ww 2>/dev/null | sort -rn -k3 | while read -r user pid vsz rss cpu comm; do
        [ "$pid" = "PID" ] && continue
        [ "${cpu%.*}" -gt "$cpu_threshold" ] 2>/dev/null || continue
        # Skip kernel threads and essential services
        case "$comm" in
            *init*|*procd*|*ubus*|*netifd*|*logd*|*dropbear*) continue ;;
        esac
        kill "$pid" 2>/dev/null && echo "Killed PID $pid ($comm) CPU=${cpu}%" && killed=$((killed+1))
    done
}

# AI analysis of system state
ai_analyze() {
    [ -z "$AI_API_KEY" ] || [ "$AI_API_KEY" = "sk-your-key-here" ] && return 1

    local cpu=$(collect_cpu)
    local mem=$(collect_mem)
    local disk=$(collect_disk)
    local temp=$(collect_temp)
    local conns=$(collect_connections)
    local load=$(collect_load)
    local procs=$(collect_processes)

    local topproc=""
    ps ww 2>/dev/null | sort -rn -k3 | head -4 | tail -3 | while read -r _ pid _ rss _ comm; do
        topproc="$topproc PID:$pid($comm)RSS:${rss}KB"
    done

    local prompt=$(printf "OpenWrt router state: CPU %s%%, Memory %s%%, Disk %s%%, Temp %sC, %s connections, %s processes, load %s. Top processes: %s. Analyze if optimization is needed, give concise advice (under 80 words)." \
        "$cpu" "$mem" "$disk" "$temp" "$conns" "$procs" "$load" "$topproc")

    local resp=$(curl -s --connect-timeout 10 -m 30 \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AI_API_KEY" \
        -d "{\"model\":\"$AI_MODEL\",\"messages\":[{\"role\":\"system\",\"content\":\"You are an OpenWrt optimization expert. Give concise Chinese advice under 80 chars.\"},{\"role\":\"user\",\"content\":\"$prompt\"}],\"max_tokens\":200,\"temperature\":0.3}" \
        "$AI_API_URL" 2>/dev/null)

    local advice=$(echo "$resp" | grep -o '"content":"[^"]*"' | head -1 | sed 's/"content":"//;s/"//' | sed 's/\\n/ /g')
    [ -n "$advice" ] && echo "$advice"
}

# Full optimization run
run_optimize() {
    local actions=""
    local cpu=$(collect_cpu)
    local mem=$(collect_mem)

    echo "=== AI Monitor Optimization $(date) ==="

    # Memory pressure check
    if [ "${mem%.*}" -gt 85 ] 2>/dev/null; then
        echo "[ACTION] High memory pressure (${mem}%), dropping caches..."
        local dc=$(drop_caches 3)
        actions="$actions\n- $dc"
    fi

    # Check for zombies
    local zombies=$(zombie_procs)
    if [ -n "$zombies" ]; then
        echo "[WARN] Zombie processes detected: $zombies"
        actions="$actions\n- Zombie processes found: $zombies"
    fi

    # Clean old logs if disk > 80%
    local disk=$(collect_disk)
    if [ "${disk%.*}" -gt 80 ] 2>/dev/null; then
        echo "[ACTION] Disk usage high (${disk}%), cleaning logs..."
        local cl=$(clean_logs)
        actions="$actions\n- $cl"
    fi

    # AI analysis
    local ai_advice=$(ai_analyze 2>/dev/null)
    if [ -n "$ai_advice" ]; then
        echo "[AI] $ai_advice"
        actions="$actions\n- AI: $ai_advice"
    fi

    # Save optimization event
    init_db
    local ts=$(date +%s)
    sqlite3 "$DB" "INSERT INTO alerts(ts,type,message,ai_response) VALUES($ts,'optimize','Auto-optimization run','${ai_advice:-none}');" 2>/dev/null

    # Push if configured
    if [ -n "$PUSH_TOKEN" ] && [ "$PUSH_TYPE" != "none" ]; then
        local msg=$(printf "Optimization Summary\nCPU: %s%% MEM: %s%% DISK: %s%%\n%s" "$cpu" "$mem" "$disk" "$actions")
        case "$PUSH_TYPE" in
            serverchan)
                curl -s --connect-timeout 5 -m 10 "https://sctapi.ftqq.com/${PUSH_TOKEN}.send?title=AI%20Optimizer&desp=$msg" >/dev/null 2>&1 ;;
            telegram)
                curl -s --connect-timeout 5 -m 10 "https://api.telegram.org/bot${PUSH_TOKEN}/sendMessage" -d "chat_id=$TELEGRAM_CHAT_ID" -d "text=$msg" -d "parse_mode=HTML" >/dev/null 2>&1 ;;
        esac
    fi

    echo "$actions"
}

# Get optimization history
get_opt_history() {
    sqlite3 "$DB" "SELECT ts,message,ai_response FROM alerts WHERE type='optimize' ORDER BY ts DESC LIMIT 20;" 2>/dev/null
}

case "${1:-}" in
    analyze)    ai_analyze ;;
    optimize)   run_optimize ;;
    top-cpu)    top_cpu_procs "${2:-10}" ;;
    top-mem)    top_mem_procs "${2:-10}" ;;
    zombies)    zombie_procs ;;
    meminfo)    mem_info ;;
    dropcache)  drop_caches "${2:-3}" ;;
    cleanlogs)  clean_logs ;;
    killhung)   kill_hung_procs "${2:-90}" ;;
    history)    get_opt_history ;;
    *)          run_optimize ;;
esac
