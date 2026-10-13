# Arquitectura

Aplicación web instalable (PWA) de un solo archivo (`index.html`) conectada a Supabase. Está organizada en capas
para que un desarrollador pueda reescribirla en nativo (React Native, Flutter o Swift/Kotlin) reutilizando casi todo.

```
┌───────────────────────────────────────────────────────────────┐
│ PRESENTACIÓN   vistas (vMando, vDependencia, vInforme, ...)   │  <- se reescribe en nativo
├───────────────────────────────────────────────────────────────┤
│ DOMINIO        reglas puras sin pantalla: semOf, statsOf,     │  <- se porta 1 a 1 (hay pruebas)
│                maskPII, normPhone, buildMsg, reportModel      │
├───────────────────────────────────────────────────────────────┤
│ DATOS          objeto `db` + loadHist/loadDir/loadNotifs      │  <- cambiar solo el cliente
│                (Supabase real o modo demostración en memoria) │
├───────────────────────────────────────────────────────────────┤
│ SUPABASE       Auth + Postgres + RLS + Storage + RPC          │  <- se reutiliza 100%
├───────────────────────────────────────────────────────────────┤
│ ETL (etl/)     Excel de control + directorio -> CSV           │  <- se reutiliza 100%
└───────────────────────────────────────────────────────────────┘
```

## Qué se reutiliza tal cual
- **Toda la carpeta `supabase/`**: tablas, políticas RLS, auditoría SHA-256, funciones. La app nativa solo llama a la misma API.
- **`etl/`**: convierte los Excel en el CSV que se importa a Supabase.
- **Reglas de negocio**: ver `REGLAS_DE_NEGOCIO.md`. Las funciones puras están probadas en `tests/reglas.test.js`; el desarrollador debe
  portarlas y comprobar que dan los mismos resultados de esos casos.
- **Tokens de diseño**: `docs/tokens.json` (colores, tipografías, radios).

## Mapa de pantallas (ruta -> función en `index.html` -> pantalla nativa sugerida)

| Ruta | Función | Roles | Notas para nativo |
|---|---|---|---|
| mando | `vMando` | admin, alcalde, control_interno | Mapa de calor (treemap), línea de tiempo, cola de acción. Treemap: `squarify()` |
| dependencia | `vDependencia` | todos (secretario/enlace solo la suya) | Donut, tendencia mensual, pendientes |
| informe | `vInforme` + `reportModel` | todos (acotado por rol) | El informe es HTML; en nativo generar PDF con la misma plantilla |
| notificaciones | `vNotificaciones`, `notifyModal`, `despachoModal` | supervisión | `wa.me` abre WhatsApp; en nativo usar el esquema de URL |
| directorio | `vDirectorio` | supervisión (edita admin/alcalde) | Solo secretarios y directores |
| actividad | `vActividad` | supervisión | Quién modificó, notificó, ingresó y generó informes |
| cumplimiento | `vCumplimiento` | supervisión | Ranking con semáforo |
| historico | `vHistorico` | todos (acotado) | Tabla paginada de 100 |
| requerimientos / carga / alertas | `vReqs`, `vCarga`, `vAlertas` | según rol | Módulo operativo (cierre con ORFEO y PDF) |
| auditoria / cuentas / config | `vAuditoria`, `vCuentas`, `vConfig` | admin y supervisión | |

La navegación se define en el arreglo `NAV` (grupos, ítems y roles permitidos). Es la fuente única de verdad de los permisos de pantalla.

## Flujo de datos
1. `boot()` crea el cliente Supabase si hay URL y anon key; si no, entra en **modo demostración**.
2. Tras iniciar sesión: `afterLogin` carga el perfil (rol y dependencia), luego `loadHist`, `loadDir`, `loadNotifs`.
3. Todas las vistas leen de `HIST.rows` (ya acotado por RLS en el servidor) mediante `hrows()`.
4. Las escrituras pasan por `db.*` (RPC `cerrar_requerimiento`, `escalar_requerimiento`; inserts en `notificaciones`, `informes`, `accesos`, `directorio`).
5. La auditoría se llena sola con triggers en la base de datos (la app no escribe en `audit_log`).

## Seguridad (qué NO debe cambiar al migrar)
- La separación por dependencia la hacen las políticas RLS, no la interfaz.
- La anon key es pública; nunca incluir la service_role key en la app.
- Los mensajes de WhatsApp y las exportaciones no llevan el asunto de los requerimientos (datos personales de ciudadanos). `maskPII` oculta nombres y documentos en pantalla.
- Los datos y el directorio (celulares) no se publican en el repositorio.

## Recomendaciones para la versión nativa
- **React Native + `@supabase/supabase-js`** reutiliza casi toda la lógica JavaScript; **Flutter + `supabase_flutter`** exige portar las reglas (hay pruebas para validar).
- **Notificaciones push** (FCM/APNs) para avisar a secretarios dentro de la app, además de WhatsApp.
- **WhatsApp Business API** (mediante una Edge Function) permitiría envío automático; hoy se abre el chat con el mensaje listo.
- **Sin conexión:** guardar en caché local la última carga de `HIST` y la bitácora pendiente de sincronizar.
- **PDF del informe:** reutilizar `reportHtml()` como plantilla (o redibujar con la librería de PDF de la plataforma).
