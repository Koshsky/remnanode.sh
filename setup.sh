#!/bin/bash
# Target: Ubuntu 24.04 (noble) — единственная поддерживаемая ОС
# ВНИМАНИЕ: в конце скрипта перезапускается ssh — это может оборвать текущее
# SSH-соединение. Запускайте скрипт через tmux/screen или с консоли сервера.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/setup_ubuntu24.log"
DONE_MARKER="/var/log/setup_ubuntu24.done"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

fail() {
    log "ОШИБКА: $1"
    exit 1
}

load_env() {
    log "Загрузка переменных окружения из .env"
    if [ -f "$SCRIPT_DIR/.env" ]; then
        source "$SCRIPT_DIR/.env"
    else
        log "ОШИБКА: Файл .env не найден в $SCRIPT_DIR"
        exit 1
    fi
}

preflight_check() {
    log "Проверка обязательных переменных .env"

    local required_vars="NEW_USER_LOGIN NEW_USER_PASSWORD EMAIL REMNAWAVE_SECRET_KEY SSH_PUBLIC_KEY"
    local var
    for var in $required_vars; do
        if [ -z "${!var}" ]; then
            log "ОШИБКА: Переменная $var не задана в .env"
            exit 1
        fi
    done

    if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "CHANGE-ME" ]; then
        log "ОШИБКА: Переменная DOMAIN должна содержать реальный домен (не CHANGE-ME)"
        exit 1
    fi

    local port_var
    for port_var in SSH_PORT XRAY_PORT REMNANODE_PORT; do
        if ! [[ "${!port_var}" =~ ^[0-9]+$ ]] || [ "${!port_var}" -lt 1 ] || [ "${!port_var}" -gt 65535 ]; then
            log "ОШИБКА: Переменная $port_var должна быть числом от 1 до 65535"
            exit 1
        fi
    done

    log "Проверка .env пройдена"
}

setup_hostname() {
    local hostname="${DOMAIN%%.*}"
    if [ -z "$hostname" ]; then
        fail "Не удалось вывести hostname из DOMAIN ($DOMAIN)"
    fi

    log "Установка hostname: $hostname (из $DOMAIN)"
    hostnamectl set-hostname "$hostname" || fail "Не удалось установить hostname $hostname"

    # Ubuntu-соглашение: 127.0.1.1 hostname в /etc/hosts (иначе "Unable to resolve host")
    if ! grep -q "127.0.1.1[[:space:]]\+$hostname" /etc/hosts; then
        sed -i "1i 127.0.1.1 $hostname" /etc/hosts || true
    fi

    log "Hostname установлен: $hostname (hostname -f: $(hostname -f 2>/dev/null || echo n/a))"
}

update_packages() {
    log "Обновление всех пакетов системы"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y || fail "Не удалось обновить пакеты"
    log "Пакеты успешно обновлены"
}

install_software() {
    log "Установка необходимого ПО: ca-certificates, curl, gnupg, docker-ce, docker compose plugin, fail2ban, certbot, ufw, openssh-server"
    apt-get update -y

    # Удаление Podman и связанных пакетов (если установлен)
    log "Удаление Podman и связанных пакетов"
    apt-get remove -y podman podman-docker podman-compose buildah criu || true
    apt-get autoremove -y || true

    # Очистка конфигурации Podman
    rm -rf /etc/containers/ || true

    apt-get install -y ca-certificates curl wget gnupg apt-transport-https cron gettext-base || fail "Не удалось установить базовые утилиты"

    # Добавление официального репозитория Docker
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL --max-time 30 https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y || fail "Не удалось обновить списки пакетов после добавления репозитория Docker"

    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || fail "Не удалось установить Docker CE"

    apt-get install -y fail2ban ufw certbot openssh-server sudo unattended-upgrades || fail "Не удалось установить остальное ПО"

    log "Необходимое ПО успешно установлено"
}

setup_unattended_upgrades() {
    log "Настройка автоматических обновлений безопасности (unattended-upgrades)"

    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    systemctl enable apt-daily.timer apt-daily-upgrade.timer || true
    systemctl start apt-daily-upgrade.timer || true

    log "Автоматические обновления безопасности включены (перезагрузкой управляет AUTO_REBOOT)"
}

create_user() {
    log "Создание пользователя $NEW_USER_LOGIN"
    
    if id "$NEW_USER_LOGIN" &>/dev/null; then
        log "Пользователь $NEW_USER_LOGIN уже существует"
    else
        useradd -m -s /bin/bash "$NEW_USER_LOGIN" || fail "Не удалось создать пользователя $NEW_USER_LOGIN"
        
        echo "$NEW_USER_LOGIN:$NEW_USER_PASSWORD" | chpasswd || fail "Не удалось установить пароль для пользователя $NEW_USER_LOGIN"
        
        log "Пользователь $NEW_USER_LOGIN создан"
    fi
    
    usermod -aG sudo "$NEW_USER_LOGIN" || fail "Не удалось добавить пользователя $NEW_USER_LOGIN в группу sudo"
    
    log "Пользователь $NEW_USER_LOGIN добавлен в группы sudo и docker"
}

configure_ssh() {
    log "Настройка SSH"
    
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup || fail "Не удалось создать резервную копию sshd_config"
    
    local temp_sshd_config="/tmp/sshd_config_temp"
    if [ -f "$SCRIPT_DIR/sshd_config" ]; then
        sed "s/\$SSH_PORT/$SSH_PORT/g" "$SCRIPT_DIR/sshd_config" | \
        sed "s/\$NEW_USER_LOGIN/$NEW_USER_LOGIN/g" > "$temp_sshd_config"
        
        cp "$temp_sshd_config" /etc/ssh/sshd_config || fail "Не удалось скопировать sshd_config"
        rm -f "$temp_sshd_config"
    else
        log "ОШИБКА: Файл sshd_config не найден в $SCRIPT_DIR"
        exit 1
    fi
    
    log "Установка SSH-ключа для пользователя $NEW_USER_LOGIN"
    local user_home
    user_home="$(getent passwd "$NEW_USER_LOGIN" | cut -d: -f6)"
    mkdir -p "$user_home/.ssh"
    chmod 700 "$user_home/.ssh"
    echo "$SSH_PUBLIC_KEY" > "$user_home/.ssh/authorized_keys"
    chmod 600 "$user_home/.ssh/authorized_keys"
    chown -R "$NEW_USER_LOGIN:$NEW_USER_LOGIN" "$user_home/.ssh" || fail "Не удалось установить SSH-ключ для $NEW_USER_LOGIN"
    
    log "SSH настроен. Порт изменен на $SSH_PORT, запрещен вход root и аутентификация по паролю"
}

restart_ssh() {
    log "Перезапуск SSH для применения настроек"
    systemctl restart ssh || fail "Не удалось перезапустить SSH службу"
    log "SSH перезапущен (рестарт в конце установки, чтобы не оставить сервер без доступа)"
}

configure_fail2ban() {
    log "Настройка fail2ban"
    
    if [ -f "$SCRIPT_DIR/fail2ban_jail.local" ]; then
        cp "$SCRIPT_DIR/fail2ban_jail.local" /etc/fail2ban/jail.local || fail "Не удалось скопировать fail2ban_jail.local"
    else
        log "ОШИБКА: Файл fail2ban_jail.local не найден в $SCRIPT_DIR"
        exit 1
    fi
    
    sed -i "s/port    = ssh/port    = $SSH_PORT/g" /etc/fail2ban/jail.local
    
    systemctl enable fail2ban || fail "Не удалось включить fail2ban"
    systemctl start fail2ban || fail "Не удалось запустить fail2ban"
    
    log "fail2ban настроен и запущен"
}

configure_ufw() {
    log "Настройка UFW"
    
    systemctl enable ufw
    systemctl start ufw
    
    ufw --force reset || fail "Не удалось сбросить правила UFW"
    
    ufw default deny incoming || fail "Не удалось задать default deny incoming"
    ufw default allow outgoing || fail "Не удалось задать default allow outgoing"
    
    ufw allow "$SSH_PORT" || fail "Не удалось разрешить порт $SSH_PORT"
    ufw allow "$XRAY_PORT" || fail "Не удалось разрешить порт $XRAY_PORT"
    ufw allow "$REMNANODE_PORT" || fail "Не удалось разрешить порт $REMNANODE_PORT"
    ufw allow 80 || fail "Не удалось разрешить порт 80"
    echo "y" | ufw enable || fail "Не удалось включить UFW"
    
    log "UFW настроен. Разрешены порты: 80, $SSH_PORT, $XRAY_PORT, $REMNANODE_PORT"
}

configure_docker() {
    log "Настройка Docker"
    
    systemctl enable docker || fail "Не удалось включить автозапуск Docker"
    systemctl start docker || fail "Не удалось запустить Docker"
    
    docker --version || fail "Docker не работает корректно"
    
    if ! getent group docker > /dev/null; then
        groupadd docker
        log "Группа docker создана"
    fi
    
    usermod -aG docker "$NEW_USER_LOGIN" || fail "Не удалось добавить пользователя $NEW_USER_LOGIN в группу docker"
    
    log "Docker CE настроен и запущен, пользователь $NEW_USER_LOGIN добавлен в группу docker"
}

configure_nginx() {
    log "Настройка nginx в Docker"

    local nginx_dir="/opt/nginx"
    local script_nginx_dir="$SCRIPT_DIR/nginx"

    if [ -d "$script_nginx_dir" ]; then
        mkdir -p "$nginx_dir"
        cp -r "$script_nginx_dir"/* "$nginx_dir/" || fail "Не удалось скопировать nginx файлы"
    else
        log "ОШИБКА: Директория nginx не найдена в $SCRIPT_DIR"
        exit 1
    fi

    if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        log "ОШИБКА: SSL сертификаты не найдены в /etc/letsencrypt/live/$DOMAIN"
        exit 1
    fi

    sed -i -e "s/\$DOMAIN/$DOMAIN/g" \
           "$nginx_dir/nginx.conf" \
           "$nginx_dir/docker-compose.yml" || fail "Не удалось настроить конфигурационные файлы"

    mkdir -p /dev/shm/nginx
    chmod 755 /dev/shm/nginx

    # Логи nginx-контейнера для fail2ban (nginx-http-auth / nginx-limit-req)
    mkdir -p /var/log/nginx
    touch /var/log/nginx/error.log /var/log/nginx/access.log

    cd "$nginx_dir"
    docker compose up -d || fail "Не удалось запустить nginx в Docker"

    sleep 3
    if docker compose ps | grep -q "Up"; then
        log "nginx успешно запущен в Docker"
        fail2ban-client reload 2>/dev/null || true
    else
        log "ОШИБКА: nginx не запустился"
        docker compose logs
        exit 1
    fi

    log "nginx настроен. Домен: $DOMAIN"
}

get_ssl_certificates() {
    log "Получение SSL сертификатов для домена $DOMAIN"
    mkdir -p /var/www/certbot
    chmod 755 /var/www/certbot
    chown -R $USER:$USER /var/www/certbot

    certbot certonly --standalone --non-interactive --agree-tos \
        --email $EMAIL \
        -d $DOMAIN \
        --http-01-port 80 \
        --cert-name $DOMAIN || fail "Не удалось получить SSL сертификаты для $DOMAIN"
    log "SSL сертификаты для $DOMAIN успешно получены"
}

setup_cert_renewal() {
    log "Настройка скрипта для автоматического обновления сертификатов"
    
    local renew_script="/usr/local/bin/renew_ssl_certificates.sh"
    
    if [ -f "$SCRIPT_DIR/renew_ssl_certificates.sh" ]; then
        cp "$SCRIPT_DIR/renew_ssl_certificates.sh" "$renew_script" || fail "Не удалось скопировать renew_ssl_certificates.sh"
    else
        log "ОШИБКА: Файл renew_ssl_certificates.sh не найден в $SCRIPT_DIR"
        exit 1
    fi
    
    chmod +x "$renew_script"
    
    (crontab -l 2>/dev/null | grep -v "$renew_script"; echo "0 3 * * * $renew_script") | crontab - || fail "Не удалось добавить задание в cron для обновления сертификатов"
    
    log "Скрипт обновления сертификатов настроен и добавлен в cron (ежедневно в 3:00)"
}

setup_auto_reboot() {
    local mode="${AUTO_REBOOT:-}"
    local reboot_schedule=""

    case "$mode" in
        daily)   reboot_schedule="0 5 * * *" ;;
        weekly)  reboot_schedule="0 5 * * 0" ;;
        "")      log "Автоперезагрузка отключена (AUTO_REBOOT не задан в .env)"
                 return 0 ;;
        *)       log "ОШИБКА: AUTO_REBOOT должен быть daily, weekly или пустым (сейчас: $mode)"
                 exit 1 ;;
    esac

    log "Настройка автоматической перезагрузки ($mode) в 5:00"
    
    (crontab -l 2>/dev/null | grep -v "reboot"; echo "$reboot_schedule /sbin/reboot") | crontab - || fail "Не удалось добавить задание перезагрузки в cron"
    
    log "Автоматическая перезагрузка настроена ($mode, 5:00)"
}

setup_remnanode() {
    log "Настройка RemnaNode"

    local remnanode_dir="/opt/remnanode"
    local script_remnanode_dir="$SCRIPT_DIR/remnanode"

    if [ -d "$script_remnanode_dir" ]; then
        mkdir -p "$remnanode_dir"
        cp -r "$script_remnanode_dir"/* "$remnanode_dir/" || fail "Не удалось скопировать файлы RemnaNode"
    else
        log "ОШИБКА: Директория remnanode не найдена в $SCRIPT_DIR"
        exit 1
    fi

    if [ -f "$remnanode_dir/docker-compose.yml" ]; then
        # Заменяем переменные через envsubst — безопасно для спецсимволов в SECRET_KEY
        REMNANODE_PORT="$REMNANODE_PORT" REMNAWAVE_SECRET_KEY="$REMNAWAVE_SECRET_KEY" \
            envsubst '$REMNANODE_PORT $REMNAWAVE_SECRET_KEY' < "$remnanode_dir/docker-compose.yml" > "$remnanode_dir/docker-compose.yml.tmp" &&
            mv "$remnanode_dir/docker-compose.yml.tmp" "$remnanode_dir/docker-compose.yml" || fail "Не удалось обновить docker-compose.yml"
        
        log "docker-compose.yml обновлен с актуальными переменными"
    else
        log "ОШИБКА: docker-compose.yml не найден в $remnanode_dir"
        exit 1
    fi

    mkdir -p /var/log/remnanode
    mkdir -p /opt/remnawave/xray/share
    cd "$remnanode_dir"

    # Добавить задачу, сохраняя существующие
    (crontab -l 2>/dev/null | grep -v 'zapret.dat'; echo "0 2,14 * * * wget -q --timeout=30 -T 30 -O /opt/remnawave/xray/share/zapret.dat https://github.com/kutovoys/ru_gov_zapret/releases/latest/download/zapret.dat") | crontab -
    log "Настроено обновление томов Zapret RU GOV дважды в день."
    log "Том расположен по пути: /opt/remnawave/xray/share/zapret.dat"

    docker compose up -d || fail "Не удалось запустить RemnaNode"

    log "RemnaNode настроен и запущен"
}

setup_beszel() {
    if [ -z "${BESZEL_HUB_URL:-}" ]; then
        log "Beszel не настроен (BESZEL_HUB_URL пуст в .env) — агент не устанавливается"
        return 0
    fi
    if [ -z "${BESZEL_AGENT_KEY:-}" ] || [ -z "${BESZEL_TOKEN:-}" ]; then
        log "ОШИБКА: BESZEL_HUB_URL задан, но BESZEL_AGENT_KEY/BESZEL_TOKEN пусты"
        log "Ключ и токен выдаёт Web-UI hub'а: Add System -> скопировать в .env узла"
        exit 1
    fi

    log "Установка Beszel-агента (hub: $BESZEL_HUB_URL)"

    local agent_dir="/opt/beszel-agent"
    if [ ! -f "$SCRIPT_DIR/beszel/agent/docker-compose.yml" ]; then
        log "ОШИБКА: beszel/agent/docker-compose.yml не найден в $SCRIPT_DIR"
        exit 1
    fi
    mkdir -p "$agent_dir"
    cp "$SCRIPT_DIR/beszel/agent/docker-compose.yml" "$agent_dir/docker-compose.yml" || fail "Не удалось скопировать beszel-agent compose"

    # envsubst — безопасно для спецсимволов в ключах и токенах
    BESZEL_AGENT_KEY="$BESZEL_AGENT_KEY" BESZEL_HUB_URL="$BESZEL_HUB_URL" \
        BESZEL_TOKEN="$BESZEL_TOKEN" BESZEL_AGENT_PORT="${BESZEL_AGENT_PORT:-45876}" \
        envsubst '$BESZEL_AGENT_KEY $BESZEL_HUB_URL $BESZEL_TOKEN $BESZEL_AGENT_PORT' \
        < "$agent_dir/docker-compose.yml" > "$agent_dir/docker-compose.yml.tmp" &&
        mv "$agent_dir/docker-compose.yml.tmp" "$agent_dir/docker-compose.yml" || fail "Не удалось подставить переменные beszel-agent"

    cd "$agent_dir"
    docker compose up -d || fail "Не удалось запустить Beszel-агента"

    sleep 3
    if docker compose ps | grep -q "Up"; then
        log "Beszel-агент запущен (hub: $BESZEL_HUB_URL)"
    else
        log "ОШИБКА: Beszel-агент не запустился"
        docker compose logs
        exit 1
    fi
}

setup_logrotate() {
    mkdir -p /var/log/remnanode
    bash -c 'cat > /etc/logrotate.d/remnanode << EOF
    /var/log/remnanode/*.log {
        size 50M
        rotate 5
        compress
        missingok
        notifempty
        copytruncate
    }
    EOF'
    systemctl enable logrotate.timer
    systemctl start logrotate.timer
}

print_post_setup_info() {
    local rc=0
    local ok="[OK]  "
    local bad="[FAIL]"

    echo "============================================="
    echo "ИТОГ НАСТРОЙКИ Ubuntu 24 — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================="

    # --- Проверки: только реальные состояния ---
    if docker ps --format '{{.Names}}' | grep -qx remnanode; then
        echo "$ok RemnaNode (docker)      запущен"
    else
        echo "$bad RemnaNode (docker)      не запущен"; rc=1
    fi

    if docker ps --format '{{.Names}}' | grep -qx nginx; then
        echo "$ok nginx (docker)           запущен"
    else
        echo "$bad nginx (docker)           не запущен"; rc=1
    fi

    local http_code
    http_code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "https://$DOMAIN/health" 2>/dev/null || true)
    if [ "$http_code" = "200" ]; then
        echo "$ok https://$DOMAIN/health   HTTP 200"
    else
        echo "$bad https://$DOMAIN/health   HTTP ${http_code:-нет ответа}"; rc=1
    fi

    if ss -tln | grep -q ":$XRAY_PORT "; then
        echo "$ok xray :$XRAY_PORT         слушает"
    else
        echo "$bad xray :$XRAY_PORT         не слушает"; rc=1
    fi

    if ss -tln | grep -q ":$REMNANODE_PORT "; then
        echo "$ok RemnaNode :$REMNANODE_PORT  слушает"
    else
        echo "$bad RemnaNode :$REMNANODE_PORT  не слушает"; rc=1
    fi

    # --- Конфигурация: одна компактная секция ---
    echo "---"
    echo "SSH:  user=$NEW_USER_LOGIN port=$SSH_PORT root=запрещён пароли=запрещены"
    echo "SSL:  /etc/letsencrypt/live/$DOMAIN/"
    echo "IP:   $(curl -s --max-time 5 ifconfig.me)"
    echo "Dirs: /opt/nginx /opt/remnanode"
    echo "Logs: /var/log/setup_ubuntu24.log /var/log/nginx /var/log/remnanode"
    echo "Cron: cert-renew 03:00, zapret 02:00/14:00"
    echo "systemd: docker=$(systemctl is-active docker 2>/dev/null || echo down) ufw=$(systemctl is-active ufw 2>/dev/null || echo down) fail2ban=$(systemctl is-active fail2ban 2>/dev/null || echo down)"
    echo "============================================="

    return $rc
}

# Основная функция
main() {
    log "Начало настройки Ubuntu 24"
    export DEBIAN_FRONTEND=noninteractive

    if [ -f "$DONE_MARKER" ] && [ "${FORCE:-}" != "1" ]; then
        log "ОШИБКА: Установка уже была выполнена ранее (маркер $DONE_MARKER)."
        log "Для повторного запуска: FORCE=1 ./setup.sh"
        exit 1
    fi

    load_env
    preflight_check
    setup_hostname
    update_packages
    install_software
    setup_unattended_upgrades
    create_user
    configure_ssh
    configure_fail2ban
    configure_ufw
    configure_docker
    get_ssl_certificates
    configure_nginx
    setup_cert_renewal
    setup_auto_reboot
    setup_remnanode
    setup_beszel
    setup_logrotate
    restart_ssh
    if print_post_setup_info; then
        touch "$DONE_MARKER"
        log "Настройка завершена успешно (маркер: $DONE_MARKER)"
    else
        log "Настройка завершена с ошибками проверок — маркер НЕ создан (FORCE=1 для повтора)"
        exit 1
    fi
}

# Запуск основной функции
main "$@"

