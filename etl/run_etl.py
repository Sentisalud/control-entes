"""ETL del Control de Requerimientos de Entes de Control.
Uso:
  python run_etl.py --2024 control_2024.xlsx --2025 control_2025.xlsx --2026 control_2026.xlsx \\
                    --gabinete directorio_protocolo.xlsx --salida ../datos_privados [--corte 2026-07-29]
Genera: historico_requerimientos.csv (para Supabase) y directorio_gabinete.csv.
"""
import argparse, os, pandas as pd, load
from clean import build
from extract_directorio import extraer, guardar_csv

def main():
    ap=argparse.ArgumentParser()
    for y in (2024,2025,2026): ap.add_argument(f'--{y}',required=True,help=f'Excel de control vigencia {y}')
    ap.add_argument('--gabinete'); ap.add_argument('--salida',default='salida'); ap.add_argument('--corte',help='AAAA-MM-DD (por defecto: último dato del Excel)')
    a=ap.parse_args(); os.makedirs(a.salida,exist_ok=True)
    load.FILES.update({2024:getattr(a,'2024'),2025:getattr(a,'2025'),2026:getattr(a,'2026')})
    df,cal=build(a.corte)
    out=pd.DataFrame({'vigencia':df.vigencia,'radicacion_ente':df.rad_ente,'ente':df.ente,'orfeo_entrada':df.orfeo_entrada,
      'fecha_recibo':df.fecha_recibo.dt.strftime('%Y-%m-%d'),'organismo':df.organismo,'tipo_organismo':df.nivel,'asunto':df.asunto,
      'termino_dias_habiles':df.dias_habiles_termino.astype('Int64'),'fecha_maxima':df.fecha_max.dt.strftime('%Y-%m-%d'),
      'orfeo_respuesta':df.orfeo_respuesta,'fecha_respuesta':df.fecha_respuesta.dt.strftime('%Y-%m-%d'),'respondio':df.respondio,'tardia':df.tardia,
      'oportunidad':df.oportunidad,'retraso_dias_habiles':df.dias_retraso_habiles.astype('Int64'),'dias_habiles_responder':df.dias_hasta_responder_habiles.astype('Int64'),
      'estado_excel':df.estado_excel,'observaciones':df.observaciones,'fila_excel':df.fila_excel}).sort_values(['vigencia','fecha_recibo','fila_excel'])
    out.to_csv(os.path.join(a.salida,'historico_requerimientos.csv'),index=False,encoding='utf-8')
    cal.to_csv(os.path.join(a.salida,'calidad_de_datos.csv'),index=False,encoding='utf-8')
    print(f'{len(out)} registros; corte de datos {out.fecha_respuesta.max()}; {len(cal)} filas para revisar (calidad_de_datos.csv)')
    if a.gabinete:
        d=extraer(a.gabinete); guardar_csv(d,os.path.join(a.salida,'directorio_gabinete.csv')); print(len(d),'contactos de secretarios y directores')
if __name__=='__main__': main()
