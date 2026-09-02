#!/bin/bash
# Минимальный мониторинг RemnaNode: статус контейнеров, диск, load, fail2ban.
# Устанавливается в /opt/remnanode-monitor/ и запускается systemd timer'ом (ежечасно).
# Telegram-уведомления — только если в /opt/remnanode-monitor/.env заданы
# TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID.

set -e

LOG_FILE="/var/log/remnanode_monitor.log"
STATE_FILE="/var/log/remnanode_monitor.state"

CONFIG_FILE="/opt/remnanode-monitor/.env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

check_containers() {
    local problems=""
    local name
    for name in nginx remnanode; do
        if ! docker ps --format '{{.Names}}' | grep -qx "$name"; then
            problems="$problems\n  • контейнер $name не запущен"
        fi
    done
    echo -e "$problems"
}

check_disk() {
    local usage
    usage=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
    if [ "${usage:-0}" -gt 90 ]; then
        echo "  • занятость диска: ${usage}% (>90%)"
    fi
}

check_load() {
    local load1 cores
    load1=$(awk '{print $1}' /proc/loadavg | cut -d. -f1)
    load1=${load1:-0}
    cores=$(nproc)
    if [ "$load1" -ge "$cores" ]; then
        echo "  • load average $load1 >= ядер ($cores)"
    fi
}

notify_telegram() {
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        return 0
    fi
    curl -s --max-time 10 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=$1" > /dev/null || true
}

report=""
report+="$(check_containers)"
report+="$(check_disk)"
report+="$(check_load)"

if [ -n "$report" ]; then
    message="⚠️ RemnaNode $(hostname): проблемы $(date '+%Y-%m-%d %H:%M:%S'):$report"
    log "ПРОБЛЕМЫ:$report"
    if [ "$(cat "$STATE_FILE" 2>/dev/null)" != "bad" ]; then
        notify_telegram "$message"
        echo "bad" > "$STATE_FILE"
    fi
else
    log "OK"
    if [ "$(cat "$STATE_FILE" 2>/dev/null)" = "bad" ]; then
        notify_telegram "✅ RemnaNode $(hostname): все системы в норме"
        echo "ok" > "$STATE_FILE"
    fi
fi