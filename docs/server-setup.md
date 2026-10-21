# Конфигурация виртуальной машины devops-vm

Гипервизор: VMware Fusion (macOS, Apple Silicon). Гостевая ОС: Ubuntu Server 26.04.1 LTS (ARM64).
Адаптация методики: вместо VirtualBox с пробросом порта 127.0.0.1:2222 -> 22 используется прямое
подключение по адресу сети Host-only («Private to my Mac»).

## 1. Параметры машины
- Имя ВМ: `devops-vm`, имя узла: `devops-vm` (FQDN `devops-vm.devops.local`)
- Процессор: 2 ядра
- Оперативная память: 4096 МБ
- Диск: 25 ГБ (NVMe, динамический, LVM; корень `/` ~11 ГБ)
- Установка: Ubuntu Server (не minimized), «Use an entire disk», OpenSSH server, без snap-пакетов
- После установки: `sudo apt update && sudo apt upgrade -y`

## 2. Сетевые интерфейсы
| Интерфейс | Режим Fusion | Тип | Подсеть | Адрес ВМ | Назначение |
|-----------|--------------|-----|---------|----------|------------|
| enp2s0  | Share with my Mac | NAT (vmnet8)       | 172.16.30.0/24 | 172.16.30.132 (DHCP) | выход в интернет |
| enp10s0 | Private to my Mac | Host-only (vmnet1) | 172.16.94.0/24 | 172.16.94.129 (DHCP) | доступ с хоста по SSH |

Адрес хоста (Mac) в сети Host-only: 172.16.94.1. Подсети узнаются командой
`grep SUBNET "/Library/Preferences/VMware Fusion/networking"` (VNET_1 — Host-only, VNET_8 — NAT).
Адреса выдаются DHCP и могут меняться; при смене обновить `~/.ssh/config` и `/etc/hosts` на хосте.

## 3. Правило проброса портов
Проброс портов не используется (в Fusion для Host-only он не нужен). Подключение выполняется
напрямую: хост 172.16.94.1 -> гость 172.16.94.129, порт 2222 (SSH). Запись на хосте в `/etc/hosts`:
`172.16.94.129    devops.local`.

## 4. Учётные записи
| Имя | Группы | Способ аутентификации |
|-----|--------|-----------------------|
| student | student, adm, cdrom, sudo, dip, plugdev, users, lxd (создан установщиком) | пароль (только консоль; по SSH вход запрещён директивой AllowUsers) |
| devops  | devops, sudo, users | по ключу ed25519 (`~/.ssh/devops_vm` на хосте) |

Создание devops:
```
sudo adduser devops
sudo usermod -aG sudo devops
```
Ключ (на хосте): `ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm`
(без парольной фразы), затем `ssh-copy-id -i ~/.ssh/devops_vm.pub devops@172.16.94.129`.
Права: `~/.ssh` — 700, `authorized_keys` — 600. Клиентский `~/.ssh/config` на хосте:
```
Host devops
    HostName 172.16.94.129
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

## 5. Служба SSH
- Порт: 2222 (22 не используется)
- Файл настроек: `/etc/ssh/sshd_config.d/99-hardening.conf` (основной `sshd_config` не изменялся,
  резервная копия `/etc/ssh/sshd_config.backup`)
- Директивы: `Port 2222`, `PermitRootLogin no`, `PasswordAuthentication no`,
  `PubkeyAuthentication yes`, `PermitEmptyPasswords no`, `MaxAuthTries 3`, `LoginGraceTime 30`,
  `AllowUsers devops`, `X11Forwarding no`, `ClientAliveInterval 300`, `ClientAliveCountMax 2`
- Конфликтующий файл: в `/etc/ssh/sshd_config.d/50-cloud-init.conf` строка
  `PasswordAuthentication yes` закомментирована:
  `sudo sed -i 's/^PasswordAuthentication/#PasswordAuthentication/' /etc/ssh/sshd_config.d/50-cloud-init.conf`
- Активация по сокету отключена, служба запускается напрямую:
```
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
```
- Проверка: `sudo sshd -t`, `sudo sshd -T`, `sudo ss -tlnp | grep sshd` (ожидается 0.0.0.0:2222)

## 6. Правила межсетевого экрана (UFW)
- Политики: `default deny incoming`, `default allow outgoing`, routed — disabled
- Логирование: `sudo ufw logging medium` (журнал `/var/log/ufw.log`)
- Правила (порядок: сначала разрешающие, потом `ufw enable`):
```
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw enable
```
- Итог: 80/tcp ALLOW, 443/tcp ALLOW, 2222/tcp LIMIT (для IPv4 и IPv6)
- Имя узла и запись в `/etc/hosts` (строка `127.0.1.1 devops-vm` заменяется на FQDN):
```
sudo hostnamectl set-hostname devops-vm
sudo sed -i 's/^127\.0\.1\.1.*/127.0.1.1 devops-vm.devops.local devops-vm/' /etc/hosts
hostname -f      # ожидается devops-vm.devops.local
```

## 7. Снимки состояния
| Наименование | Момент создания | Состояние |
|--------------|-----------------|-----------|
| 01-clean-install   | 9 октября 2026, 16:22  | чистая установка + `apt upgrade`, пользователь только student |
| 02-keys-configured | 9 октября 2026, 16:33  | создан devops, настроен вход по ключу |
| 03-ssh-hardened    | 9 октября 2026, 16:56  | усилена защита SSH (порт 2222, пароли отключены); файрвол ещё не включён |
| 04-nginx-https     | 10 октября 2026, 15:32 | включены файрвол и имя узла (разделы 4–6, восстановлены с 01-clean-install), установлен Nginx, ресурс devops.local работает по HTTPS (раздел 8) |
| 05-docker-compose  | 21 октября 2026, 13:09 | установлен Docker Engine, проект app (Flask + PostgreSQL) работает в Docker Compose; публикация через Nginx настроена после снимка (раздел 9) |

Файрвол (раздел 6) и имя узла после снимка 03 настраивались без отдельного снимка; в 04 они уже
включены. Снимок 04 создан от 01-clean-install (конфигурация воспроизведена по этому документу).

## 8. Веб-сервер
- Пакет: `nginx` (1.28.3 из репозитория Ubuntu), `sudo apt update && sudo apt install -y nginx`.
  Главный процесс — от root, рабочие — от `www-data`. Слушает 80 и 443 (IPv4 и IPv6).
- Конфигурация ресурса: `/etc/nginx/sites-available/devops-site`, включена ссылкой в
  `/etc/nginx/sites-enabled/devops-site`; стандартный ресурс отключён (удалена ссылка
  `/etc/nginx/sites-enabled/default`, файл в `sites-available` сохранён).
- Каталог ресурса: `/var/www/devops-site`, владелец `devops:devops`, права каталогов 755, файлов 644
  (модель «владелец пишет, веб-сервер читает»); файлов с записью для всех нет. Содержимое
  доставляется из репозитория: `scripts/deploy.sh` (rsync `--delete --chmod=D755,F644`).
- Сертификат: `/etc/ssl/certs/devops.crt`, права 644, владелец root (открытая часть).
  Ключ: `/etc/ssl/private/devops.key`, права 600, владелец root (читает только главный процесс;
  из `/etc/ssl/private` не копировать, в репозиторий не добавлять).
- Формирование самоподписанного сертификата (срок 365 дней: 10.10.2026 – 10.10.2027, SAN
  `DNS:devops.local`):
```
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" \
  -addext "subjectAltName=DNS:devops.local"
```
- Содержимое `/etc/nginx/sites-available/devops-site` (HSTS не используется):
```
server {
    listen 80;
    listen [::]:80;
    server_name devops.local;

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name devops.local;

    ssl_certificate     /etc/ssl/certs/devops.crt;
    ssl_certificate_key /etc/ssl/private/devops.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /var/www/devops-site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    error_page 404 /404.html;

    access_log /var/log/nginx/devops-site.access.log;
    error_log /var/log/nginx/devops-site.error.log;
}
```
- Порядок воспроизведения:
```
sudo mkdir -p /var/www/devops-site && sudo chown -R devops:devops /var/www/devops-site
# создать сертификат (команда выше) и /etc/nginx/sites-available/devops-site (содержимое выше)
sudo ln -s /etc/nginx/sites-available/devops-site /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
scripts/deploy.sh     # на хосте: доставка содержимого каталога site/
```
- Проверка на хосте: сертификат копируется по SSH (`scp devops:/etc/ssl/certs/devops.crt ~/devops.crt`),
  затем `curl --cacert ~/devops.crt -I https://devops.local` (ожидается 200 OK);
  `curl -I http://devops.local` — 301 на `https://devops.local/`.
- Журналы: `/var/log/nginx/devops-site.access.log` и `devops-site.error.log` (блок 80 отдельного журнала
  не имеет и пишет в `/var/log/nginx/access.log`).

## 9. Контейнеризация
- Docker Engine: пакет `docker-ce` 29.9.2 из официального репозитория `download.docker.com`
  (источник `/etc/apt/sources.list.d/docker.sources`, ключ `/etc/apt/keyrings/docker.asc`);
  плагин Compose v5.6.1 (`docker-compose-plugin`), containerd 2.4.2. Пакет `docker.io` из репозитория
  Ubuntu не используется.
- Группа `docker`: только учётная запись `devops` (имеет право sudo). Участник группы фактически
  получает права root, поэтому другие учётные записи в группу не добавляются.
- Проект: `/home/devops/app` (Dockerfile, docker-compose.yml, app.py, requirements.txt,
  .env.example). Содержимое доставляется с хоста: `rsync -avz --delete --exclude=.env app/ devops:app/`
  (исключение `.env` обязательно, иначе `--delete` удалит секреты).
- Файл `.env`: `/home/devops/app/.env`, владелец `devops`, права 600, пароль СУБД сформирован на
  сервере (`openssl rand -hex 16`), в репозиторий и на хост не копируется.
- Сервисы: `app` (образ `devops-app:1.0`, процесс от пользователя `app`, не root) и `db`
  (`postgres:16-alpine`, проверка готовности `pg_isready`, `app` стартует после состояния healthy).
- Публикуемые порты: `127.0.0.1:5000 -> 5000` (приложение, только для Nginx на этой же машине).
  Порт СУБД 5432 не публикуется; приложение находит СУБД по имени `db` в сети проекта.
- Сеть: `app_backend` (bridge). Том с данными: `app_db_data` (`/var/lib/postgresql/data`);
  `docker compose down` том сохраняет, `docker compose down -v` удаляет вместе с базой.
- Обратный прокси-сервер: в HTTPS-блок `/etc/nginx/sites-available/devops-site` добавлено
  расположение `location /app/` с `proxy_pass http://127.0.0.1:5000/;` и заголовками Host, X-Real-IP,
  X-Forwarded-For, X-Forwarded-Proto; статический ресурс сохранён.
- Порядок воспроизведения: установить Docker по инструкции (источник: docs.docker.com/engine/install/ubuntu),
  `sudo usermod -aG docker devops`, доставить `app/`, создать `.env` (см. выше), затем
  `cd ~/app && docker compose up -d --build`, добавить `location /app/` и выполнить
  `sudo nginx -t && sudo systemctl reload nginx`.
- Проверка: `docker compose ps` (db healthy), `curl --cacert ~/devops.crt https://devops.local/app/`,
  `sudo ss -tlnp | grep -E ':(5000|5432)\b'` (только `127.0.0.1:5000`).
