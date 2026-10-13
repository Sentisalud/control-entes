"""Prueba de regresión del ETL. Requiere los Excel reales:
  CE_DATA=/ruta/con/excels python -m unittest tests/etl_test.py
Los valores esperados corresponden a los archivos entregados con corte 29/07/2026; si los Excel cambian, actualizarlos aquí."""
import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'etl'))
D = os.environ.get('CE_DATA')

@unittest.skipUnless(D, 'definir CE_DATA con la carpeta de los Excel')
class ETL(unittest.TestCase):
    def test_totales(self):
        import load; from clean import build
        load.FILES.update({2024: os.path.join(D,'control_2024.xlsx'), 2025: os.path.join(D,'control_2025.xlsx'), 2026: os.path.join(D,'control_2026.xlsx')})
        df, cal = build()
        self.assertEqual(len(df), 2568)
        c = df.oportunidad.value_counts().to_dict()
        self.assertEqual((c['A tiempo'], c['Tardía'], c['Sin respuesta (vencida)']), (1461, 799, 157))
        inc = c['Tardía'] + c['Sin respuesta (vencida)']; ev = c['A tiempo'] + inc
        self.assertAlmostEqual(inc / ev, 0.3955, places=3)
        self.assertEqual(df[df.organismo == 'Secretaría de Seguridad y Justicia'].oportunidad.isin(['Tardía','Sin respuesta (vencida)']).sum(), 187)
        self.assertFalse((df.organismo == 'Sin clasificar').any())

if __name__ == '__main__':
    unittest.main()
