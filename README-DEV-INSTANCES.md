# 🚀 Sistema de Instancias de Desarrollo Odoo 19 Enterprise

Sistema automatizado para crear y gestionar entornos de desarrollo clonados desde producción.

## 📁 Estructura de Directorios

```
/home/go/apps/
├── production/
│   └── odoo-enterprise/
│       └── imac-production/          # Instancia de producción
└── develop/
    └── odoo-enterprise/
        ├── dev-juan/                 # Instancia de desarrollo de Juan
        ├── dev-maria/                # Instancia de desarrollo de María
        └── dev-testing/              # Instancia de testing
```

## 🛠️ Scripts Disponibles

### 1. Crear Nueva Instancia de Desarrollo

```bash
cd /home/go/scripts
./create-dev-instance.sh
```

**Qué hace:**
- Clona archivos de producción → desarrollo
- Clona base de datos de producción → desarrollo
- Crea servicio systemd independiente
- Configura Nginx con SSL
- Crea subdominios en Cloudflare
- Genera scripts auxiliares de actualización

**Resultado:**
- Instancia funcional en `https://dev-{nombre}.hospitalprivadosalta.ar`
- Puerto asignado en rango 3100-3200
- Base de datos: `dev-{nombre}-imac-production`
- Servicio: `odoo19e-dev-{nombre}`

---

### 2. Eliminar Instancia de Desarrollo

```bash
cd /home/go/scripts
./remove-dev-instance.sh
```

**Qué hace:**
- Detiene y elimina servicio systemd
- Elimina base de datos
- Elimina archivos
- Elimina configuración Nginx
- Elimina certificado SSL
- Elimina subdominio de Cloudflare
- Libera puerto

---

## 📜 Scripts Auxiliares (Dentro de cada instancia dev)

Cada instancia de desarrollo incluye dos scripts auxiliares en su directorio:

### Actualizar Base de Datos desde Producción

```bash
cd /home/go/apps/develop/odoo-enterprise/dev-{nombre}
./update-db.sh
```

**Qué hace:**
1. Detiene servicio Odoo de desarrollo
2. Elimina BD de desarrollo actual
3. Crea dump de BD de producción
4. Restaura dump en BD de desarrollo
5. Reinicia servicio Odoo

**⚠️ Advertencia:** Esto eliminará TODOS los datos actuales de la BD de desarrollo.

---

### Actualizar Archivos desde Producción

```bash
cd /home/go/apps/develop/odoo-enterprise/dev-{nombre}
./update-files.sh
```

**Qué hace:**
1. Detiene servicio Odoo de desarrollo
2. Hace backup de `custom_addons` (por si tiene cambios locales)
3. Elimina carpeta `odoo-server` de desarrollo
4. Copia carpeta `odoo-server` desde producción
5. Restaura `custom_addons` de desarrollo
6. Reinstala dependencias Python
7. Reinicia servicio Odoo

---

## 🔧 Gestión de Instancias

### Ver instancias de desarrollo activas

```bash
ls -la /home/go/apps/develop/odoo-enterprise/
```

### Ver registro de instancias

```bash
cat ~/dev-instances.txt
```

Formato: `nombre|puerto|base_datos|fecha_creacion`

### Ver puertos ocupados

```bash
cat ~/puertos_ocupados_odoo.txt | sort -n
```

### Ver estado de un servicio

```bash
sudo systemctl status odoo19e-dev-{nombre}
```

### Ver logs de un servicio

```bash
sudo journalctl -u odoo19e-dev-{nombre} -f
```

### Reiniciar un servicio

```bash
sudo systemctl restart odoo19e-dev-{nombre}
```

---

## 🌐 Acceso a Instancias

### Producción
- URL: https://hospitalprivadosalta.ar
- Puerto: 2102
- BD: `imac-production`
- Servicio: `odoo19e-imac-production`

### Desarrollo
- URL: https://dev-{nombre}.hospitalprivadosalta.ar
- Puerto: 3100-3200
- BD: `dev-{nombre}-imac-production`
- Servicio: `odoo19e-dev-{nombre}`

---

## ⚙️ Configuraciones Especiales de Desarrollo

Las instancias de desarrollo tienen configuraciones diferentes a producción:

| Configuración | Producción | Desarrollo |
|--------------|------------|------------|
| `workers` | 0 | 0 |
| `log_level` | info | debug |
| `list_db` | False | True |
| `dbfilter` | Estricto | Permisivo |
| Rango de puertos | 2100-3000 | 3100-3200 |
| Bloqueo `/web/database/manager` | Sí | No |

---

## 📋 Flujo de Trabajo Típico

### Crear nueva instancia para desarrollador

```bash
# 1. Crear instancia
./create-dev-instance.sh
# Ingresar nombre: juan

# 2. Acceder a la instancia
# URL: https://dev-juan.hospitalprivadosalta.ar
# Usuario: admin
# Contraseña: !Phax3312!IMAC
```

### Actualizar instancia con datos frescos de producción

```bash
# Opción 1: Solo actualizar BD
cd /home/go/apps/develop/odoo-enterprise/dev-juan
./update-db.sh

# Opción 2: Solo actualizar archivos
./update-files.sh

# Opción 3: Actualizar ambos
./update-db.sh && ./update-files.sh
```

### Eliminar instancia cuando ya no se necesita

```bash
cd /home/go/scripts
./remove-dev-instance.sh
# Ingresar nombre: juan
# Confirmar: BORRARdev-juan
```

---

## 🔒 Seguridad

### Diferencias de seguridad vs Producción

**Desarrollo (más permisivo):**
- ✅ Acceso al gestor de BD habilitado
- ✅ Selector de BD visible
- ✅ Log level en debug (más información)
- ✅ Sin filtros estrictos de BD

**Producción (más restrictivo):**
- ❌ Gestor de BD bloqueado en Nginx
- ❌ Selector de BD oculto
- ❌ Log level en info
- ❌ Filtro estricto de BD

### Recomendaciones

1. **No usar datos sensibles reales** en desarrollo si es posible
2. **Limitar acceso** a subdominios dev- solo a IPs autorizadas (opcional)
3. **Eliminar instancias** cuando ya no se usen
4. **No hacer cambios directos** en producción, siempre probar en dev primero

---

## 🐛 Solución de Problemas

### La instancia no inicia

```bash
# Ver logs del servicio
sudo journalctl -u odoo19e-dev-{nombre} -n 100 --no-pager

# Verificar que el puerto esté libre
sudo netstat -tlnp | grep {puerto}

# Verificar configuración
cat /home/go/apps/develop/odoo-enterprise/dev-{nombre}/odoo.conf
```

### Error de conexión a BD

```bash
# Verificar que la BD existe
sudo -u postgres psql -l | grep dev-{nombre}

# Verificar permisos
sudo -u postgres psql -c "\du"
```

### Error 502 en Nginx

```bash
# Verificar configuración de Nginx
sudo nginx -t

# Ver logs de Nginx
sudo tail -f /var/log/nginx/error.log

# Verificar que Odoo esté escuchando en el puerto correcto
sudo netstat -tlnp | grep python
```

### Certificado SSL no se genera

```bash
# Verificar DNS
dig dev-{nombre}.hospitalprivadosalta.ar

# Intentar generar manualmente
sudo certbot --nginx -d dev-{nombre}.hospitalprivadosalta.ar
```

---

## 📊 Monitoreo

### Ver todas las instancias y su estado

```bash
# Listar servicios de Odoo
sudo systemctl list-units | grep odoo19e

# Ver uso de recursos
htop
# Filtrar por: python

# Ver espacio en disco
df -h /home/go/apps/develop/
```

### Ver bases de datos

```bash
sudo -u postgres psql -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datname LIKE 'dev-%' OR datname = 'imac-production' ORDER BY datname;"
```

---

## 📝 Notas Importantes

1. **Cada instancia de desarrollo es completamente independiente**
2. **Los cambios en desarrollo NO afectan producción**
3. **Los scripts auxiliares están dentro de cada instancia dev**
4. **Puedes tener múltiples instancias de desarrollo simultáneas**
5. **Las actualizaciones de BD/archivos son destructivas** (eliminan datos actuales)
6. **Siempre confirma antes de ejecutar scripts destructivos**

---

## 🆘 Soporte

Para problemas o dudas:
1. Revisar logs: `sudo journalctl -u odoo19e-dev-{nombre} -n 100`
2. Verificar configuración: `cat /home/go/apps/develop/odoo-enterprise/dev-{nombre}/info-instancia.txt`
3. Revisar este README

---

**Última actualización:** 2025-10-28
