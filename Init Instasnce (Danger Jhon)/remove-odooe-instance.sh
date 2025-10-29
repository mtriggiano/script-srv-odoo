#!/bin/bash

set -e

ODOO_ROOT="/home/go/apps/production/odoo-enterprise"
PUERTOS_FILE="$HOME/puertos_ocupados_odoo.txt"
LOGFILE="/var/log/odoo-instances-removal.log"
CF_ZONE_NAME="hospitalprivadosalta.ar"

# Mostrar instancias disponibles
echo "📦 Instancias disponibles:"
ls "$ODOO_ROOT" 2>/dev/null || { echo "⚠️  No se encontraron instancias."; exit 1; }

echo -e "\n🗑️  Nombre de la instancia a eliminar (ej: principal, ventas, crm):"
echo "    (Usa 'principal' o 'main' para la instancia principal imac-production)"
read INSTANCE_INPUT

# Convertir a minúsculas y normalizar
INSTANCE_INPUT=$(echo "$INSTANCE_INPUT" | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g')

# Si es principal/main, usar nombre real de la instancia
if [[ "$INSTANCE_INPUT" == "principal" ]] || [[ "$INSTANCE_INPUT" == "main" ]]; then
  INSTANCE="imac-production"
  DOMAIN="$CF_ZONE_NAME"
  DB_NAME="imac-production"
else
  INSTANCE="$INSTANCE_INPUT"
  DOMAIN="$INSTANCE.$CF_ZONE_NAME"
  DB_NAME="$INSTANCE"
fi

BASE_DIR="$ODOO_ROOT/$INSTANCE"
INFO_FILE="$BASE_DIR/info-instancia.txt"
NGINX_CONF="/etc/nginx/sites-available/$INSTANCE"
NGINX_LINK="/etc/nginx/sites-enabled/$INSTANCE"
LOG_PATH="/tmp/odoo-create-$INSTANCE.log"

# Detectar servicio systemd (nombre sin extensión)
SERVICE_NAME=""
if [[ -f "$INFO_FILE" ]]; then
  SERVICE_NAME=$(grep "🧩 Servicio systemd:" "$INFO_FILE" | awk '{print $4}' | sed 's/.*\///;s/\.service$//')
else
  # Buscar servicios odoo19e, odoo18e, odoo18
  [[ -f "/etc/systemd/system/odoo19e-$INSTANCE.service" ]] && SERVICE_NAME="odoo19e-$INSTANCE"
  [[ -f "/etc/systemd/system/odoo18e-$INSTANCE.service" ]] && SERVICE_NAME="odoo18e-$INSTANCE"
  [[ -f "/etc/systemd/system/odoo18-$INSTANCE.service" ]] && SERVICE_NAME="odoo18-$INSTANCE"
fi

# Detectar puerto asignado desde info-instancia.txt
if [[ -f "$INFO_FILE" ]]; then
  PORT=$(grep "🛠️ Puerto:" "$INFO_FILE" | awk '{print $3}')
else
  PORT=""
fi

# Validar existencia
if [[ ! -d "$BASE_DIR" ]]; then
  echo "❌ La instancia '$INSTANCE' no existe en $ODOO_ROOT."
  exit 1
fi

# Confirmación explícita
echo -e "\n⚠️  Esta acción eliminará todos los datos de '$INSTANCE'."
echo "Para confirmar, escribí exactamente: BORRAR$INSTANCE"
read -p "> " CONFIRM

if [[ "$CONFIRM" != "BORRAR$INSTANCE" ]]; then
  echo "❌ Confirmación incorrecta. Abortando."
  exit 1
fi

# Cloudflare API
CF_API_TOKEN="JK1cCBg776SHiZX9T6Ky5b2gtjMkpUsNHxVyQ0Vs"
CF_ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CF_ZONE_NAME" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')

# Detener y eliminar servicio
if [[ -n "$SERVICE_NAME" ]]; then
  echo "❌ Deteniendo y eliminando servicio systemd '$SERVICE_NAME'..."
  sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  sudo rm -f "/etc/systemd/system/$SERVICE_NAME.service"
  sudo rm -f "/etc/systemd/system/multi-user.target.wants/$SERVICE_NAME.service"
else
  echo "⚠️  No se encontró el nombre del servicio para eliminar."
fi

echo "🗄️  Eliminando base de datos PostgreSQL..."
sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME';" >/dev/null 2>&1 || true
sudo -u postgres dropdb "$DB_NAME" >/dev/null 2>&1 || true

echo "🧽 Eliminando carpeta de instancia..."
sudo rm -rf "$BASE_DIR"

echo "🧹 Borrando log temporal si existe..."
sudo rm -f "$LOG_PATH"

echo "🌐 Eliminando configuración Nginx..."
sudo rm -f "$NGINX_CONF" "$NGINX_LINK"
sudo nginx -t && sudo systemctl reload nginx

echo "🔐 Eliminando certificado SSL (Certbot)..."
sudo certbot delete --cert-name "$DOMAIN" --non-interactive >/dev/null 2>&1 || true

echo "☁️ Eliminando subdominio de Cloudflare ($DOMAIN)..."
DNS_RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$DOMAIN" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')

if [[ "$DNS_RECORD_ID" != "null" && -n "$DNS_RECORD_ID" ]]; then
  curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$DNS_RECORD_ID" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" > /dev/null
  echo "✅ Subdominio $DOMAIN eliminado de Cloudflare."
else
  echo "⚠️  No se encontró registro DNS para $DOMAIN en Cloudflare."
fi

# Limpiar puerto usado
if [[ -n "$PORT" ]]; then
  sed -i "/^$PORT$/d" "$PUERTOS_FILE"
  echo "🔓 Puerto $PORT liberado en $PUERTOS_FILE"
else
  echo "⚠️  No se detectó el puerto. Verificá manualmente si querés liberar algún registro."
fi

echo "🔁 Recargando systemd..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload

# Registrar acción en vitácora
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "$TIMESTAMP - Instancia: $INSTANCE - Puerto: ${PORT:-N/A} - Dominio: $DOMAIN - Eliminada OK" | sudo tee -a "$LOGFILE" >/dev/null

echo "✅ Instancia '$INSTANCE' eliminada completamente."

# Mostrar puertos aún registrados
if [[ -f "$PUERTOS_FILE" && -s "$PUERTOS_FILE" ]]; then
  echo -e "\n📊 Puertos registrados como ocupados:"
  sort -n "$PUERTOS_FILE"
else
  echo -e "\n🟢 No quedan puertos registrados como ocupados."
fi