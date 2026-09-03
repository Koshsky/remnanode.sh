# remnanode.sh — Ansible-провижининг ремнанод (Ubuntu 24.04)

Полная настройка свежих машин **Ubuntu 24.04 (noble)** через Ansible:
безопасность (SSH-ключи, fail2ban, UFW), обновления (в т.ч. unattended-upgrades),
Docker, SSL (certbot), nginx, RemnaNode и мониторинг парка (Beszel).

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
cp group_vars/all/vars.yml.template group_vars/all/vars.yml   # заполнить (gitignored)
```

### Переменные (group_vars/all/vars.yml)

| Переменная | Обязательная | Описание |
|---|---|---|
| `NEW_USER_LOGIN` / `NEW_USER_PASSWORD` | да | Пользователь (sudo) и его пароль |
| `EMAIL` | да | Почта для certbot |
| `REMNAWAVE_SECRET_KEY` | да | Секрет RemnaWave |
| `DOMAIN_ZONE` | да | Домен: DOMAIN = `<hostname>.<DOMAIN_ZONE>` (hostname = имя хоста в инвентаре) |
| `SSH_PORT` | нет | Порт SSH, по умолчанию 222 |
| `XRAY_PORT` / `REMNANODE_PORT` | нет | Порт Xray (443) / RemnaNode (8443) |
| `AUTO_REBOOT` | нет | `daily`, `weekly` или пусто (выкл) — авто-перезагрузка в 5:00 |
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

## Что делает playbook

1. Генерирует ключи, ставит hostname (имя из инвентаря) и обновляет систему.
2. Пакеты: Docker CE (+ compose plugin), fail2ban, ufw, certbot, openssh-server, sudo, unattended-upgrades.
3. Пользователь + SSH-ключи (root и user) → sshd (свой порт, root-пароль и пароли запрещены).
4. fail2ban (sshd, nginx-http-auth, nginx-limit-req) и UFW (default deny).
5. SSL (certbot standalone на свободном 80) → nginx в Docker → RemnaNode (образ пинится 2.7.0).
6. Cron: продление сертификатов (03:00), zapret.dat (02:00/14:00), опц. перезагрузка; logrotate.
7. Beszel-агент (если задан) + опциональное UFW-правило для SSH-режима.

## Мониторинг (Beszel)

Hub — отдельная машина (`beszel/server/`, см. ниже). Новая нода добавляется через
инвентарь и `.env`-переменные, конфиг hub не правится.

```bash
# hub на отдельном VPS:
cd beszel/server && cp .env.example .env && docker compose up -d
# UI: http://IP:8090 → Add System → KEY/TOKEN → в group_vars/all/vars.yml →
# проиграть provision.yml
```

## Структура

```
ansible.cfg, requirements.yml
inventory/                   # hosts.example.ini (шаблон), hosts.ini (gitignored)
group_vars/all/vars.yml.template
playbooks/provision.yml      # полная настройка ноды
playbooks/ops/rekey.yml      # перевыпуск ключей
keys/                        # gitignored: сгенерированные ключи по хостам
roles/
  base/          hostname, apt, пакеты, unattended-upgrades
  security/      пользователь, sshd_config.j2, ключи, fail2ban, ufw
  docker/        Docker CE + compose plugin
  certbot/       SSL-сертификат (standalone)
  nginx/         /opt/nginx (conf.j2, статика, логи)
  remnanode/     compose.j2 + zapret cron
  beszel/        агент (compose.j2) + UFW-правило
  maintenance/   cron (renew/reboot), logrotate
beszel/server/   hub-композ (разворачивается отдельно на VPS)
```

## Устранение неполадок

- `Все порты молчат, таймауты` — пакеты не доходят до машины: проверь публичный IP
  ноды (`curl -s ifconfig.me` на ней), DNS, фаервол/панель провайдера.
- `401 от Beszel` — ключ/токен не совпадают с hub: перевыпустить через Add System.
- Ручной доступ к машине: `ssh -p {{ SSH_PORT }} {{ NEW_USER_LOGIN }}@<IP>` (ключ из `keys/<host>/`).