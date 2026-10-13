# Reglas de negocio

## 1. Oportunidad de cada requerimiento
Se calcula en el ETL (`etl/clean.py`, función `build`) a partir de las fechas del Excel de control.

| Estado (`oportunidad`) | Condición |
|---|---|
| No requiere respuesta | Solo 2026: el término es "No aplica" o vacío (oficios informativos) |
| A tiempo | Tiene fecha de respuesta y `fecha_respuesta <= fecha_maxima` |
| Tardía | Tiene fecha de respuesta y `fecha_respuesta > fecha_maxima` |
| Sin respuesta (vencida) | No hay fecha ni radicado ORFEO de respuesta y `fecha_maxima < corte` |
| Pendiente en término | No hay respuesta y `fecha_maxima >= corte` |
| Respondida (sin fecha para medir) | Hay ORFEO o estado "Cerrado" pero la fecha de respuesta falta o es ilegible |

- **Corte de datos:** la fecha más reciente (radicación o respuesta) que aparece en los Excel; se puede forzar con `--corte`.
- **Fecha máxima:** la que trae el Excel de origen (no se recalcula). Si hubo prórroga sin actualizarla, la respuesta figura como tardía.
- **Días de retraso:** días hábiles en el intervalo (fecha máxima, fecha de respuesta] o, si no hay respuesta, hasta el corte. Festivos de Colombia (`holidays`).
- **Días hábiles que tardó en responder:** días hábiles en (fecha de recibo, fecha de respuesta].

## 2. Incumplimiento y semáforo
- `evaluables = a_tiempo + tardias + sin_respuesta_vencida`
- `incumplimientos = tardias + sin_respuesta_vencida`
- `tasa = incumplimientos / evaluables`
- **Semáforo** (`semOf`): `muestra insuficiente` si `evaluables < 10`; `rojo` si `tasa >= 40%`; `verde` si `tasa < 20%`; `amarillo` en otro caso.
  Umbrales en `SEMP` (app) y en la vista `v_cumplimiento_organismo` (SQL).
- **Ventana móvil (mapa de calor):** requerimientos con fecha máxima en los 90 días previos al mes seleccionado; con menos de 3 casos el bloque se muestra gris.

## 3. Unificación de organismos
`etl/clean.py` normaliza nombres (tildes, siglas, errores de digitación) a un catálogo canónico de dependencias. Las subsecretarías,
subdirecciones y oficinas se suman a su secretaría o departamento según la estructura del Directorio del Gabinete (`PARENT`).
La hoja "Mapeo organismos" del Excel consolidado lista cada texto original y su destino.

## 4. Directorio y notificaciones
- Solo secretarios y directores (nombre, cargo, celular). No subsecretarios, asesores ni jefes de oficina. Control Disciplinario tiene dos directores.
- Celular válido: 10 dígitos que inician en 3, se guarda como `57XXXXXXXXXX` (`normPhone`).
- Plantillas: `vencidos`, `preventivo`, `desempeno`, `reconocimiento` (`buildMsg`). Sin emojis, máximo ~1.500 caracteres, sin asunto de los requerimientos.
- Cada envío queda en `notificaciones` y en la cadena de auditoría. El seguimiento marca "Sin atender" si pasan 7 o más días y los casos no bajaron.

## 5. Privacidad
- `maskPII` oculta nombres de ciudadanos y documentos (cédula, PPT, TI) en listas, informes y exportaciones. El texto original solo se ve con "Ver texto original".
- El informe incluye una **huella SHA-256** de los registros usados y queda registrado en `informes`.

## 6. Permisos por rol
| Rol | Ve | Crea | Cierra con ORFEO | Escala / notifica | Auditoría y actividad |
|---|---|---|---|---|---|
| admin | Todo | Sí | Sí | Sí | Sí |
| alcalde | Todo | No | No | Sí | Sí |
| control_interno | Todo | No | No | Sí | Sí |
| secretario | Su dependencia | No | Su dependencia | No | No |
| enlace | Su dependencia | Su dependencia | Su dependencia | Sí (alertas) | No |
