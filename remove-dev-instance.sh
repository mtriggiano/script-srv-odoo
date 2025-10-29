#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 🗑️ Script para eliminar instancias de desarrollo Odoo 19 Enterprise

set -e

DEV_ROOT="/home/go/apps/develop/odoo-enterprise"
PUERTOS_FILE="$HOME/puertos_ocupados_odoo.txt"
DEV_INSTANCES_FILE="$HOME/dev-instances.txt"
LOGFILE="/var/log/odoo-dev-instances-removal.log"
CF_ZONE_NAME="hospitalprivadosalta.ar"
CF_API_TOKEN="JK1cCBg776SHiZX9T6Ky5b2gtjMkpUsNHxVyQ0Vs"

# Mostrar instancias de desarrollo disponibles
echo "📦 Instancias de desarrollo disponibles:"
if [[ -d "$DEV_ROOT" ]] && [[ -n "$(ls -A $DEV_ROOT 2>/dev/null)" ]]; then
  ls -1 "$DEV_ROOT" | sed 's/^/  - /'
else
  echo "  ⚠️  No se encontraron instancias de desarrollo."
  exit 1
fi

echo -e "\n🗑️  Nombre de la instancia de desarrollo a eliminar:"
echo "   (Escribe solo el nombre, ej: juan, maria, testing)"
read -p "> " DEV_INPUT

# Validar entrada
if [[ -z "$DEV_INPUT" ]]; then
  echo "❌ Debes proporcionar un nombre."
  exit 1
fi

# Normalizar y construir nombre completo
DEV_INPUT=$(echo "$DEV_INPUT" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

# Si el usuario ya escribió "dev-", no duplicar
if [[ "$DEV_INPUT" == dev-* ]]; then
  INSTANCE="$DEV_INPUT"
else
  INSTANCE="dev-$DEV_INPUT"
fi

BASE_DIR="$DEV_ROOT/$INSTANCE"
INFO_FILE="$BASE_DIR/info-instancia.txt"

# Validar existencia
if [[ ! -d "$BASE_DIR" ]]; then
  echo "❌ La instancia '$INSTANCE' no existe en $DEV_ROOT."
  exit 1
fi

# Detectar configuración desde info-instancia.txt
if [[ -f "$INFO_FILE" ]]; then
  DB_NAME=$(grep "Base de datos:" "$INFO_FILE" | cut -d':' -f2 | xargs)
  PORT=$(grep "Puerto:" "$INFO_FILE" | cut -d':' -f2 | xargs)
  DOMAIN=$(grep "Dominio:" "$INFO_FILE" | cut -d':' -f2 | xargs | sed 's|https://||')
  SERVICE_NAME=$(grep "Servicio systemd:" "$INFO_FILE" | cut -d':' -f2 | xargs)
else
  # Intentar detectar automáticamente
  DB_NAME="dev-${INSTANCE#dev-}-imac-production"
  DOMAIN="$INSTANCE.$CF_ZONE_NAME"
  SERVICE_NAME="odoo19e-$INSTANCE"
  PORT=""
fi

NGINX_CONF="/etc/nginx/sites-available/$INSTANCE"
NGINX_LINK="/etc/nginx/sites-enabled/$INSTANCE"
LOG_PATH="/tmp/odoo-create-dev-$INSTANCE.log"

echo ""
echo "📋 Información de la instancia a eliminar:"
echo "   Nombre: $INSTANCE"
echo "   Base de datos: $DB_NAME"
echo "   Dominio: $DOMAIN"
echo "   Servicio: $SERVICE_NAME"
echo "   Puerto: ${PORT:-N/A}"
echo "   Ubicación: $BASE_DIR"
echo ""

# Confirmación explícita
echo "⚠️  Esta acción eliminará TODOS los datos de '$INSTANCE'."
echo "Para confirmar, escribí exactamente: BORRAR$INSTANCE"
read -p "> " CONFIRM

if [[ "$CONFIRM" != "BORRAR$INSTANCE" ]]; then
  echo "❌ Confirmación incorrecta. Abortando."
  exit 1
fi

echo ""
echo "🗑️  Iniciando eliminación de instancia de desarrollo..."

# Cloudflare API
CF_ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CF_ZONE_NAME" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')

# Detener y eliminar servicio
if [[ -n "$SERVICE_NAME" ]]; then
  echo "⏹️  Deteniendo y eliminando servicio systemd '$SERVICE_NAME'..."
  sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  sudo rm -f "/etc/systemd/system/$SERVICE_NAME.service"
  sudo rm -f "/etc/systemd/system/multi-user.target.wants/$SERVICE_NAME.service"
else
  echo "⚠️  No se encontró el nombre del servicio para eliminar."
fi

# Eliminar base de datos
echo "🗄️  Eliminando base de datos PostgreSQL '$DB_NAME'..."
sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME';" >/dev/null 2>&1 || true
if sudo -u postgres dropdb "$DB_NAME" 2>&1; then
  echo "✅ Base de datos '$DB_NAME' eliminada correctamente."
else
  echo "⚠️  La base de datos '$DB_NAME' no existía o ya fue eliminada."
fi

# Eliminar carpeta de instancia
echo "🧽 Eliminando carpeta de instancia..."
sudo rm -rf "$BASE_DIR"

# Borrar log temporal
echo "🧹 Borrando log temporal si existe..."
sudo rm -f "$LOG_PATH"

# Eliminar configuración Nginx
echo "🌐 Eliminando configuración Nginx..."
sudo rm -f "$NGINX_CONF" "$NGINX_LINK"
sudo nginx -t && sudo systemctl reload nginx

# Eliminar certificado SSL
echo "🔐 Eliminando certificado SSL (Certbot)..."
sudo certbot delete --cert-name "$DOMAIN" --non-interactive >/dev/null 2>&1 || true

# Eliminar subdominio de Cloudflare
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
fi

# Eliminar registro de instancia de desarrollo
if [[ -f "$DEV_INSTANCES_FILE" ]]; then
  sed -i "/^$INSTANCE|/d" "$DEV_INSTANCES_FILE"
  echo "📝 Registro eliminado de $DEV_INSTANCES_FILE"
fi

# Recargar systemd
echo "🔁 Recargando systemd..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload

# Registrar acción en bitácora
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "$TIMESTAMP - Instancia DEV: $INSTANCE - Puerto: ${PORT:-N/A} - Dominio: $DOMAIN - BD: $DB_NAME - Eliminada OK" | sudo tee -a "$LOGFILE" >/dev/null

echo ""
echo "✅ Instancia de desarrollo '$INSTANCE' eliminada completamente."

# Mostrar instancias restantes
if [[ -d "$DEV_ROOT" ]] && [[ -n "$(ls -A $DEV_ROOT 2>/dev/null)" ]]; then
  echo -e "\n📦 Instancias de desarrollo restantes:"
  ls -1 "$DEV_ROOT" | sed 's/^/  - /'
else
  echo -e "\n🟢 No quedan instancias de desarrollo."
fi

# Mostrar puertos registrados
if [[ -f "$PUERTOS_FILE" && -s "$PUERTOS_FILE" ]]; then
  echo -e "\n📊 Puertos registrados como ocupados:"
  sort -n "$PUERTOS_FILE" | sed 's/^/  - /'
else
  echo -e "\n🟢 No quedan puertos registrados como ocupados."
fi
