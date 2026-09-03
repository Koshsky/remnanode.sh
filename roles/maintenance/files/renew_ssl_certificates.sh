#!/bin/bash
# Скрипт для автоматического обновления SSL сертификатов с использованием webroot

set -e

LOG_FILE="/var/log/ssl_renewal.log"
WEBROOT_PATH="/var/www/certbot"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Начало процедуры обновления SSL сертификатов" >> "$LOG_FILE"

# Проверяем, нужно ли обновление (опционально)
if certbot renew --dry-run >> "$LOG_FILE" 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Проверка обновления прошла успешно" >> "$LOG_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Предупреждение: Проверка обновления не прошла, но продолжаем" >> "$LOG_FILE"
fi

# Обновляем сертификаты в режиме webroot
echo "$(date '+%Y-%m-%d %H:%M:%S') - Запуск обновления сертификатов" >> "$LOG_FILE"
if certbot renew --quiet --webroot --webroot-path "$WEBROOT_PATH"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Сертификаты успешно обновлены" >> "$LOG_FILE"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Nginx автоматически использует новые сертификаты" >> "$LOG_FILE"
    
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ОШИБКА: Не удалось обновить сертификаты" >> "$LOG_FILE"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Процедура обновления SSL сертификатов завершена успешно" >> "$LOG_FILE"
