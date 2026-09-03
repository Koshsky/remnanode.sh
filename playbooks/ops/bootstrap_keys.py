#!/usr/bin/env python3
"""Первый контакт со свежеустановленной нодой: положить pub ЕДИНОГО park-ключа
(playbooks/keys/park/id_ed25519.pub) в /root/.ssh/authorized_keys всех нод.

Зачем нужен: после переустановки ОС authorized_keys пуст, а ansible-core 2.21+
не имеет paramiko-плагина, а sshpass без sudo не поставить. Единственный путь
первого входа — пароль root (свежий Ubuntu 24.04 его разрешает), и именно его
использует этот скрипт (paramiko есть в системном python3).

Требования перед запуском:
  - нода переустановлена, у root задан пароль (консоль провайдера), sshd с
    PermitRootLogin yes + PasswordAuthentication yes (fresh default);
  - inventory/hosts.ini актуален: IP, ansible_user=root, ansible_password.

Запуск:  python3 playbooks/ops/bootstrap_keys.py
После этого: ansible-playbook playbooks/provision.yml (root по единому ключу).
"""
import os
import re
import sys

import paramiko

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
INVENTORY = os.path.join(ROOT, 'inventory', 'hosts.ini')
PARK_PUB = os.path.join(HERE, '..', 'keys', 'park', 'id_ed25519.pub')

if not os.path.isfile(PARK_PUB):
    print('нет единого ключа:', PARK_PUB, '— сгенерируй: ssh-keygen -t ed25519 -N \'\' -f playbooks/keys/park/id_ed25519')
    sys.exit(1)
pub = open(PARK_PUB).read().strip()

hosts = []
with open(INVENTORY, encoding='utf-8') as f:
    for line in f:
        m = re.match(
            r"^\s*(\S+)\s+ansible_host=([0-9a-fA-F.:]+)\s+ansible_user=(\S+)\s+ansible_password='([^']*)'",
            line)
        if m:
            hosts.append(m.groups())

if not hosts:
    print('No hosts parsed from', INVENTORY)
    sys.exit(1)

failed = False
for name, ip, user, pw in hosts:
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        c.connect(ip, port=22, username=user, password=pw, timeout=12,
                  banner_timeout=12, auth_timeout=12,
                  allow_agent=False, look_for_keys=False)
        cmd = ("mkdir -p /root/.ssh && chmod 700 /root/.ssh && "
               "touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && "
               f"grep -qF '{pub}' /root/.ssh/authorized_keys || echo '{pub}' >> /root/.ssh/authorized_keys; "
               "echo INSTALLED")
        _, out, err = c.exec_command(cmd, timeout=20)
        print(f'[{name}] ({ip}) {out.read().decode().strip()} {err.read().decode().strip()[:120]}')
        c.close()
    except Exception as ex:
        print(f'[{name}] ({ip}) FAIL: {type(ex).__name__}: {ex}')
        failed = True

print('done. Проверка: ssh -i playbooks/keys/park/id_ed25519 root@<IP> hostname'
      if not failed else 'done with failures')
sys.exit(1 if failed else 0)