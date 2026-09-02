# remnanode.sh

Инструмент первичной настройки свежей машины **Ubuntu 24.04 (noble)**:
безопасность (SSH, fail2ban, UFW), обновления (в т.ч. автоматические security),
Docker, SSL (certbot), nginx, RemnaNode и мониторинг парка (Beszel).

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
| `BESZEL_HUB_URL` | нет | Адрес hub'а Beszel (напр. `https://dashboard.example.com`); пусто — агент не ставится |
| `BESZEL_AGENT_KEY` | нет | Ключ из Web-UI hub'а (Add System) |
| `BESZEL_TOKEN` | нет | Токен из Web-UI hub'а (Add System) |
| `BESZEL_AGENT_PORT` | нет | Порт агента, по умолчанию 45876 |

Пустые обязательные поля скрипт не пропустит — упадёт на preflight до любых изменений системы.

## Что делает скрипт

1. Устанавливает hostname из `DOMAIN` (напр. `node-01.example.com` → `node-01`), проверяет `.env` (preflight) и обновляет систему (`apt full-upgrade`).
2. Ставит: базовые утилиты, Docker CE (+ compose plugin, без podman), fail2ban,
   ufw, certbot, openssh-server, sudo, unattended-upgrades.
3. Создаёт пользователя, кладёт ваш SSH-ключ в `authorized_keys`, настраивает sshd
   (свой порт, root и пароли запрещены).
4. fail2ban (sshd, nginx-http-auth, nginx-limit-req) и UFW (default deny).
5. Получает SSL-сертификат (certbot standalone), поднимает nginx в Docker и RemnaNode.
6. Настраивает cron: продление сертификатов (03:00), zapret.dat (02:00/14:00),
   опционально перезагрузку; включается unattended-upgrades.
7. Устанавливает Beszel-агент (если задан `.env`) и logrotate; в конце — summary со статусами.

## Мониторинг (Beszel)

Единая точка для всего парка ремнанод — **hub** на отдельной машине, агент на каждом узле.

Поднять hub:

```bash
cd beszel/server && cp .env.example .env && docker compose up -d
```

Web-UI hub: `http://IP:8090` (первый аккаунт — администратор). За UFW лучше закрыть 8090 от интернета — разрешить только себе или проксировать за HTTPS (пример Caddy: `reverse_proxy beszel:8090`).

Подключение новой remnanode — **без правок конфига hub'а**:
1. В hub → **Add System** → скопировать `KEY`/`TOKEN`.
2. В `.env` узла вписать:
   ```
   BESZEL_HUB_URL="https://dashboard.example.com"
   BESZEL_AGENT_KEY="<KEY>"
   BESZEL_TOKEN="<TOKEN>"
   ```
3. `./setup.sh` — агент сам зарегистрируется и начнёт пушить метрики.

Hub не хранит список узлов заранее — агент приходит с парой ключ/токен и регистрируется сам, поэтому новые узлы добавляются только через `.env` на них. Метрики контейнеров nginx/remnanode доступны благодаря `/var/run/docker.sock` в агенте.

## Логи и артефакты

- Лог установки: `/var/log/setup_ubuntu24.log`, маркер завершения: `/var/log/setup_ubuntu24.done`
- Стеки: `/opt/nginx`, `/opt/remnanode`, `/opt/beszel-agent`
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
beszel/server/               # hub: веб-дашборд всего парка (docker compose)
beszel/agent/                # агент-шаблон, ставится на каждом узле через setup.sh
```