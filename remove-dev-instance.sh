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
echo "   (Escribe el nombre completo como aparece arriba, ej: dev-mtg, dev-dev-nacho)"
read -p "> " DEV_INPUT

# Validar entrada
if [[ -z "$DEV_INPUT" ]]; then
  echo "❌ Debes proporcionar un nombre."
  exit 1
fi

# Normalizar entrada
DEV_INPUT=$(echo "$DEV_INPUT" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

# Buscar la instancia exacta en el directorio
INSTANCE=""
if [[ -d "$DEV_ROOT/$DEV_INPUT" ]]; then
  # El nombre ingresado existe tal cual
  INSTANCE="$DEV_INPUT"
elif [[ -d "$DEV_ROOT/dev-$DEV_INPUT" ]]; then
  # Agregar prefijo "dev-" si no lo tiene
  INSTANCE="dev-$DEV_INPUT"
else
  # Buscar coincidencia parcial
  MATCHES=$(ls -1 "$DEV_ROOT" 2>/dev/null | grep -i "$DEV_INPUT" || true)
  MATCH_COUNT=$(echo "$MATCHES" | grep -c . || echo 0)
  
  if [[ $MATCH_COUNT -eq 1 ]]; then
    INSTANCE="$MATCHES"
    echo "ℹ️  Encontrada instancia: $INSTANCE"
  elif [[ $MATCH_COUNT -gt 1 ]]; then
    echo "❌ Múltiples instancias coinciden con '$DEV_INPUT':"
    echo "$MATCHES" | sed 's/^/  - /'
    echo "Por favor, especifica el nombre completo."
    exit 1
  else
    echo "❌ No se encontró ninguna instancia que coincida con '$DEV_INPUT'."
    exit 1
  fi
fi

BASE_DIR="$DEV_ROOT/$INSTANCE"
INFO_FILE="$BASE_DIR/info-instancia.txt"

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

if [[ -z "$CF_ZONE_ID" || "$CF_ZONE_ID" == "null" ]]; then
  echo "⚠️  No se pudo obtener el Zone ID de Cloudflare. Verifica el token y el nombre de zona."
else
  echo "   Zone ID: $CF_ZONE_ID"
  
  # Buscar registro DNS
  DNS_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$DOMAIN" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json")
  
  DNS_RECORD_ID=$(echo "$DNS_RESPONSE" | jq -r '.result[0].id')
  
  if [[ "$DNS_RECORD_ID" != "null" && -n "$DNS_RECORD_ID" ]]; then
    echo "   Registro DNS encontrado: $DNS_RECORD_ID"
    
    DELETE_RESPONSE=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$DNS_RECORD_ID" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json")
    
    DELETE_SUCCESS=$(echo "$DELETE_RESPONSE" | jq -r '.success')
    
    if [[ "$DELETE_SUCCESS" == "true" ]]; then
      echo "✅ Subdominio $DOMAIN eliminado de Cloudflare."
    else
      echo "⚠️  Error al eliminar de Cloudflare:"
      echo "$DELETE_RESPONSE" | jq -r '.errors[]?.message' 2>/dev/null || echo "   Error desconocido"
    fi
  else
    echo "⚠️  No se encontró registro DNS para $DOMAIN en Cloudflare."
    echo "   Respuesta de API: $(echo "$DNS_RESPONSE" | jq -r '.result | length') registros encontrados"
  fi
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
