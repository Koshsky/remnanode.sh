# remnanode.sh

Ansible-провижининг ремнанод на **Ubuntu 24.04 (noble)**.

`ansible-playbook` (playbooks/provision.yml) выполняет полную настройку свежих
машин одним прогоном: безопасность (SSH-ключи, hardening sshd, fail2ban, UFW),
обновления (unattended-upgrades), Docker CE, обратный прокси Caddy с авто-SSL
вместо nginx/certbot и RemnaNode.

Парк авторизуется по **единому park-ключу** (`playbooks/keys/park/id_ed25519`),
который генерируется при первом запуске. Единственный внешний ввод при первом
запуске — root-логин и пароль машины; далее Ansible работает по ключу.

## Как это устроено

- При первом запуске генерируется единая ключевая пара парка
  (`playbooks/keys/park/id_ed25519`, каталог не в версионном контроле); её
  публичная часть кладётся в `authorized_keys` **и root, и создаваемого
  пользователя** — **до** применения hardening sshd.
- sshd: `PermitRootLogin prohibit-password` — root **по паролю запрещён всегда**,
  по ключу разрешён (нужно Ansible); парольная аутентификация отключена.
- Первый запуск: `root + пароль` (`-k`). Повторные: `root + ключ`, без пароля.
- Операции на нодах выполняются под пользователем `NEW_USER_LOGIN` (sudo);
  Ansible подключается как root по ключу.
- Потеря ключей: `playbooks/ops/rekey.yml` перевыпускает и переустанавливает их
  (последний рубеж — консоль провайдера).

## Требования

```bash
pip install ansible
ansible-galaxy collection install -r requirements.yml
```

## Настройка

```bash
cp inventory/hosts.example.ini inventory/hosts.ini   # реальные IP (файл gitignored)
cp inventory/group_vars/all/vars.yml.template inventory/group_vars/all/vars.yml   # заполнить (gitignored)
```

### Переменные (inventory/group_vars/all/vars.yml)

| Переменная | Обязательная | Описание |
|---|---|---|
| `NEW_USER_LOGIN` / `NEW_USER_PASSWORD` | да | Пользователь (sudo) и его пароль |
| `EMAIL` | нет | Почта для ACME-аккаунта Caddy (необязательна при http-01) |
| `REMNAWAVE_SECRET_KEY` | да | Секрет RemnaWave |
| `DOMAIN_ZONE` | да | Зона по умолчанию: `DOMAIN = <hostname>.<DOMAIN_ZONE>`; для нод с другим доменом — `inventory/host_vars/<host>.yml` (`DOMAIN`/`DOMAIN_ZONE` перекроет) |
| `DOMAIN` | — | Вычисляется автоматически; переопределяется в `inventory/host_vars/<host>.yml` |
| `SSH_PORT` | нет | Порт SSH, по умолчанию 22 (рекомендуется оставлять стандартным) |
| `XRAY_PORT` / `REMNANODE_PORT` | нет | Порт Xray (443) / RemnaNode (8443) |
| `AUTO_REBOOT` | нет | `daily`, `weekly` или пусто (выкл) — авто-перезагрузка в 5:00 |
| `UNATTENDED_UPGRADES` | нет | Автообновления: `true` (по умолчанию, **только security**) или `false` (полностью выключить) |
| `UNATTENDED_UPGRADES_MAIL` | нет | Email уведомлений unattended-upgrades (пусто — выкл; требует MTA на хосте) |

### Быстрые прогоны (скип-логика)

| Сценарий | Команда |
|---|---|
| Полный (включая апгрейд пакетов и healthcheck'и) | `ansible-playbook playbooks/provision.yml` |
| Быстрый (идемпотентность/проверка без апгрейда) | `… --skip-tags upgrade` |
| Только обновление системы | `… --tags upgrade` |
| Только роль (например caddy) | `… --tags caddy` |
| Одна нода | `… --limit node-06` |
| Итерация без ожидания healthcheck'ов | `… --skip-tags checks` |
| Максимально быстро | `… --skip-tags upgrade,checks` |

Тег `upgrade` — на `apt full-upgrade`; тег `checks` — на пост-проверках.
Установка Docker CE пропускается, если docker уже стоит (обновления — через `--tags upgrade`).

## Запуск

```bash
# первая настройка парка (будет запрошен root-пароль каждого хоста):
ansible-playbook -i inventory/hosts.ini playbooks/provision.yml -k

# повторные запуски (по ключам, идемпотентно):
ansible-playbook -i inventory/hosts.ini playbooks/provision.yml
```

Новая машина добавляется строкой в `inventory/hosts.ini`
(`<name> ansible_host=<IP> ansible_user=root`) с последующим прогоном playbook.

### Домены / разные доменные зоны

- Парк в одной зоне: задаётся только `DOMAIN_ZONE`, `DOMAIN` вычисляется (`<hostname>.<DOMAIN_ZONE>`).
- Узлы в разных зонах или с кастомными доменами: `inventory/host_vars/<host>.yml`
  (файлы gitignored, пример — `inventory/host_vars/node-01.example.yml`):
  ```yaml
  DOMAIN: "custom-node.example.org"        # полный домен
  # или другая зона с hostname-шаблоном:
  # DOMAIN_ZONE: shop.example
  ```
  `host_vars` перекрывает `group_vars/all`. Если hostname машины должен совпадать
  с первым сегментом кастомного домена — хост переименовывается в инвентаре.

### Секреты

`REMNAWAVE_SECRET_KEY` — **единый секрет RemnaWave-панели**, общий для всех нод
(идентифицирует панель). Вписывается один раз в `inventory/group_vars/all/vars.yml`
при деплое панели. Никакой per-node настройки не требуется: `host_vars` используется
только для `DOMAIN`/`DOMAIN_ZONE`.

## Что делает playbook

1. Генерирует park-ключ, ставит hostname (имя из инвентаря) и обновляет систему.
2. Пакеты: Docker CE (+ compose plugin), fail2ban, ufw, openssh-server, sudo, unattended-upgrades.
3. Пользователь + SSH-ключи (root и user) → sshd (свой порт, root-пароль и пароли запрещены).
4. fail2ban (sshd) и UFW (default deny).
5. Caddy в Docker: сам выпускает и продлевает SSL для домена узла (ACME) и отдаёт
   landing/health за xray (TCP-loopback `127.0.0.1:8445`, БЕЗ PROXY protocol —
   в панели RemnaWave у фоллбэка ноды proxyProtocol выключен; listener-wrappers
   tls в Caddy 2.11 режут тела ответов, поэтому схема без wrapper'ов). На :443
   xray принимает VLESS — Caddy :443 НЕ слушает (иначе перехватывал бы клиентов)
   → RemnaNode (образ пинится 2.7.0).
6. Cron: zapret.dat (02:00/14:00), опц. перезагрузка; logrotate (продление SSL — на Caddy).

### Автообновления (unattended-upgrades)

- Включены по умолчанию, но **только для канала security**: оверрайд
  `99unattended-upgrades-security-only` сужает `Origins-Pattern` до
  `Ubuntu-Security`. Ядра и обычные обновления из `-updates` авто-режимом **не**
  трогаются (кроме security-патчей ядра — их применение всё равно требует ребута,
  который управляется отдельно через `AUTO_REBOOT` или вручную).
- `UNATTENDED_UPGRADES: false` — полностью выключает (флаг «1»→«0» в
  `20auto-upgrades`, таймеры останавливаются).
- Уведомления: опциональный `UNATTENDED_UPGRADES_MAIL` — только при наличии MTA
  на хосте; авто-перезагрузка всегда `false`.
- **Ручной прогон playbook** при этом делает *полное* обновление (`apt full-upgrade`,
  включая ядра из `-updates`) — осознанное действие оператора; в авто-режиме
  (unattended-upgrades) обновляется только security.

### Секреты (ansible-vault)

`inventory/group_vars/all/vars.yml` и `playbooks/keys/` gitignored, но лежат на диске
открытым текстом. Для продакшена секреты рекомендуется зашифровать:

```bash
ansible-vault encrypt inventory/group_vars/all/vars.yml       # пароль будет запрошен при запуске
ansible-playbook ... --ask-vault-pass
# либо переменные окружения: ANSIBLE_VAULT_PASSWORD_FILE=...
```

## Структура

```
ansible.cfg, requirements.yml
inventory/                   # hosts.example.ini (шаблон), hosts.ini (gitignored)
inventory/group_vars/all/vars.yml.template
playbooks/provision.yml      # полная настройка ноды
playbooks/ops/rekey.yml      # перевыпуск park-ключа
playbooks/ops/bootstrap_keys.py  # разовый первичный вход (root-пароль) на свежие ноды
playbooks/keys/              # gitignored: единый park-ключ парка
roles/
  base/          hostname, apt, пакеты, unattended-upgrades
  security/      пользователь, sshd_config.j2, ключи, fail2ban, ufw
  docker/        Docker CE + compose plugin
  caddy/         landing/health за xray + ACME-сертификаты (TCP-loopback 127.0.0.1:8445)
  remnanode/     compose.j2 + zapret cron
  maintenance/   cron (reboot), logrotate
```

## Устранение неполадок

- `Все порты молчат, таймауты` — пакеты не доходят до машины: проверить публичный IP
  ноды (`curl -s ifconfig.me` на ней), DNS, фаервол/панель провайдера.
- `https://<domain>/health` молчит, хотя caddy/xray Up — проверить в панели RemnaWave
  fallback ноды: dest должен быть `127.0.0.1:8445` (tcp), а не `/dev/shm/nginx.sock`
  (unix-сокет Caddy больше не создаёт).
- `Connection timed out` во время провижининга при открытом ufw/верном порте — fail2ban
  забанил IP контрольной машины (ControlMaster в `ansible.cfg` держит одно соединение
  на хост, так что на новых прогонах это исключено; текущий бан снять с консоли ноды:
  `fail2ban-client set sshd unbanip <IP>` либо подождать bantime=3600).
- Ручной доступ к машине: `ssh -p {{ SSH_PORT }} {{ NEW_USER_LOGIN }}@<IP>`
  (ключ — `playbooks/keys/park/id_ed25519`).
