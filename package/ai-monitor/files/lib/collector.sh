#!/bin/sh
# Data Collector - gathers all system metrics

DATA_DIR="/var/lib/ai-monitor"
DB="$DATA_DIR/metrics.db"

init_db() {
    mkdir -p "$DATA_DIR"
    sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS metrics (
        ts INTEGER PRIMARY KEY,
        cpu REAL, mem REAL, disk REAL, temp REAL,
        rx_bytes INTEGER, tx_bytes INTEGER,
        clients INTEGER, processes INTEGER, conns INTEGER,
        load1 REAL, load5 REAL, load15 REAL
    );" 2>/dev/null
    sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS clients (
        mac TEXT, ip TEXT, hostname TEXT, first_seen INTEGER,
        last_seen INTEGER, PRIMARY KEY(mac)
    );" 2>/dev/null
    sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS alerts (
        ts INTEGER, type TEXT, message TEXT, ai_response TEXT
    );" 2>/dev/null
    sqlite3 "$DB" "PRAGMA journal_mode=WAL;" 2>/dev/null
}

collect_cpu() {
    local cpu=$(top -bn1 2>/dev/null | grep "CPU:" | awk '{print $2}' | sed 's/%//')
    [ -z "$cpu" ] && cpu=$(awk -v n=$(nproc) '{printf "%.0f", $1*100/n}' /proc/loadavg)
    echo "${cpu:-0}"
}

collect_mem() {
    free | awk '/Mem:/ {printf "%.1f", $3/$2*100}'
}

collect_disk() {
    df / | awk 'NR==2 {print $5}' | sed 's/%//'
}

collect_temp() {
    local t=""
    for f in /sys/class/thermal/thermal_zone*/temp; do
        [ -f "$f" ] && t=$(awk '{printf "%.0f", $1/1000}' "$f") && break
    done
    echo "${t:-0}"
}

collect_traffic() {
    local iface=$(route -n 2>/dev/null | awk '$1=="0.0.0.0"{print $8;exit}')
    [ -z "$iface" ] && iface=$(ip route 2>/dev/null | awk '/default/{print $5;exit}')
    [ -z "$iface" ] && iface="eth0"
    local rx=$(awk -v if="$iface:" '$1==if{print $2}' /proc/net/dev 2>/dev/null)
    local tx=$(awk -v if="$iface:" '$1==if{print $10}' /proc/net/dev 2>/dev/null)
    echo "${rx:-0} ${tx:-0}"
}

collect_clients() {
    local count=0
    [ -f /tmp/dhcp.leases ] && count=$(wc -l < /tmp/dhcp.leases)
    [ "$count" -eq 0 ] && count=$(ip neigh 2>/dev/null | grep -c REACHABLE)
    echo "${count:-0}"
}

collect_processes() {
    ps 2>/dev/null | wc -l
}

collect_connections() {
    cat /proc/net/nf_conntrack 2>/dev/null | wc -l
}

collect_load() {
    awk '{print $1, $2, $3}' /proc/loadavg
}

snapshot() {
    init_db
    local ts=$(date +%s)
    local cpu=$(collect_cpu)
    local mem=$(collect_mem)
    local disk=$(collect_disk)
    local temp=$(collect_temp)
    local traffic=$(collect_traffic)
    local rx=$(echo "$traffic" | awk '{print $1}')
    local tx=$(echo "$traffic" | awk '{print $2}')
    local clients=$(collect_clients)
    local proc=$(collect_processes)
    local conns=$(collect_connections)
    local load=$(collect_load)

    sqlite3 "$DB" "INSERT INTO metrics VALUES($ts,$cpu,$mem,$disk,$temp,$rx,$tx,$clients,$proc,$conns,$(echo $load | sed 's/ /,/g'));" 2>/dev/null

    # Track client changes
    [ -f /tmp/dhcp.leases ] && while IFS=' ' read -r _ mac ip hostname _; do
        [ -z "$mac" ] && continue
        sqlite3 "$DB" "INSERT INTO clients(mac,ip,hostname,first_seen,last_seen) VALUES('$mac','$ip','$hostname',$ts,$ts) ON CONFLICT(mac) DO UPDATE SET ip='$ip',hostname='$hostname',last_seen=$ts;" 2>/dev/null
    done < /tmp/dhcp.leases

    # Cleanup old data (keep 7 days)
    sqlite3 "$DB" "DELETE FROM metrics WHERE ts < $((ts - 604800));" 2>/dev/null
}

# Return JSON for LuCI
json_snapshot() {
    local cpu=$(collect_cpu)
    local mem=$(collect_mem)
    local disk=$(collect_disk)
    local temp=$(collect_temp)
    local traffic=$(collect_traffic)
    local rx=$(echo "$traffic" | awk '{printf "%.1f", $1/1073741824}')
    local tx=$(echo "$traffic" | awk '{printf "%.1f", $2/1073741824}')
    local clients=$(collect_clients)
    local proc=$(collect_processes)
    local conns=$(collect_connections)
    local uptime=$(awk '{printf "%.0f", $1/86400}' /proc/uptime)

    printf '{"cpu":%s,"mem":%s,"disk":%s,"temp":%s,"rx_gb":%s,"tx_gb":%s,"clients":%s,"processes":%s,"connections":%s,"uptime_days":%s}' \
        "$cpu" "$mem" "$disk" "$temp" "$rx" "$tx" "$clients" "$proc" "$conns" "$uptime"
}

case "${1:-}" in
    init) init_db ;;
    all)  snapshot ;;
    json) json_snapshot ;;
    cpu)  collect_cpu ;;
    mem)  collect_mem ;;
    disk) collect_disk ;;
    temp) collect_temp ;;
    traffic) collect_traffic ;;
    clients) collect_clients ;;
    proc) collect_processes ;;
    conns) collect_connections ;;
    load) collect_load ;;
esac
