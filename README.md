# Control de Entes — Alcaldía de Santiago de Cali

Centro de mando para que el Alcalde monitoree el cumplimiento frente a los entes de control, dependencia por dependencia,
genere el informe ejecutivo en PDF y notifique por WhatsApp a cada secretario o director. Cada secretario o director solo ve su dependencia.

## Qué incluye
- **Centro de mando:** mapa de calor, máquina del tiempo, cola de acción y modo despacho.
- **Informe ejecutivo en PDF** desde la misma aplicación (gráficos, ranking, casos críticos y huella SHA-256 de verificación).
- **Expediente de dependencia**, **notificaciones por WhatsApp** con bitácora y **directorio** (solo secretarios y directores).
- **Actividad y cambios:** quién modificó qué (con valor anterior y nuevo), quién notificó, quién ingresó y quién generó informes.
- Cumplimiento por secretaría, histórico, cierre con ORFEO y PDF, auditoría con cadena SHA-256, cuentas y roles.

## Estructura
```
index.html              Aplicación (sin datos incrustados: los datos viven en Supabase)
manifest.webmanifest, sw.js, icons/    Instalación y funcionamiento sin conexión
supabase/               01_schema, 02_seed, 03_historico, 04_directorio_notificaciones, 05_actividad_informes, 06_directorio_validaciones
etl/                    Excel -> CSV (ver etl/README.md)
docs/                   Arquitectura, reglas de negocio, modelo de datos, tokens de diseño, guía de migración a nativo
tests/                  reglas.test.js (node) y etl_test.py (python)
```

## Identidad visual
Colores de la bandera de Santiago de Cali y oro del escudo oficial; tokens en `docs/tokens.json`. En el celular la app usa barra de pestañas inferior y el panel administrativo completo se abre desde "Menú".

## Pruebas
```
node tests/reglas.test.js
CE_DATA=/ruta/excels python -m unittest tests/etl_test.py
```

## Privacidad (importante)
- Los datos (radicados, nombres de ciudadanos en los asuntos y celulares del gabinete) **no van en este repositorio**: se importan a Supabase desde `datos_privados/`, que queda fuera de GitHub.
- El HTML solo contiene la URL y la anon key de Supabase (públicas por diseño). La seguridad real la dan las políticas RLS: un secretario o director solo lee su dependencia, aunque abra las herramientas del navegador.
- Los mensajes de WhatsApp no incluyen el asunto de los requerimientos; listas, informes y exportaciones ocultan nombres y documentos de ciudadanos.
- Nunca pegar la service_role key en el HTML.

## Despliegue
1. Crear el proyecto en Supabase y ejecutar en el SQL Editor, en orden: `01` a `05` de `supabase/`.
2. Importar primero `historico_requerimientos.csv` en `historico_requerimientos` y después `directorio_gabinete.csv` en `directorio`.
3. Ejecutar `06_directorio_validaciones.sql`. Desde ese momento el directorio corrige solo tildes y espacios en el nombre de la dependencia y rechaza dependencias inexistentes, celulares inválidos o repetidos y nombres incompletos.
4. Ejecutar `select * from v_directorio_verificacion;` y corregir hasta que no devuelva filas: así cada secretario o director queda amarrado a su dependencia y el WhatsApp sale sin errores.
5. Pegar la Project URL y la anon key en el bloque `CFG` de `index.html`.
6. Publicar con GitHub Pages (Settings > Pages > rama main, carpeta raíz).
7. En Supabase: Authentication > URL Configuration, agregar la URL de GitHub Pages. Crear el primer usuario y asignarle rol `admin` y `activo = true`.

Para migrar a una app nativa, empezar por `docs/ARQUITECTURA.md`.
