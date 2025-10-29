#!/usr/bin/env python3
"""
Script para neutralizar una base de datos de Odoo usando el sistema nativo.
Elimina credenciales, desactiva crons, correos, webhooks, y elimina la licencia Enterprise.
"""

import sys
import os

# Agregar el path de Odoo al PYTHONPATH
ODOO_PATH = '/home/go/apps/production/odoo-enterprise/imac-production/odoo-server'
sys.path.insert(0, ODOO_PATH)

import odoo
from odoo import api
import odoo.modules.neutralize
from odoo.sql_db import db_connect

def neutralize_database(db_name):
    """
    Neutraliza una base de datos usando el sistema nativo de Odoo
    más limpieza adicional de licencia Enterprise.
    """
    print(f"🔄 Neutralizando base de datos: {db_name}")
    
    try:
        # Conectar a la base de datos
        registry = odoo.modules.registry.Registry.new(db_name)
        
        with registry.cursor() as cr:
            env = api.Environment(cr, odoo.SUPERUSER_ID, {})
            
            # 1. Regenerar UUID (fuerza generación de nuevo UUID)
            print("  🔑 Regenerando UUID de la base de datos...")
            env['ir.config_parameter'].init(force=True)
            
            # 2. Ejecutar neutralización nativa de Odoo
            print("  🛡️  Ejecutando neutralización nativa de Odoo...")
            print("     - Desactivando servidores de correo")
            print("     - Desactivando crons")
            print("     - Desactivando webhooks")
            print("     - Limpiando credenciales de APIs externas")
            odoo.modules.neutralize.neutralize_database(cr)
            
            # 3. Eliminar licencia Enterprise (adicional)
            print("  📜 Eliminando licencia Enterprise...")
            params_to_delete = [
                'database.enterprise_code',
                'database.expiration_date',
                'database.expiration_reason',
                'database.already_linked_subscription_url',
                'database.already_linked_email',
                'database.already_linked_send_mail_url',
            ]
            
            for param in params_to_delete:
                cr.execute("DELETE FROM ir_config_parameter WHERE key = %s", (param,))
            
            # 4. Marcar como base de datos de desarrollo
            print("  🏷️  Marcando como base de datos de desarrollo...")
            cr.execute("""
                INSERT INTO ir_config_parameter (key, value)
                VALUES ('database.is_development', 'true')
                ON CONFLICT (key) DO UPDATE SET value = 'true'
            """)
            
            # 5. Cambiar nombre de la compañía para identificarla como DEV
            print("  🏢 Actualizando nombre de compañía...")
            cr.execute("""
                UPDATE res_company 
                SET name = '[DEV] ' || name 
                WHERE id = 1 
                AND name NOT LIKE '[DEV]%'
            """)
            
            cr.commit()
            
        print("✅ Base de datos neutralizada correctamente")
        print(f"   - UUID regenerado")
        print(f"   - {len(params_to_delete)} parámetros de licencia eliminados")
        print(f"   - Correos, crons y webhooks desactivados")
        print(f"   - Credenciales de APIs limpiadas")
        return True
        
    except Exception as e:
        print(f"❌ Error al neutralizar base de datos: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("Uso: neutralize-database.py <nombre_base_datos>")
        sys.exit(1)
    
    db_name = sys.argv[1]
    
    # Configurar Odoo
    odoo.tools.config.parse_config([])
    
    success = neutralize_database(db_name)
    sys.exit(0 if success else 1)
