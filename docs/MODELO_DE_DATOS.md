# Modelo de datos (Supabase / PostgreSQL)

Ejecutar en orden: `01_schema.sql`, `02_seed.sql`, `03_historico.sql`, `04_directorio_notificaciones.sql`, `05_actividad_informes.sql`.

| Tabla / vista | Para qué sirve | Quién lee | Quién escribe |
|---|---|---|---|
| `profiles` | Cuenta: rol, dependencia, activo | propio; admin/alcalde/control_interno todos | admin |
| `entes`, `dependencias` | Catálogos | usuarios activos | admin |
| `requerimientos` | Módulo operativo (requerimientos vivos) | por dependencia | admin / enlace (crear); cierre vía RPC |
| `historico_requerimientos` | Histórico 2024-2026 clasificado | supervisión todo; secretario/enlace su dependencia | importación (service role) |
| `v_cumplimiento_organismo` | Ranking y semáforo por organismo y vigencia | igual que el histórico | solo lectura |
| `directorio` | Secretarios y directores (nombre, celular) | supervisión todo; otros su dependencia | admin, alcalde |
| `notificaciones` | Bitácora de WhatsApp enviados | igual que directorio | admin, alcalde, control_interno (solo insertar) |
| `accesos` | Quién ingresó y cuándo | supervisión; cada uno el suyo | cada usuario (insertar) |
| `informes` | Informes generados con su huella | supervisión; cada uno los suyos | cada usuario (insertar) |
| `alertas_log` | Escalamientos del módulo operativo | supervisión | RPC `escalar_requerimiento` |
| `audit_log` | Cadena de auditoría SHA-256 | supervisión | solo triggers |

## RPC (funciones que llama la app)
- `cerrar_requerimiento(p_id, p_orfeo, p_fecha, p_path, p_hash)`: valida formato de ORFEO, fecha, dependencia y duplicados.
- `escalar_requerimiento(p_id, p_canal)`
- `verificar_cadena_auditoria()` -> `(ok, total, primer_id_roto)`
- `current_rol()`, `current_dep()`, `current_dep_name()`: usadas por las políticas RLS.

## Auditoría inmutable
Cada INSERT/UPDATE/DELETE de las tablas auditadas agrega una fila a `audit_log` con:
`hash = SHA256(prev_hash | tabla | accion | registro_id | usuario | fecha UTC (AAAA-MM-DDTHH:MI:SS.US) | payload | cambios)`.
En UPDATE, `cambios` guarda `{campo: {de, a}}`. Los triggers bloquean UPDATE, DELETE y TRUNCATE sobre `audit_log`.
Un cliente puede recalcular la cadena con esa fórmula para verificarla sin confiar en el servidor.

## Importación de datos
1. `python etl/run_etl.py ...` genera `historico_requerimientos.csv` y `directorio_gabinete.csv`.
2. Importarlos desde Table Editor > Insert > Import data from CSV (usa credenciales de administrador, no pasa por RLS).
