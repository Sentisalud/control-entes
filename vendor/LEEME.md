# Librerías y fuentes incluidas

La aplicación no descarga nada de internet: todo lo que necesita viaja con ella.

| Archivo | Origen | Versión | Licencia |
|---|---|---|---|
| supabase.min.js, 591.supabase.js | @supabase/supabase-js (npm) | 2.45.4 | MIT |
| xlsx.full.min.js | SheetJS Community Edition (npm xlsx) | 0.18.5 | Apache 2.0 |
| fontawesome/ | @fortawesome/fontawesome-free (npm) | 6.4.0 | Íconos CC BY 4.0, fuentes SIL OFL 1.1, código MIT |
| pdf.min.js, pdf.worker.min.js | pdfjs-dist (npm), lector de PDF de Mozilla | 3.11.174 | Apache 2.0 |
| fuentes/ (Archivo, Inter, JetBrains Mono) | @fontsource-variable (npm) | — | SIL Open Font License 1.1 |

Esta carpeta se publica junto a index.html (carpeta `vendor/`). La aplicación y el service worker la usan con rutas relativas, así que funciona igual en GitHub Pages o en un servidor de la Alcaldía sin salida a internet.
