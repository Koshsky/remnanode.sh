# remnanode.sh

Инструмент первичной настройки свежей машины **Ubuntu 24.04 (noble)**:
безопасность (SSH, fail2ban, UFW), обновления (в т.ч. автоматические security),
Docker, SSL (certbot), nginx, RemnaNode и минимальный мониторинг.

> Поддерживается только Ubuntu 24.04. Скрипт рассчитан на запуск от **root**.

## Предусловия

- Свежая Ubuntu 24.04 с доступом по SSH (или консолью провайдера) и выходом в интернет.
- **DNS**: A-запись для `DOMAIN` уже указывает на эту машину (certbot проверяет домен).
- **SSH-ключ**: публичный ключ для входа подготовлен заранее — он кладётся в
  `authorized_keys` нового пользователя, после чего парольный вход и root отключаются.
- Порты у провайдера/в панели VPS открыты: SSH-порт, 80, 443/xray, порт RemnaNode.
- Запускайте через **tmux/screen**: в конце установки перезапускается ssh.

## Установка

```bash
cp .env.example .env      # заполнить все поля
./setup.sh                # от root; повторно: FORCE=1 ./setup.sh
```

### Переменные .env

| Переменная | Обязательная | Описание |
|---|---|---|
| `NEW_USER_LOGIN` | да | Имя создаваемого пользователя (в группе sudo) |
| `NEW_USER_PASSWORD` | да | Его пароль (в лог/консоль не выводится) |
| `SSH_PUBLIC_KEY` | да | Публичный SSH-ключ администратора (одной строкой) |
| `EMAIL` | да | Почта для certbot |
| `DOMAIN` | да | Домен (не `CHANGE-ME`), A-запись на сервер |
| `REMNAWAVE_SECRET_KEY` | да | Секрет RemnaWave; спецсимволы безопасны (envsubst) |
| `SSH_PORT` | нет | Порт SSH, по умолчанию 222 |
| `XRAY_PORT` | нет | Порт Xray, по умолчанию 443 |
| `REMNANODE_PORT` | нет | Порт RemnaNode, по умолчанию 8443 |
| `AUTO_REBOOT` | нет | `daily`, `weekly` или пусто (выкл) — авто-перезагрузка в 5:00 |
| `TELEGRAM_BOT_TOKEN` | нет | Токен бота для уведомлений мониторинга |
| `TELEGRAM_USER_ID` | нет | Числовой Telegram user id получателя (перед настройкой напишите боту `/start`) |

Пустые обязательные поля скрипт не пропустит — упадёт на preflight до любых изменений системы.

## Что делает скрипт

1. Проверяет `.env` (preflight) и обновляет систему (`apt full-upgrade`).
2. Ставит: базовые утилиты, Docker CE (+ compose plugin, без podman), fail2ban,
   ufw, certbot, openssh-server, sudo, unattended-upgrades.
3. Создаёт пользователя, кладёт ваш SSH-ключ в `authorized_keys`, настраивает sshd
   (свой порт, root и пароли запрещены).
4. fail2ban (sshd, nginx-http-auth, nginx-limit-req) и UFW (default deny).
5. Получает SSL-сертификат (certbot standalone), поднимает nginx в Docker и RemnaNode.
6. Настраивает cron: продление сертификатов (03:00), zapret.dat (02:00/14:00),
   опционально перезагрузку; включается unattended-upgrades.
7. Устанавливает мониторинг (ежечасно) и logrotate; в конце — summary со статусами.

## Мониторинг

- Скрипт: `/opt/remnanode-monitor/monitor.sh`, запуск — systemd timer `remnanode-monitor.timer` (ежечасно).
- Проверяет: контейнеры nginx/remnanode, диск (>90%), load, и пишет в `/var/log/remnanode_monitor.log`.
- Уведомления Telegram — только если заданы `TELEGRAM_BOT_TOKEN` и `TELEGRAM_USER_ID`.

## Логи и артефакты

- Лог установки: `/var/log/setup_ubuntu24.log`, маркер завершения: `/var/log/setup_ubuntu24.done`
- Стеки: `/opt/nginx`, `/opt/remnanode`; мониторинг: `/opt/remnanode-monitor`
- SSL: `/etc/letsencrypt/live/$DOMAIN/`
- Логи контейнеров: `docker logs nginx`, `docker logs remnanode`; `/var/log/nginx`, `/var/log/remnanode`

## Структура репозитория

```
setup.sh                     # главный скрипт (Ubuntu 24.04)
.env.example                 # шаблон конфигурации (реальный .env не в git)
sshd_config, fail2ban_jail.local   # шаблоны конфигов
nginx/                       # nginx-стек (Docker): conf, compose, app
remnanode/                   # RemnaNode: docker-compose (версия образа пиннится)
renew_ssl_certificates.sh    # продление сертификатов (cron)
monitor/monitor.sh           # статус-скрипт мониторинга
```