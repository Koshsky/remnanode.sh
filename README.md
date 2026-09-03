# remnanode.sh — Ansible-провижининг ремнанод (Ubuntu 24.04)

Полная настройка свежих машин **Ubuntu 24.04 (noble)** через Ansible:
безопасность (SSH-ключи, fail2ban, UFW), обновления (в т.ч. unattended-upgrades),
Docker, nginx-замена — Caddy (SSL сам), RemnaNode и мониторинг парка (Beszel).

Единственный ввод при первом запуске — **root-логин и пароль** машины. Дальше
Ansible работает по сгенерированным SSH-ключам.

## Как это устроено (ответ на «а как реконнект?»)

- При первом запуске для каждого хоста генерируется ключевая пара
  (`keys/<host>/id_ed25519`, каталог в `.gitignore`), публичная часть кладётся в
  `authorized_keys` **и root, и создаваемого пользователя** — **до** применения
  харднинга sshd.
- sshd: `PermitRootLogin prohibit-password` — root **по паролю запрещён всегда**,
  по ключу разрешён (нужно Ansible); парольная аутентификация отключена.
- Первый запуск: `root + пароль` (`-k`). Повторные: `root + ключ`, без пароля.
- Человек работает под `NEW_USER_LOGIN` (sudo), Ansible — под root по ключу.
- Потерял ключи? → `playbooks/ops/rekey.yml` перевыпускает и переустанавливает их
  (последний рубеж — консоль провайдера).

## Требования (контрольная машина — у тебя)

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
| `BESZEL_HUB_URL` | нет | Адрес hub'а Beszel; пусто — агент не ставится |
| `BESZEL_AGENT_KEY` / `BESZEL_TOKEN` | нет | Ключ/токен из Web-UI hub'а (Add System) |
| `BESZEL_AGENT_PORT` | нет | Порт агента, по умолчанию 45876 |
| `BESZEL_ALLOW_FROM` | нет | IP/подсеть hub'а — открыть 45876 в UFW (SSH-режим Beszel) |

## Запуск

```bash
# первая настройка парка (спросит root-пароль каждого хоста):
ansible-playbook -i inventory/hosts.ini playbooks/provision.yml -k

# повторные запуски (по ключам, идемпотентно):
ansible-playbook -i inventory/hosts.ini playbooks/provision.yml
```

Новая машина = добавить строку в `inventory/hosts.ini` (`<name> ansible_host=<IP> ansible_user=root`)
и прогнать playbook — hub Beszel при этом трогать не нужно (агент регистрируется сам).

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
  с первым сегментом кастомного домена — переименуйте хост в инвентаре.

## Что делает playbook

1. Генерирует ключи, ставит hostname (имя из инвентаря) и обновляет систему.
2. Пакеты: Docker CE (+ compose plugin), fail2ban, ufw, openssh-server, sudo, unattended-upgrades.
3. Пользователь + SSH-ключи (root и user) → sshd (свой порт, root-пароль и пароли запрещены).
4. fail2ban (sshd) и UFW (default deny).
5. Caddy в Docker: сам выпускает и продлевает SSL для домена узла (ACME) и отдаёт
   landing/health за xray (unix-сокет, PROXY protocol) → RemnaNode (образ пинится 2.7.0).
6. Cron: zapret.dat (02:00/14:00), опц. перезагрузка; logrotate (продление SSL — на Caddy).
7. Beszel-агент (если задан) + опциональное UFW-правило для SSH-режима.

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
  включая ядра из `-updates`) — это осознанное действие оператора; в авто-режиме
  (unattended-upgrades) обновляется только security.

### Секреты (ansible-vault)

`inventory/group_vars/all/vars.yml` и `keys/` gitignored, но лежат на диске открытым текстом.
Для продакшена рекомендуется зашифровать секреты:

```bash
ansible-vault encrypt inventory/group_vars/all/vars.yml       # пароль спросит при запуске
ansible-playbook ... --ask-vault-pass
# либо переменные окружения: ANSIBLE_VAULT_PASSWORD_FILE=...
```

## Мониторинг (Beszel)

Hub Beszel разворачивается **отдельно на своём VPS** (вне этого репозитория — образ
`henrygd/beszel`, UI на порту 8090). В этом репо — только **агент** (`roles/beszel`):
он пушит метрики на hub. Новая нода добавляется через инвентарь и `BESZEL_*`
переменные, конфиг hub не правится.

```text
1. В Web-UI hub'а: Add System → скопировать KEY/TOKEN
2. Вписать BESZEL_HUB_URL / BESZEL_AGENT_KEY / BESZEL_TOKEN в inventory/group_vars/all/vars.yml
3. Проиграть provision.yml — агент зарегистрируется сам
```

## Структура

```
ansible.cfg, requirements.yml
inventory/                   # hosts.example.ini (шаблон), hosts.ini (gitignored)
inventory/group_vars/all/vars.yml.template
playbooks/provision.yml      # полная настройка ноды
playbooks/ops/rekey.yml      # перевыпуск ключей
keys/                        # gitignored: сгенерированные ключи по хостам
roles/
  base/          hostname, apt, пакеты, unattended-upgrades
  security/      пользователь, sshd_config.j2, ключи, fail2ban, ufw
  docker/        Docker CE + compose plugin
  caddy/         landing/health за xray + ACME-сертификаты (unix-сокет, PROXY protocol)
  remnanode/     compose.j2 + zapret cron
  beszel/        агент (compose.j2) + UFW-правило
  maintenance/   cron (reboot), logrotate
```

## Устранение неполадок

- `Все порты молчат, таймауты` — пакеты не доходят до машины: проверь публичный IP
  ноды (`curl -s ifconfig.me` на ней), DNS, фаервол/панель провайдера.
- `401 от Beszel` — ключ/токен не совпадают с hub: перевыпустить через Add System.
- `Connection timed out` во время провижининга при открытом ufw/верном порте — fail2ban
  забанил твой IP (ControlMaster в `ansible.cfg` держит одно соединение на хост, так что
  на новых прогонах это исключено; текущий бан: `fail2ban-client set sshd unbanip <твой_IP>`
  с консоли ноды или подождать bantime=3600).
- Ручной доступ к машине: `ssh -p {{ SSH_PORT }} {{ NEW_USER_LOGIN }}@<IP>` (ключ из `keys/<host>/`).