#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 🚀 Script de creación de instancia de desarrollo Odoo 19 Enterprise
# Clona la instancia de producción para crear entornos de desarrollo aislados

set -e

# Configuración
PROD_ROOT="/home/go/apps/production/odoo-enterprise"
DEV_ROOT="/home/go/apps/develop/odoo-enterprise"
PROD_INSTANCE="imac-production"
PROD_DB="imac-production"
PYTHON="/usr/bin/python3.12"
PUERTOS_FILE="$HOME/puertos_ocupados_odoo.txt"
DEV_INSTANCES_FILE="$HOME/dev-instances.txt"
USER="go"
DB_USER="go"
DB_PASSWORD="!Phax3312!IMAC"
ADMIN_PASSWORD="!Phax3312!IMAC"
CF_API_TOKEN="JK1cCBg776SHiZX9T6Ky5b2gtjMkpUsNHxVyQ0Vs"
CF_ZONE_NAME="hospitalprivadosalta.ar"
PUBLIC_IP="200.69.140.2"

# Validaciones iniciales
command -v /usr/bin/jq >/dev/null 2>&1 || { echo >&2 "❌ 'jq' no está instalado."; exit 1; }
command -v /usr/bin/curl >/dev/null 2>&1 || { echo >&2 "❌ 'curl' no está instalado."; exit 1; }
command -v pg_dump >/dev/null 2>&1 || { echo >&2 "❌ 'pg_dump' no está instalado."; exit 1; }

# Verificar que existe la instancia de producción
if [[ ! -d "$PROD_ROOT/$PROD_INSTANCE" ]]; then
  echo "❌ No se encontró la instancia de producción en $PROD_ROOT/$PROD_INSTANCE"
  exit 1
fi

# Crear directorio de desarrollo si no existe
mkdir -p "$DEV_ROOT"

# Mostrar instancias de desarrollo existentes
echo "📦 Instancias de desarrollo existentes:"
if [[ -d "$DEV_ROOT" ]] && [[ -n "$(ls -A $DEV_ROOT 2>/dev/null)" ]]; then
  ls -1 "$DEV_ROOT" | sed 's/^/  - /'
else
  echo "  (ninguna)"
fi

# Solicitar nombre de la instancia de desarrollo (o usar argumento)
if [[ -n "$1" ]]; then
  DEV_NAME="$1"
  echo -e "\n🔧 Creando instancia de desarrollo: $DEV_NAME"
else
  echo -e "\n🔧 Nombre de la nueva instancia de desarrollo:"
  echo "   Ejemplos: juan, maria, testing, feature-xyz"
  read -p "> " DEV_NAME
fi

# Validar nombre
if [[ -z "$DEV_NAME" ]]; then
  echo "❌ Debes proporcionar un nombre."
  exit 1
fi

# Normalizar nombre
DEV_NAME=$(echo "$DEV_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
INSTANCE_NAME="dev-$DEV_NAME"
DB_NAME="dev-$DEV_NAME-$PROD_DB"
DOMAIN="$INSTANCE_NAME.$CF_ZONE_NAME"
BASE_DIR="$DEV_ROOT/$INSTANCE_NAME"

# Verificar si ya existe
if [[ -d "$BASE_DIR" ]]; then
  echo "❌ La instancia '$INSTANCE_NAME' ya existe en $BASE_DIR"
  exit 1
fi

echo ""
echo "📋 Resumen de la nueva instancia:"
echo "   Nombre: $INSTANCE_NAME"
echo "   Base de datos: $DB_NAME"
echo "   Dominio: https://$DOMAIN"
echo "   Ubicación: $BASE_DIR"
echo ""
read -p "¿Continuar? (s/n): " CONFIRM

if [[ "$CONFIRM" != "s" ]] && [[ "$CONFIRM" != "S" ]]; then
  echo "❌ Cancelado."
  exit 1
fi

LOG="/tmp/odoo-create-dev-$INSTANCE_NAME.log"
exec > >(tee -a "$LOG") 2>&1

echo "🚀 Iniciando creación de instancia de desarrollo: $INSTANCE_NAME"

# Buscar puerto libre (rango 3100-3200 para desarrollo)
echo "🔍 Buscando puerto libre..."
PORT=""
for p in {3100..3200}; do
  if ! grep -q "^$p$" "$PUERTOS_FILE" 2>/dev/null && ! lsof -iTCP:$p -sTCP:LISTEN -t >/dev/null; then
    PORT=$p
    break
  fi
done
[[ -z "$PORT" ]] && echo "❌ No hay puerto libre en rango 3100-3200." && exit 1
echo "✅ Puerto asignado: $PORT"

SERVICE="/etc/systemd/system/odoo19e-$INSTANCE_NAME.service"
ODOO_CONF="$BASE_DIR/odoo.conf"
ODOO_LOG="$BASE_DIR/odoo.log"
NGINX_CONF="/etc/nginx/sites-available/$INSTANCE_NAME"
INFO_FILE="$BASE_DIR/info-instancia.txt"
VENV_DIR="$BASE_DIR/venv"
APP_DIR="$BASE_DIR"

# Configurar DNS en Cloudflare
echo "🌍 IP pública configurada: $PUBLIC_IP"
CF_ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CF_ZONE_NAME" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" | /usr/bin/jq -r '.result[0].id')
echo "🌐 Configurando DNS en Cloudflare para $DOMAIN..."
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data '{"type":"A","name":"'"$DOMAIN"'","content":"'"$PUBLIC_IP"'","ttl":3600,"proxied":true}' >/dev/null

echo "🛰️  Esperando propagación DNS..."
sleep 5

# Crear estructura de directorios
echo "📁 Creando estructura de carpetas en $BASE_DIR..."
mkdir -p "$BASE_DIR"
mkdir -p "$BASE_DIR/custom_addons"
mkdir -p "$BASE_DIR/odoo-server"

# Copiar archivos desde producción
echo "📦 Copiando archivos desde producción..."
echo "   Esto puede tomar varios minutos..."
cp -r "$PROD_ROOT/$PROD_INSTANCE/odoo-server/"* "$BASE_DIR/odoo-server/"
echo "✅ Archivos copiados correctamente."

# Crear entorno virtual Python
echo "🐍 Creando entorno virtual Python..."
$PYTHON -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
echo "⬆️  Actualizando pip y wheel..."
pip install --upgrade pip wheel
echo "📦 Instalando requerimientos Python..."
pip install -r "$BASE_DIR/odoo-server/requirements.txt"

# Clonar base de datos desde producción
echo "🗄️  Clonando base de datos desde producción..."
echo "   Eliminando BD anterior si existe..."
sudo -u postgres dropdb "$DB_NAME" 2>/dev/null || true
echo "   Creando dump de $PROD_DB..."
sudo -u postgres pg_dump "$PROD_DB" > "/tmp/${DB_NAME}_dump.sql"
echo "   Creando base de datos $DB_NAME..."
sudo -u postgres createdb "$DB_NAME" -O "$DB_USER" --encoding='UTF8'
echo "   Restaurando datos..."
sudo -u postgres psql -d "$DB_NAME" < "/tmp/${DB_NAME}_dump.sql"
rm -f "/tmp/${DB_NAME}_dump.sql"
echo "✅ Base de datos clonada correctamente."

# Copiar filestore desde producción
echo "📁 Copiando filestore (imágenes y archivos adjuntos)..."
FILESTORE_BASE="/home/go/.local/share/Odoo/filestore"
PROD_FILESTORE="$FILESTORE_BASE/$PROD_DB"
DEV_FILESTORE="$FILESTORE_BASE/$DB_NAME"

if [[ -d "$PROD_FILESTORE" ]]; then
  echo "   Origen: $PROD_FILESTORE ($(du -sh $PROD_FILESTORE | cut -f1))"
  mkdir -p "$DEV_FILESTORE"
  rsync -a "$PROD_FILESTORE/" "$DEV_FILESTORE/"
  echo "✅ Filestore copiado correctamente ($(find $DEV_FILESTORE -type f | wc -l) archivos)"
else
  echo "⚠️  Advertencia: No se encontró filestore de producción en $PROD_FILESTORE"
fi

# Generar archivo de configuración Odoo (modo desarrollo)
echo "⚙️ Generando archivo de configuración Odoo (modo desarrollo)..."
cat > "$ODOO_CONF" <<EOF
[options]
addons_path = $BASE_DIR/odoo-server/odoo/addons,$BASE_DIR/custom_addons
db_host = localhost
db_port = 5432
db_user = $DB_USER
db_password = $DB_PASSWORD
db_name = $DB_NAME
log_level = debug
logfile = $ODOO_LOG
http_port = $PORT
http_interface = 127.0.0.1
proxy_mode = True
admin_passwd = $ADMIN_PASSWORD
workers = 0
max_cron_threads = 1
db_maxconn = 8

# Configuración de desarrollo (más permisiva)
list_db = True
limit_time_cpu = 600
limit_time_real = 1200
limit_memory_soft = 2147483648
limit_memory_hard = 2684354560
EOF

touch "$ODOO_LOG"
chown -R $USER:$USER "$BASE_DIR"

# Crear servicio systemd
echo "⚙️ Creando servicio systemd para Odoo..."
echo "[Unit]
Description=Odoo 19e Development Instance - $INSTANCE_NAME
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=$VENV_DIR/bin/python3 $BASE_DIR/odoo-server/odoo-bin -c $APP_DIR/odoo.conf
WorkingDirectory=$APP_DIR
StandardOutput=journal
StandardError=inherit
Restart=always

[Install]
WantedBy=multi-user.target
" | sudo tee /etc/systemd/system/odoo19e-$INSTANCE_NAME.service > /dev/null

sudo systemctl daemon-reload
sudo systemctl enable "odoo19e-$INSTANCE_NAME"

# Regenerar assets antes de iniciar el servicio
echo "🎨 Regenerando assets (CSS, JS, iconos)..."
echo "   Esto puede tomar algunos minutos..."
sudo -u $USER "$VENV_DIR/bin/python3" "$BASE_DIR/odoo-server/odoo-bin" -c "$ODOO_CONF" --update=all --stop-after-init

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

# Configurar Nginx
[[ -L "/etc/nginx/sites-enabled/$INSTANCE_NAME" ]] && sudo rm -f "/etc/nginx/sites-enabled/$INSTANCE_NAME"

echo "🔍 Verificando si ya existe certificado SSL para $DOMAIN..."
if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    echo "🚫 Certificado no encontrado. Creando configuración HTTP temporal..."
    
    echo "server {
    listen 80;
    server_name $DOMAIN;

    client_max_body_size 20M;

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
    
    echo "map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    server_name $DOMAIN;

    client_max_body_size 20M;

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

# Crear scripts auxiliares de actualización
echo "📝 Creando scripts auxiliares..."

# Script para actualizar BD
cat > "$BASE_DIR/update-db.sh" <<'UPDATEDB'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
#!/bin/bash
# Script para actualizar la BD de desarrollo desde producción

PROD_DB="imac-production"
DEV_DB="__DB_NAME__"
INSTANCE_NAME="__INSTANCE_NAME__"

echo "🔄 Actualizando base de datos de desarrollo desde producción..."
echo "   Producción: $PROD_DB"
echo "   Desarrollo: $DEV_DB"
read -p "¿Continuar? Esto eliminará todos los datos actuales (s/n): " CONFIRM

if [[ "$CONFIRM" != "s" ]] && [[ "$CONFIRM" != "S" ]]; then
  echo "❌ Cancelado."
  exit 1
fi

echo "⏹️  Deteniendo servicio Odoo..."
sudo systemctl stop "odoo19e-$INSTANCE_NAME"

echo "🗄️  Eliminando BD de desarrollo actual..."
sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DEV_DB';" >/dev/null 2>&1
sudo -u postgres dropdb "$DEV_DB" 2>/dev/null

echo "📦 Creando dump de producción..."
sudo -u postgres pg_dump "$PROD_DB" > "/tmp/${DEV_DB}_dump.sql"

echo "🔄 Restaurando en desarrollo..."
sudo -u postgres createdb "$DEV_DB" -O "go" --encoding='UTF8'
sudo -u postgres psql -d "$DEV_DB" < "/tmp/${DEV_DB}_dump.sql"
rm -f "/tmp/${DEV_DB}_dump.sql"

echo "📁 Sincronizando filestore..."
FILESTORE_BASE="/home/go/.local/share/Odoo/filestore"
PROD_FILESTORE="$FILESTORE_BASE/$PROD_DB"
DEV_FILESTORE="$FILESTORE_BASE/$DEV_DB"
if [[ -d "$PROD_FILESTORE" ]]; then
  mkdir -p "$DEV_FILESTORE"
  rsync -a --delete "$PROD_FILESTORE/" "$DEV_FILESTORE/"
  echo "✅ Filestore sincronizado ($(find $DEV_FILESTORE -type f | wc -l) archivos)"
fi

echo "🎨 Regenerando assets..."
cd "__BASE_DIR__"
source venv/bin/activate
./venv/bin/python3 ./odoo-server/odoo-bin -c ./odoo.conf --update=all --stop-after-init

echo "▶️  Iniciando servicio Odoo..."
sudo systemctl start "odoo19e-$INSTANCE_NAME"

echo "✅ Base de datos actualizada correctamente."
UPDATEDB

sed -i "s/__DB_NAME__/$DB_NAME/g" "$BASE_DIR/update-db.sh"
sed -i "s/__INSTANCE_NAME__/$INSTANCE_NAME/g" "$BASE_DIR/update-db.sh"
sed -i "s|__BASE_DIR__|$BASE_DIR|g" "$BASE_DIR/update-db.sh"
chmod +x "$BASE_DIR/update-db.sh"

# Script para actualizar archivos
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cat > "$BASE_DIR/update-files.sh" <<'UPDATEFILES'
#!/bin/bash
# Script para actualizar archivos de desarrollo desde producción

PROD_DIR="/home/go/apps/production/odoo-enterprise/imac-production"
DEV_DIR="__BASE_DIR__"
INSTANCE_NAME="__INSTANCE_NAME__"

echo "🔄 Actualizando archivos desde producción..."
echo "   Producción: $PROD_DIR"
echo "   Desarrollo: $DEV_DIR"
read -p "¿Continuar? (s/n): " CONFIRM

if [[ "$CONFIRM" != "s" ]] && [[ "$CONFIRM" != "S" ]]; then
  echo "❌ Cancelado."
  exit 1
fi

echo "⏹️  Deteniendo servicio Odoo..."
sudo systemctl stop "odoo19e-$INSTANCE_NAME"

echo "💾 Haciendo backup de custom_addons..."
if [[ -d "$DEV_DIR/custom_addons" ]]; then
  cp -r "$DEV_DIR/custom_addons" "$DEV_DIR/custom_addons.backup"
fi

echo "🗑️  Eliminando odoo-server actual..."
rm -rf "$DEV_DIR/odoo-server"

echo "📦 Copiando archivos desde producción..."
mkdir -p "$DEV_DIR/odoo-server"
cp -r "$PROD_DIR/odoo-server/"* "$DEV_DIR/odoo-server/"

echo "🔄 Restaurando custom_addons..."
if [[ -d "$DEV_DIR/custom_addons.backup" ]]; then
  rm -rf "$DEV_DIR/custom_addons"
  mv "$DEV_DIR/custom_addons.backup" "$DEV_DIR/custom_addons"
fi

echo "🐍 Actualizando dependencias Python..."
source "$DEV_DIR/venv/bin/activate"
pip install --upgrade pip wheel
pip install -r "$DEV_DIR/odoo-server/requirements.txt"

echo "▶️  Iniciando servicio Odoo..."
sudo systemctl start "odoo19e-$INSTANCE_NAME"

echo "✅ Archivos actualizados correctamente."
UPDATEFILES

sed -i "s|__BASE_DIR__|$BASE_DIR|g" "$BASE_DIR/update-files.sh"
sed -i "s/__INSTANCE_NAME__/$INSTANCE_NAME/g" "$BASE_DIR/update-files.sh"
chmod +x "$BASE_DIR/update-files.sh"

# Generar archivo de información
cat > "$INFO_FILE" <<EOF
🔧 Instancia de Desarrollo: $INSTANCE_NAME
🌍 Dominio: https://$DOMAIN
🛠️ Puerto: $PORT
🗄️ Base de datos: $DB_NAME
👤 Usuario DB: $DB_USER
🔑 Contraseña DB: $DB_PASSWORD
📁 Ruta: $BASE_DIR
📄 Configuración: $ODOO_CONF
📝 Log: $ODOO_LOG
🪵 Log de instalación: $LOG
🧩 Servicio systemd: odoo19e-$INSTANCE_NAME
🌀 Logs: sudo journalctl -u odoo19e-$INSTANCE_NAME -n 50 --no-pager
🌐 Nginx: $NGINX_CONF
🌐 IP pública: $PUBLIC_IP
🔁 Reiniciar servicio: sudo systemctl restart odoo19e-$INSTANCE_NAME
📋 Ver estado: sudo systemctl status odoo19e-$INSTANCE_NAME

📜 Scripts auxiliares:
   Actualizar BD: $BASE_DIR/update-db.sh
   Actualizar archivos: $BASE_DIR/update-files.sh

🏭 Clonado desde producción:
   Instancia: $PROD_INSTANCE
   Base de datos: $PROD_DB
EOF

# Registrar puerto como ocupado
if ! grep -q "^$PORT$" "$PUERTOS_FILE" 2>/dev/null; then
  echo "$PORT" >> "$PUERTOS_FILE"
fi

# Registrar instancia de desarrollo
echo "$INSTANCE_NAME|$PORT|$DB_NAME|$(date '+%Y-%m-%d %H:%M:%S')" >> "$DEV_INSTANCES_FILE"

echo ""
echo "✅ Instancia de desarrollo creada con éxito: https://$DOMAIN"
echo "📂 Ver detalles en: $BASE_DIR/info-instancia.txt"
echo ""
echo "📜 Scripts disponibles:"
echo "   Actualizar BD desde producción: $BASE_DIR/update-db.sh"
echo "   Actualizar archivos desde producción: $BASE_DIR/update-files.sh"
