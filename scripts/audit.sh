#!/usr/bin/env bash
set -uo pipefail

PASS=0; FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo " [OK]    $desc"; ((PASS++))
    else
        echo " [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
    fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён"        "no" "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no" "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"
# TODO 1: порт SSH отличен от 22
SSH_PORT="$(sudo sshd -T | awk '/^port/{print $2}')"
check "Порт SSH отличен от 22" "yes" "$([[ "$SSH_PORT" != "22" ]] && echo yes || echo no)"
# TODO 2: maxauthtries равно 3
check "MaxAuthTries равен 3" "3" "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"
# TODO 3: политика по умолчанию для входящего трафика равна deny
check "Политика входящего трафика: deny" "deny" "$(sudo ufw status verbose | awk '/^Default:/{print $2}')"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "              %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
CERT_MIN_DAYS="${CERT_MIN_DAYS:-30}"      # минимальный остаток срока сертификата, дней
NGINX_T=0; sudo nginx -t >/dev/null 2>&1 || NGINX_T=$?
CERT_OK=0; openssl x509 -checkend $((CERT_MIN_DAYS * 86400)) -noout \
    -in /etc/ssl/certs/devops.crt >/dev/null 2>&1 || CERT_OK=$?
WRITABLE="$(find /var/www/devops-site -perm -o+w 2>/dev/null | wc -l | tr -d ' ')"
KEY_MODE="$(sudo stat -c '%a' /etc/ssl/private/devops.key 2>/dev/null)"
check "Служба nginx активна"                              "active" "$(systemctl is-active nginx)"
check "Конфигурация nginx корректна (nginx -t)"           "0"      "$NGINX_T"
check "Сертификат действует ещё не менее ${CERT_MIN_DAYS} дн." "0"  "$CERT_OK"
check "Нет файлов ресурса с записью для всех; ключ 600"   "0 600"  "$WRITABLE $KEY_MODE"

echo "[5] Контейнеризация"
DB_HEALTH="$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null)"
EXPOSED="$(ss -tln | awk '{print $4}' | grep -E ':(5000|5432)$' | grep -vc '^127\.0\.0\.1:')"
ENV_MODE="$(stat -c '%a' ~/app/.env 2>/dev/null)"
check "Служба docker активна"                            "active"  "$(systemctl is-active docker)"
check "Контейнер СУБД в состоянии healthy"               "healthy" "$DB_HEALTH"
check "Порты 5000 и 5432 слушаются только на 127.0.0.1"  "0"       "$EXPOSED"
check "Права файла ~/app/.env равны 600"                 "600"     "$ENV_MODE"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
