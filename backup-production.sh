#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 💾 Script de backup completo de producción Odoo
# Crea backup de BD + filestore comprimido, SIN neutralizar

set -e

# Configuración
PROD_INSTANCE="imac-production"
PROD_DB="imac-production"
BACKUP_DIR="/home/go/backups"
FILESTORE_BASE="/home/go/.local/share/Odoo/filestore"
PROD_FILESTORE="$FILESTORE_BASE/$PROD_DB"
RETENTION_DAYS=7  # Por defecto 7 días
USER="go"

# Crear directorio de backups si no existe
mkdir -p "$BACKUP_DIR"

# Timestamp para el backup
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_NAME="backup_${PROD_DB}_${TIMESTAMP}"
BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"

echo "💾 Iniciando backup de producción..."
echo "   Instancia: $PROD_INSTANCE"
echo "   Base de datos: $PROD_DB"
echo "   Timestamp: $TIMESTAMP"
echo ""

# Crear directorio temporal para este backup
mkdir -p "$BACKUP_PATH"

# 1. Backup de la base de datos
echo "🗄️  Creando dump de base de datos..."
sudo -u postgres pg_dump "$PROD_DB" | gzip > "$BACKUP_PATH/database.sql.gz"
DB_SIZE=$(du -h "$BACKUP_PATH/database.sql.gz" | cut -f1)
echo "✅ Base de datos: $DB_SIZE"

# 2. Backup del filestore
if [[ -d "$PROD_FILESTORE" ]]; then
  echo "📁 Comprimiendo filestore..."
  tar -czf "$BACKUP_PATH/filestore.tar.gz" -C "$FILESTORE_BASE" "$PROD_DB" 2>/dev/null
  FS_SIZE=$(du -h "$BACKUP_PATH/filestore.tar.gz" | cut -f1)
  FILE_COUNT=$(find "$PROD_FILESTORE" -type f | wc -l)
  echo "✅ Filestore: $FS_SIZE ($FILE_COUNT archivos)"
else
  echo "⚠️  No se encontró filestore en $PROD_FILESTORE"
  touch "$BACKUP_PATH/filestore.tar.gz"
fi

# 3. Crear archivo de metadatos
echo "📝 Creando metadatos..."
cat > "$BACKUP_PATH/metadata.json" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "date": "$(date '+%Y-%m-%d %H:%M:%S')",
  "database": "$PROD_DB",
  "instance": "$PROD_INSTANCE",
  "database_size": "$DB_SIZE",
  "filestore_size": "$FS_SIZE",
  "file_count": ${FILE_COUNT:-0},
  "hostname": "$(hostname)",
  "neutralized": false,
  "type": "production_full"
}
EOF

# 4. Comprimir todo en un archivo final
echo "📦 Creando archivo final..."
cd "$BACKUP_DIR"
tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"
rm -rf "$BACKUP_PATH"

TOTAL_SIZE=$(du -h "${BACKUP_NAME}.tar.gz" | cut -f1)
echo "✅ Backup completado: ${BACKUP_NAME}.tar.gz ($TOTAL_SIZE)"

# 5. Limpiar backups antiguos según retención
echo "🧹 Limpiando backups antiguos (retención: $RETENTION_DAYS días)..."
find "$BACKUP_DIR" -name "backup_${PROD_DB}_*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete
REMAINING=$(ls -1 "$BACKUP_DIR"/backup_${PROD_DB}_*.tar.gz 2>/dev/null | wc -l)
echo "✅ Backups restantes: $REMAINING"

# 6. Registrar en log
LOG_FILE="$BACKUP_DIR/backup.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Backup: ${BACKUP_NAME}.tar.gz - Size: $TOTAL_SIZE - Status: OK" >> "$LOG_FILE"

echo ""
echo "✅ Backup completado exitosamente"
echo "   Archivo: $BACKUP_DIR/${BACKUP_NAME}.tar.gz"
echo "   Tamaño: $TOTAL_SIZE"
