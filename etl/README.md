# ETL: de los Excel de control a Supabase

Convierte los Excel de control (uno por vigencia) y el directorio protocolario en los CSV que se importan a Supabase.

```
pip install -r requirements.txt
python run_etl.py --2024 control_2024.xlsx --2025 control_2025.xlsx --2026 control_2026.xlsx \
                  --gabinete directorio_protocolo.xlsx --salida ../datos_privados
```

Genera `historico_requerimientos.csv`, `directorio_gabinete.csv` y `calidad_de_datos.csv` (filas del Excel con datos inconsistentes para revisar).
El corte de datos es la fecha más reciente de los Excel; se puede forzar con `--corte AAAA-MM-DD`.

- `load.py`: lee las hojas CONTROL de cada vigencia (las columnas cambian entre 2024/2025 y 2026).
- `clean.py`: fechas, unificación de organismos (`RULES`, `PARENT`), clasificación de oportunidad y días hábiles.
- `extract_directorio.py`: toma solo secretarios y directores de la hoja "Gabinete" (sin cédulas ni correos).

Los CSV contienen datos personales: no subirlos a GitHub.
