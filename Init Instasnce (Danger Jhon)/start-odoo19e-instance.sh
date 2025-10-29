#!/bin/bash

# 🚀 Script de creación de instancia Odoo 19 Enterprise - Versión mejorada
# Fecha de actualización: 2025-07-17 18:08:02

# 1. Validaciones
command -v jq >/dev/null 2>&1 || { echo >&2 "❌ 'jq' no está instalado."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "❌ 'curl' no está instalado."; exit 1; }

ODOO_ROOT="/home/go/apps/production/odoo-enterprise"
REPO="/home/go/apps/repo/odoo19e.zip"
PYTHON="/usr/bin/python3.12"
PUERTOS_FILE="$HOME/puertos_ocupados_odoo.txt"
USER="go"
DB_USER="go"
DB_PASSWORD="!Phax3312!IMAC"
ADMIN_PASSWORD="!Phax3312!IMAC"
CF_API_TOKEN="JK1cCBg776SHiZX9T6Ky5b2gtjMkpUsNHxVyQ0Vs"
CF_ZONE_NAME="hospitalprivadosalta.ar"
CF_EMAIL="info@info.com"
PUBLIC_IP="200.69.140.2"

# 2. Instancia
RAW_NAME="$1"
if [[ -z "$RAW_NAME" ]]; then echo "❌ Debes pasar el nombre de la instancia."; exit 1; fi
INSTANCE=$(echo "$RAW_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g')

# Si es la instancia principal, usar nombre específico
if [[ "$INSTANCE" == "principal" ]] || [[ "$INSTANCE" == "main" ]]; then
  INSTANCE_NAME="imac-production"
  USE_ROOT_DOMAIN=true
else
  INSTANCE_NAME="$INSTANCE"
  USE_ROOT_DOMAIN=false
fi

LOG="/tmp/odoo-create-$INSTANCE_NAME.log"
# Redirigir salida tanto a pantalla como a log
exec > >(tee -a "$LOG") 2>&1

echo "🚀 Iniciando creación de instancia Odoo: $INSTANCE_NAME"

# Cancelación segura
trap cleanup SIGINT
cleanup() {
  echo -e "\n❌ Cancelado."
  [[ -d "$ODOO_ROOT/$INSTANCE_NAME" ]] && rm -rf "$ODOO_ROOT/$INSTANCE_NAME"
  sudo -u postgres dropdb "$INSTANCE_NAME" 2>/dev/null || true
  sed -i "/^$PORT$/d" "$PUERTOS_FILE" 2>/dev/null || true
  exit 1
}

echo "🔍 Buscando puerto libre..."
# 3. Puerto libre
# Verificar si ya existe configuración previa para esta instancia
if [[ -f "$ODOO_ROOT/$INSTANCE_NAME/odoo.conf" ]]; then
  EXISTING_PORT=$(grep "^http_port" "$ODOO_ROOT/$INSTANCE_NAME/odoo.conf" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
  if [[ -n "$EXISTING_PORT" ]]; then
    PORT=$EXISTING_PORT
    echo "✅ Reutilizando puerto existente: $PORT"
  fi
fi

# Si no hay puerto asignado, buscar uno libre
if [[ -z "$PORT" ]]; then
  for p in {2100..3000}; do
    if ! grep -q "^$p$" "$PUERTOS_FILE" 2>/dev/null && ! lsof -iTCP:$p -sTCP:LISTEN -t >/dev/null; then
      PORT=$p
      # NO escribir en el archivo aún, se hará al final si todo sale bien
      break
    fi
  done
  [[ -z "$PORT" ]] && echo "❌ No hay puerto libre." && exit 1
  echo "✅ Puerto asignado: $PORT"
fi

# Configurar dominio según tipo de instancia
if [[ "$USE_ROOT_DOMAIN" == true ]]; then
  DOMAIN="$CF_ZONE_NAME"
else
  DOMAIN="$INSTANCE_NAME.$CF_ZONE_NAME"
fi

BASE_DIR="$ODOO_ROOT/$INSTANCE_NAME"
SERVICE="/etc/systemd/system/odoo19e-$INSTANCE_NAME.service"
ODOO_CONF="$BASE_DIR/odoo.conf"
ODOO_LOG="$BASE_DIR/odoo.log"
NGINX_CONF="/etc/nginx/sites-available/$INSTANCE_NAME"
INFO_FILE="$BASE_DIR/info-instancia.txt"
VENV_DIR="$BASE_DIR/venv"
ODOO_BIN="$BASE_DIR/odoo-server/odoo-bin"
VENV_PYTHON="$VENV_DIR/bin/python3"
APP_DIR="$BASE_DIR"

echo "🌐 Dominio configurado: $DOMAIN"

# 4. DNS
echo "🌍 IP pública configurada: $PUBLIC_IP"
CF_ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CF_ZONE_NAME" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" | jq -r '.result[0].id')
echo "🌐 Configurando DNS en Cloudflare para $DOMAIN..."
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data '{"type":"A","name":"'"$DOMAIN"'","content":"'"$PUBLIC_IP"'","ttl":3600,"proxied":true}' >/dev/null

MAX_WAIT=60; SECONDS_WAITED=0; SPINNER='|/-\'
echo "🛰️  Esperando propagación DNS de $DOMAIN (máximo $MAX_WAIT segundos)..."
while (( SECONDS_WAITED < MAX_WAIT )); do
  if dig +short "$DOMAIN" | grep -q "$PUBLIC_IP"; then echo -e "\n✅ DNS resuelto."; break; fi
  printf "\r⌛ %02ds esperando... %c" "$SECONDS_WAITED" "${SPINNER:SECONDS_WAITED%4:1}"
  sleep 1; ((SECONDS_WAITED++))
done

# 5. Setup
echo "📁 Creando estructura de carpetas en $BASE_DIR..."
mkdir -p "$BASE_DIR"
cd "$BASE_DIR" || exit 1
echo "📁 Creando carpeta de instancia y custom_addons en $BASE_DIR..."
mkdir -p "$BASE_DIR"
mkdir -p "$BASE_DIR/custom_addons"
mkdir -p "$BASE_DIR/odoo-server"
echo "📦 Descomprimiendo repositorio en $BASE_DIR/odoo-server..."
unzip "$REPO" -d "$BASE_DIR/tmp_unzip"
cp "$BASE_DIR/tmp_unzip/setup.py" "$BASE_DIR/odoo-server/"
cp "$BASE_DIR/tmp_unzip/requirements19e.txt" "$BASE_DIR/odoo-server/requirements.txt"
cp -r "$BASE_DIR/tmp_unzip/odoo" "$BASE_DIR/odoo-server/"
# Copiar odoo-bin y setup si existen
if [[ -f "$BASE_DIR/tmp_unzip/odoo-bin" ]]; then
  cp "$BASE_DIR/tmp_unzip/odoo-bin" "$BASE_DIR/odoo-server/"
  chmod +x "$BASE_DIR/odoo-server/odoo-bin"
fi
if [[ -d "$BASE_DIR/tmp_unzip/setup" ]]; then
  cp -r "$BASE_DIR/tmp_unzip/setup" "$BASE_DIR/odoo-server/"
fi
rm -rf "$BASE_DIR/tmp_unzip"

# Verificar que la carpeta odoo existe
if [[ ! -d "$BASE_DIR/odoo-server/odoo" ]]; then
  echo "❌ Error: Carpeta 'odoo' no encontrada en el repositorio descomprimido."
  exit 1
fi

# Verificar que odoo-bin existe, si no, crearlo
if [[ ! -f "$BASE_DIR/odoo-server/odoo-bin" ]]; then
  echo "⚠️  'odoo-bin' no encontrado en el ZIP. Creándolo automáticamente..."
  cat > "$BASE_DIR/odoo-server/odoo-bin" <<'ODOOBIN'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys
import os

# Agregar el directorio de odoo al path
odoo_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, odoo_dir)

if __name__ == "__main__":
    from odoo.cli import main
    main()
ODOOBIN
  chmod +x "$BASE_DIR/odoo-server/odoo-bin"
  echo "✅ odoo-bin creado exitosamente."
fi


echo "🐍 Creando entorno virtual Python..."
$PYTHON -m venv "$VENV_DIR"
echo "💡 Activando entorno virtual..."
source "$VENV_DIR/bin/activate"
echo "⬆️  Actualizando pip y wheel..."
pip install --upgrade pip wheel
echo "📦 Instalando requerimientos Python..."
pip install -r "$BASE_DIR/odoo-server/requirements.txt"

echo "🗑️ Limpiando base de datos existente si existe..."
sudo -u postgres dropdb "$INSTANCE_NAME" 2>/dev/null
echo "🛢️  Creando base de datos $INSTANCE_NAME..."
sudo -u postgres createdb "$INSTANCE_NAME" -O "$DB_USER" --encoding='UTF8'

echo "⚙️ Generando archivo de configuración Odoo..."
cat > "$ODOO_CONF" <<EOF
[options]
addons_path = $BASE_DIR/odoo-server/odoo/addons,$BASE_DIR/custom_addons
db_host = localhost
db_port = 5432
db_user = $DB_USER
db_password = $DB_PASSWORD
db_name = $INSTANCE_NAME
log_level = info
logfile = $ODOO_LOG
http_port = $PORT
http_interface = 127.0.0.1
proxy_mode = True
admin_passwd = $ADMIN_PASSWORD
workers = 0
max_cron_threads = 1
db_maxconn = 8
EOF

touch "$ODOO_LOG"
chown -R $USER:$USER "$BASE_DIR"

echo "⚙️ Creando servicio systemd para Odoo..."
echo "[Unit]
Description=Odoo 19e Instance - $INSTANCE_NAME
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=$VENV_PYTHON $BASE_DIR/odoo-server/odoo-bin -c $APP_DIR/odoo.conf
WorkingDirectory=$APP_DIR
StandardOutput=journal
StandardError=inherit
Restart=always

[Install]
WantedBy=multi-user.target
" | sudo tee /etc/systemd/system/odoo19e-$INSTANCE_NAME.service > /dev/null

if [ ! -f "/etc/systemd/system/odoo19e-$INSTANCE_NAME.service" ]; then
  echo "❌ Error crítico: No se pudo crear el archivo de servicio systemd /etc/systemd/system/odoo19e-$INSTANCE_NAME.service"
  exit 1
fi

echo "🔄 Recargando systemd y habilitando servicio..."
sudo systemctl daemon-reload
echo "🌀 Habilitando servicio systemd (sin iniciar aún)..."
sudo systemctl enable "odoo19e-$INSTANCE_NAME"

# 6. Módulos y assets
echo "🔌 Cerrando conexiones existentes a la base de datos..."
sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$INSTANCE_NAME' AND pid <> pg_backend_pid();" 2>/dev/null || true

echo "📦 Instalando módulos iniciales y configurando entorno Odoo..."
echo "   Esto puede tomar varios minutos..."
sudo -u $USER "$VENV_PYTHON" "$BASE_DIR/odoo-server/odoo-bin" -c "$ODOO_CONF" --load-language=es_ES -i base,web,base_setup,web_enterprise,contacts,l10n_latam_base,l10n_ar,l10n_ar_reports --without-demo=all --stop-after-init

if [ $? -ne 0 ]; then
  echo "❌ Error al instalar módulos iniciales. Revisa el log en $ODOO_LOG"
  exit 1
fi
echo "✅ Módulos iniciales instalados correctamente."

echo "🌎 Configurando idioma, zona horaria y moneda..."
sudo -u $USER "$VENV_PYTHON" "$BASE_DIR/odoo-server/odoo-bin" shell -d "$INSTANCE_NAME" <<EOF
lang = env['res.lang'].search([('code', '=', 'es_AR')], limit=1)
if lang:
    env.user.lang = 'es_AR'
    env.user.tz = 'America/Argentina/Buenos_Aires'
    env.user.company_id.write({'currency_id': env.ref('base.ARS').id})
EOF

echo "🎨 Actualizando módulos..."
sudo -u $USER "$VENV_PYTHON" "$BASE_DIR/odoo-server/odoo-bin" -c "$ODOO_CONF" --update=all --stop-after-init

if [ $? -ne 0 ]; then
  echo "⚠️  Advertencia: Error al actualizar módulos. Continuando..."
fi

echo "🚀 Iniciando servicio Odoo..."
sudo systemctl start "odoo19e-$INSTANCE_NAME"
sleep 3

if sudo systemctl is-active --quiet "odoo19e-$INSTANCE_NAME"; then
  echo "✅ Servicio Odoo iniciado correctamente."
else
  echo "❌ Error: El servicio no pudo iniciarse. Revisa los logs:"
  echo "   sudo journalctl -u odoo19e-$INSTANCE_NAME -n 50"
  exit 1
fi

# 7. Nginx y SSL
[[ -L "/etc/nginx/sites-enabled/$INSTANCE_NAME" ]] && sudo rm -f "/etc/nginx/sites-enabled/$INSTANCE_NAME"

echo "🔍 Verificando si ya existe certificado SSL para $DOMAIN..."
if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    echo "🚫 Certificado no encontrado. Creando configuración HTTP temporal..."
    
    # Crear configuración HTTP simple temporal
    echo "server {
    listen 80;
    server_name $DOMAIN;

    client_max_body_size 20M;

    # Bloquear acceso al gestor de bases de datos
    location ~* ^/web/database/(manager|selector|create|duplicate|drop|backup|restore|change_password) {
        deny all;
        return 403;
    }

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_read_timeout 720s;
    }
}" | sudo tee /etc/nginx/sites-available/$INSTANCE_NAME > /dev/null
    
    sudo ln -s /etc/nginx/sites-available/$INSTANCE_NAME /etc/nginx/sites-enabled/$INSTANCE_NAME
    
    echo "🔄 Recargando Nginx con configuración HTTP..."
    sudo nginx -t && sudo systemctl reload nginx || sudo systemctl start nginx
    
    echo "📜 Obteniendo certificado SSL con Certbot..."
    sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN --redirect
    
    echo "✅ Certificado SSL obtenido y configurado automáticamente por Certbot"
else
    echo "✅ Certificado SSL ya existe. Creando configuración con HTTPS..."
    
    # Crear configuración con SSL
    echo "map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    server_name $DOMAIN;

    client_max_body_size 20M;

    # Bloquear acceso al gestor de bases de datos
    location ~* ^/web/database/(manager|selector|create|duplicate|drop|backup|restore|change_password) {
        deny all;
        return 403;
    }

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_http_version 1.1;
        proxy_read_timeout 720s;
    }

    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}

server {
    if (\$host = $DOMAIN) {
        return 301 https://\$host\$request_uri;
    }

    listen 80;
    server_name $DOMAIN;
    return 404;
}" | sudo tee /etc/nginx/sites-available/$INSTANCE_NAME > /dev/null
    
    sudo ln -s /etc/nginx/sites-available/$INSTANCE_NAME /etc/nginx/sites-enabled/$INSTANCE_NAME
    
    echo "🔄 Recargando Nginx con configuración HTTPS..."
    sudo nginx -t && sudo systemctl reload nginx
fi

echo "✅ Nginx configurado correctamente para $DOMAIN"


echo "📄 Generando archivo de información de la instancia..."
# 8. Info
cat > "$INFO_FILE" <<EOF
🔧 Instancia: $INSTANCE_NAME
🌍 Dominio: https://$DOMAIN
🛠️ Puerto: $PORT
🗄️ Base de datos: $INSTANCE_NAME
👤 Usuario DB: $DB_USER
🔑 Contraseña DB: $DB_PASSWORD
📁 Ruta: $BASE_DIR
📄 Configuración: $ODOO_CONF
📝 Log: $ODOO_LOG
🪵 Log de instalación: $LOG
🧩 Servicio systemd: odoo19e-$INSTANCE_NAME
🌀 Logs: sudo journalctl -u odoo19e-$INSTANCE_NAME -n 50 --no-pager
🌐 Nginx: $NGINX_CONF
🕒 Zona horaria: America/Argentina/Buenos_Aires
🌐 IP pública: $PUBLIC_IP
🔁 Reiniciar servicio: sudo systemctl restart odoo19e-$INSTANCE_NAME
📋 Ver estado:         sudo systemctl status odoo19e-$INSTANCE_NAME
📦 Módulos instalados: base, web, web_enterprise, mail, account, web_assets, base_setup, contacts, l10n_latam_base, l10n_ar, l10n_ar_reports
EOF

echo "✅ Instancia creada con éxito: https://$DOMAIN"
echo "📂 Ver detalles en: $BASE_DIR/info-instancia.txt"