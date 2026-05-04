#!/bin/bash
# health-monitor.sh — periodic on-Pi health snapshot.
#
# Triggered every 5 minutes by health-monitor.timer. Appends a single
# block of state (memory, listening sockets, top RSS processes, key
# service states, temperature, load, dmesg OOMs since boot) to
# /var/log/printserver/health.log so that AFTER an outage and reboot
# the operator can scroll back and see exactly what the system looked
# like just before SSH/web stopped responding.
#
# Designed to:
#   - never fail (every command is wrapped with || true)
#   - be tiny per run (~2 KB) so logrotate keeps weeks of history at <2 MB
#   - never call into the printserver-web service itself (must work even
#     when the web service is dead)

set +e
LOGFILE="/var/log/printserver/health.log"
mkdir -p "$(dirname "$LOGFILE")"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

{
    echo "=== $(ts) ==="

    echo "-- memory (MB) --"
    free -m 2>/dev/null | head -3

    echo "-- load / uptime --"
    uptime 2>/dev/null

    echo "-- temperature --"
    if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
        awk '{printf "cpu: %.1f C\n", $1/1000}' /sys/class/thermal/thermal_zone0/temp
    fi

    echo "-- listening (22, 5000, 631, 139, 445) --"
    ss -tlnH 2>/dev/null | awk '$4 ~ /:(22|5000|631|139|445)$/ {print $1, $4, $6}'

    echo "-- key services --"
    for svc in ssh ssh.socket printserver-web cups avahi-daemon smbd nmbd wsdd; do
        state=$(systemctl is-active "$svc" 2>/dev/null)
        printf "  %-20s %s\n" "$svc" "${state:-missing}"
    done

    echo "-- top 8 by RSS --"
    ps -eo pid,rss,comm --sort=-rss --no-headers 2>/dev/null | head -8 \
        | awk '{printf "  pid=%-6s rss=%6s KB  %s\n", $1, $2, $3}'

    echo "-- OOM kills since boot --"
    oom=$(dmesg 2>/dev/null | grep -ciE "killed process|out of memory")
    echo "  count: ${oom:-0}"
    if [[ "${oom:-0}" -gt 0 ]]; then
        dmesg 2>/dev/null | grep -iE "killed process|out of memory" | tail -3 \
            | sed 's/^/  /'
    fi

    echo "-- disk (/ , /var/log) --"
    df -h / /var/log 2>/dev/null | awk 'NR>1 {printf "  %-15s %s used / %s total (%s)\n", $6, $3, $2, $5}'

    echo
} >> "$LOGFILE" 2>&1

exit 0
