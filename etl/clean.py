from load import *
import unicodedata, numpy as np, holidays
from collections import Counter

HOY = None   # CORTE DE DATOS: se calcula en build() como la fecha más reciente (radicación o respuesta) que aparece en los Excel

MES = {'ene':1,'feb':2,'mar':3,'abr':4,'apr':4,'may':5,'jun':6,'jul':7,'ago':8,'aug':8,'sep':9,'sept':9,'oct':10,'nov':11,'dic':12,'dec':12}
def pdate(v):
    """Devuelve (Timestamp|NaT, texto_original_si_no_se_pudo)"""
    if v is None or (isinstance(v,float) and np.isnan(v)): return pd.NaT, None
    if isinstance(v,(dt.datetime,dt.date,pd.Timestamp)): return pd.Timestamp(v).normalize(), None
    s=str(v).strip().lower()
    m=re.fullmatch(r'(\d{1,2})[-/ ]([a-z]{3,4})\.?[-/ ](\d{2,4})',s)
    if m and m.group(2) in MES:
        y=int(m.group(3)); y = y+2000 if y<100 else y
        try: return pd.Timestamp(y,MES[m.group(2)],int(m.group(1))), None
        except: pass
    m=re.fullmatch(r'(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})',s)
    if m:
        y=int(m.group(3)); y = y+2000 if y<100 else y
        try: return pd.Timestamp(y,int(m.group(2)),int(m.group(1))), None
        except: pass
    return pd.NaT, str(v)

def fold(s):
    s=unicodedata.normalize('NFKD',str(s)); s=''.join(c for c in s if not unicodedata.combining(c))
    return re.sub(r'\s+',' ',re.sub(r'[^a-z0-9 ]+',' ',s.lower())).strip()

# ---- Normalización de organismos: (patrón sobre texto sin tildes, nombre canónico, nivel, confianza) ----
SUB = 'Subunidad'
EXTRA = [
 (r'insp\w* polic|inspeccion de policia', 'Secretaría de Seguridad y Justicia','Secretaría','alta'),
 (r'acceso a (servicios de )?(la )?justicia', 'Secretaría de Seguridad y Justicia','Secretaría','alta'),
 (r'(subsecretari[ao] (de )?(la )?)?politica de seguridad', 'Secretaría de Seguridad y Justicia','Secretaría','alta'),
 (r'derechos humanos y construccion de paz', 'Secretaría de Paz y Cultura Ciudadana','Secretaría','alta'),
 (r'mejoramiento integral y legalizacion', 'Secretaría de Vivienda Social y Hábitat','Secretaría','alta'),
 (r'catast|finanzas publicas', 'Departamento Administrativo de Hacienda Municipal','Departamento','alta'),
 (r'doctrina y asuntos normativos', 'Departamento Administrativo de Gestión Jurídica Pública','Departamento','alta'),
 (r'centro de administracion local integrada|\bcali \d|cali rural', 'Secretaría de Desarrollo Territorial y Participación Ciudadana','Secretaría','alta'),
 (r'takeshima', 'Unidad Administrativa Especial Estudios Takeshima','UAE','alta'),
 (r'gestion ambiental', 'Departamento Administrativo de Gestión del Medio Ambiente (DAGMA)','Departamento','alta'),
 (r'contrataci', 'Departamento Administrativo de Contratación Pública','Departamento','alta'),
 (r'tecnolog|tenolog', 'Departamento Administrativo de Tecnologías de la Información y las Comunicaciones','Departamento','alta'),
 (r'suguridad|seguridad y just', 'Secretaría de Seguridad y Justicia','Secretaría','alta'),
 (r'educac', 'Secretaría de Educación','Secretaría','alta'),
 (r'subsecretari[ao] (de )?(la )?primera infancia', 'Subsecretaría de Primera Infancia (padre por confirmar)','Subunidad','media'),
 (r'subsecretari[ao] (de )?equidad', 'Subsecretaría de Equidad de Género (padre por confirmar)','Subunidad','media'),
 (r'subsecretari[ao] (de )?(poblaciones y etnias|etnias y poblaciones)', 'Subsecretaría de Poblaciones y Etnias (padre por confirmar)','Subunidad','media'),
 (r'subsecretari[ao] (de )?atencion', 'Subsecretaría de Atención Integral a Víctimas (padre por confirmar)','Subunidad','media'),
 (r'subsecretari[ao] (de )?inspeccion|^vigilancia y control', 'Subsecretaría de Inspección, Vigilancia y Control (padre por confirmar)','Subunidad','media'),
 (r'tramites servicios y gestion documental', 'Subdirección de Trámites, Servicios y Gestión Documental (padre por confirmar)','Subunidad','media'),
]
EXTRA3 = [
 (r'contrav', 'Oficina de Contravenciones (padre por confirmar)','Subunidad','media'),
 (r'comiaria', 'Secretaría de Seguridad y Justicia','Secretaría','alta'),
 (r'talento humane', 'Departamento Administrativo de Desarrollo e Innovación Institucional','Departamento','alta'),
 (r'politica de segurdad', 'Secretaría de Seguridad y Justicia','Secretaría','alta'),
 (r'infaestructura', 'Secretaría de Infraestructura','Secretaría','alta'),
 (r'defensa judicial|defense judicial|prevencion del dano antijuridico', 'Departamento Administrativo de Gestión Jurídica Pública','Departamento','alta'),
 (r'patrimonio|bibliotecas', 'Secretaría de Cultura','Secretaría','alta'),
 (r'inspeccion urbano de policia', 'Secretaría de Seguridad y Justicia','Secretaría','alta'),
]
EXTRA2 = [
 (r'^\d{1,3}( y \d{1,3})?$|^y \d+$', 'Sin dato','Otro','baja'),
 (r'comis\w*ri|corregidor', 'Secretaría de Seguridad y Justicia','Secretaría','alta'),
 (r'secretaria de (ed\w*c\w*n|edcuac\w*|eduac\w*)', 'Secretaría de Educación','Secretaría','alta'),
 (r'cobertura educativa', 'Secretaría de Educación','Secretaría','alta'),
 (r'seguridad y j\w+|secretaria de inspeccion', 'Secretaría de Seguridad y Justicia','Secretaría','alta'),
 (r'infra\w{3,}ructura', 'Secretaría de Infraestructura','Secretaría','alta'),
 (r'sec+retaria privada', 'Oficina de la Secretaría Privada y Despacho del Alcalde','Despacho','alta'),
 (r'etnias', 'Subsecretaría de Poblaciones y Etnias (padre por confirmar)','Subunidad','media'),
 (r'contra\w+ publica', 'Departamento Administrativo de Contratación Pública','Departamento','alta'),
 (r'cobro (coactivo|persuasivo|coativo)|tesoreria|administracion de pagos', 'Departamento Administrativo de Hacienda Municipal','Departamento','alta'),
 (r'subdireccion desarrollo integral', 'Departamento Administrativo de Planeación Municipal','Departamento','alta'),
 (r'transparencia', 'Oficina de Transparencia (padre por confirmar)','Subunidad','media'),
 (r'contravenciones', 'Oficina de Contravenciones (padre por confirmar)','Subunidad','media'),
]
RULES = EXTRA3 + EXTRA2 + EXTRA + [
 # subunidades con padre de confianza alta (se suman al padre)
 (r'subsecretaria de acceso a servicios de justicia|comisaria|inspeccion de policia|inspector', 'Secretaría de Seguridad y Justicia','Secretaría','alta'),
 (r'subsecretaria de la politica de seguridad', 'Secretaría de Seguridad y Justicia','Secretaría','alta'),
 (r'subsecretaria de promocion y fortalecimiento de la participacion', 'Secretaría de Desarrollo Territorial y Participación Ciudadana','Secretaría','alta'),
 (r'subsecretaria (proteccion de la salud|de promocion prevencion)|subsecretaria de salud|promocion prevencion y produccion social', 'Secretaría de Salud Pública','Secretaría','alta'),
 (r'subsecretaria de infraestructura y mantenimiento vial', 'Secretaría de Infraestructura','Secretaría','alta'),
 (r'subsecretaria de infraestructura deportiva', 'Secretaría del Deporte y la Recreación','Secretaría','alta'),
 (r'subsecretaria de movilidad sostenible', 'Secretaría de Movilidad','Secretaría','alta'),
 (r'subsecretaria de artes', 'Secretaría de Cultura','Secretaría','alta'),
 (r'subdireccion (de )?(finanzas publicas|tesoreria|de impuestos|de catastro)|oficina tecnica operativa de cobro coactivo|contaduria', 'Departamento Administrativo de Hacienda Municipal','Departamento','alta'),
 (r'subdireccion (de )?(planificacion del territorio|de espacio publico|de desarrollo integral)', 'Departamento Administrativo de Planeación Municipal','Departamento','alta'),
 (r'(subdireccion|subsecretaria) (de )?gesti\w* estrategica (de )?(del )?talento humano|subdireccion estrategica de talento humano|talento humano', 'Departamento Administrativo de Desarrollo e Innovación Institucional','Departamento','alta'),
 # subunidades SIN padre confirmado (quedan como fila propia, a confirmar)
 (r'subsecretaria de equidad de gener', 'Subsecretaría de Equidad de Género (padre por confirmar)',SUB,'media'),
 (r'subsecretaria de poblaciones y etnias', 'Subsecretaría de Poblaciones y Etnias (padre por confirmar)',SUB,'media'),
 (r'subsecretaria de atencion (integral )?a victimas', 'Subsecretaría de Atención Integral a Víctimas (padre por confirmar)',SUB,'media'),
 (r'subsecretaria de inspeccion', 'Subsecretaría de Inspección, Vigilancia y Control (padre por confirmar)',SUB,'media'),
 # organismos principales
 (r'secretaria privada|despacho (del )?alcalde|^alcalde|^alcaldia$|^alcalde$', 'Oficina de la Secretaría Privada y Despacho del Alcalde','Despacho','alta'),
 (r'todos los organismos', 'Todos los organismos','Otro','alta'),
 (r'paz y cultura', 'Secretaría de Paz y Cultura Ciudadana','Secretaría','alta'),
 (r'seguridad y just|seguridad y justcia|seguridad y jus', 'Secretaría de Seguridad y Justicia','Secretaría','alta'),
 (r'educacion', 'Secretaría de Educación','Secretaría','alta'),
 (r'movilidad', 'Secretaría de Movilidad','Secretaría','alta'),
 (r'bienestar|binestar', 'Secretaría de Bienestar Social','Secretaría','alta'),
 (r'salud', 'Secretaría de Salud Pública','Secretaría','alta'),
 (r'infraestructura', 'Secretaría de Infraestructura','Secretaría','alta'),
 (r'hacienda', 'Departamento Administrativo de Hacienda Municipal','Departamento','alta'),
 (r'desarrollo (e )?innovacion|desarrollo institucional|dadii|desarrollo e inovacion', 'Departamento Administrativo de Desarrollo e Innovación Institucional','Departamento','alta'),
 (r'planeacion', 'Departamento Administrativo de Planeación Municipal','Departamento','alta'),
 (r'desarrollo territorial|participacion ciudadana', 'Secretaría de Desarrollo Territorial y Participación Ciudadana','Secretaría','alta'),
 (r'gobierno', 'Secretaría de Gobierno','Secretaría','alta'),
 (r'medio ambiente|dagma', 'Departamento Administrativo de Gestión del Medio Ambiente (DAGMA)','Departamento','alta'),
 (r'desarrollo economico', 'Secretaría de Desarrollo Económico','Secretaría','alta'),
 (r'cultura', 'Secretaría de Cultura','Secretaría','alta'),
 (r'bienes y servicios', 'Unidad Administrativa Especial de Gestión de Bienes y Servicios','UAE','alta'),
 (r'control disciplinario', 'Departamento Administrativo de Control Disciplinario Interno','Departamento','alta'),
 (r'control interno', 'Departamento Administrativo de Control Interno','Departamento','alta'),
 (r'servicios publicos|uaesp', 'Unidad Administrativa Especial de Servicios Públicos Municipales','UAE','alta'),
 (r'gestion juridica|juridica', 'Departamento Administrativo de Gestión Jurídica Pública','Departamento','alta'),
 (r'deporte', 'Secretaría del Deporte y la Recreación','Secretaría','alta'),
 (r'contratacion publica', 'Departamento Administrativo de Contratación Pública','Departamento','alta'),
 (r'vivienda', 'Secretaría de Vivienda Social y Hábitat','Secretaría','alta'),
 (r'riesgo', 'Secretaría de Gestión del Riesgo de Emergencias y Desastres','Secretaría','alta'),
 (r'tecnologias de la informacion|\btic\b', 'Departamento Administrativo de Tecnologías de la Información y las Comunicaciones','Departamento','alta'),
 (r'turismo', 'Secretaría de Turismo','Secretaría','alta'),
 (r'proteccion animal', 'Unidad Administrativa Especial de Protección Animal','UAE','alta'),
 (r'teatro municipal', 'Teatro Municipal Enrique Buenaventura','UAE','alta'),
]
CRULES=[(re.compile(p),n,l,c) for p,n,l,c in RULES]

PARENT = {
 'Subsecretaría de Equidad de Género (padre por confirmar)':('Secretaría de Bienestar Social','Secretaría'),
 'Subsecretaría de Poblaciones y Etnias (padre por confirmar)':('Secretaría de Bienestar Social','Secretaría'),
 'Subsecretaría de Atención Integral a Víctimas (padre por confirmar)':('Secretaría de Bienestar Social','Secretaría'),
 'Subsecretaría de Primera Infancia (padre por confirmar)':('Secretaría de Bienestar Social','Secretaría'),
 'Subsecretaría de Inspección, Vigilancia y Control (padre por confirmar)':('Secretaría de Seguridad y Justicia','Secretaría'),
 'Oficina de Contravenciones (padre por confirmar)':('Secretaría de Movilidad','Secretaría'),
 'Subdirección de Trámites, Servicios y Gestión Documental (padre por confirmar)':('Departamento Administrativo de Desarrollo e Innovación Institucional','Departamento'),
 'Oficina de Transparencia (padre por confirmar)':('Oficina de la Secretaría Privada y Despacho del Alcalde','Despacho'),
}
def canon_one(txt):
    f=fold(txt)
    for rx,n,l,c in CRULES:
        if rx.search(f):
            if n in PARENT: n,l=PARENT[n]; c='alta'
            return n,l,c
    return None
def split_orgs(txt):
    """Un texto puede nombrar varios organismos ('Despacho Alcalde, Secretaría X y Secretaría Y')."""
    if txt is None: return []
    parts=re.split(r'\s*(?:,|;|/|\+|\sy\s(?=(?:secretar|departamento|despacho|oficina|unidad|subsecretar|subdirec|dagma|alcald)))\s*',str(txt),flags=re.I)
    out=[]
    for p in parts:
        if not p.strip(): continue
        c=canon_one(p)
        key=(c[0],c[1],c[2]) if c else (re.sub(r'\s+',' ',p.strip()),'Sin clasificar','baja')
        if key[0] not in [o[0] for o in out]: out.append(key)
    return out

# ------------------------------------------------------------------
# Construcción de la tabla consolidada
# ------------------------------------------------------------------
FER = holidays.Colombia(years=range(2023,2028))
HOL = np.array(sorted(FER.keys()),dtype='datetime64[D]')
def bdays(a,b):
    """días hábiles en (a, b] ; negativo si b<a"""
    if pd.isna(a) or pd.isna(b): return np.nan
    a=np.datetime64(a.date()); b=np.datetime64(b.date())
    if b>=a: return int(np.busday_count(a+1,b+1,holidays=HOL))
    return -int(np.busday_count(b+1,a+1,holidays=HOL))
NOAPL = re.compile(r'^(n/?a|no aplica|no aplic\w*|sin respuesta|ninguno)$',re.I)
def idstr(v):
    if v is None or (isinstance(v,float) and np.isnan(v)): return None
    t=str(v).strip()
    return t[:-2] if re.fullmatch(r'\d+\.0',t) else t

def build(corte=None):
    global HOY
    d=pd.concat([load(v) for v in (2024,2025,2026)],ignore_index=True)
    if corte is not None: HOY=pd.Timestamp(corte)
    else:
        fechas=[pdate(x)[0] for x in list(d.fecha_radicacion)+list(d.fecha_resp)]
        HOY=max(f for f in fechas if not pd.isna(f))
    out=[]; calidad=[]
    for _,r in d.iterrows():
        q=lambda tipo,det: calidad.append(dict(vigencia=r.vigencia,fila_excel=r.fila_excel,rad_ente=r.rad_ente,tipo=tipo,detalle=det))
        fmax,fm_bad=pdate(r.fecha_max); fresp,fr_bad=pdate(r.fecha_resp)
        frad,_=pdate(r.fecha_radicacion); fdaci,_=pdate(r.fecha_daci); foficio,_=pdate(r.fecha_oficio)
        frecibo = fdaci if not pd.isna(fdaci) else frad
        dh = None
        try: dh=int(float(r.dias_habiles))
        except: pass
        requiere = (dh is not None and dh>0) if r.vigencia==2026 else True
        if r.vigencia<2026 and dh is None: q('Término sin dato','Días hábiles vacío o no numérico: '+str(r.dias_habiles))
        # organismo responsable
        rsp = None if pd.isna(r.responde) else r.responde
        dir_ = None if pd.isna(r.dirigido) else r.dirigido
        base = rsp if rsp else dir_
        orgs = split_orgs(base) or split_orgs(dir_)
        if orgs: org,nivel,_=orgs[0]
        else:
            org,nivel='Sin dato','Otro'
            q('Organismo vacío','No hay organismo responsable registrado')
        todos = ' | '.join(o[0] for o in orgs)
        if nivel=='Sin clasificar': q('Organismo sin clasificar',str(base))
        orfeo_txt = None if (r.orfeo_resp is None or NOAPL.match(str(r.orfeo_resp))) else str(r.orfeo_resp)
        has_orfeo = orfeo_txt is not None
        cerrado = (str(r.estado).lower()=='cerrado')
        if fr_bad: q('Fecha de respuesta ilegible','Valor en Excel: '+fr_bad)
        if fm_bad and requiere: q('Fecha máxima ilegible','Valor en Excel: '+fm_bad)
        respondio = (not pd.isna(fresp)) or (cerrado and has_orfeo)
        if requiere:
            if not pd.isna(fresp) and not pd.isna(fmax):
                if fresp<=fmax: oport='A tiempo'
                else: oport='Tardía'
            elif respondio: oport='Respondida (sin fecha para medir)'; q('Respondida sin fecha medible','Tiene ORFEO/estado cerrado pero la fecha de respuesta falta o es ilegible')
            elif pd.isna(fmax): oport='Pendiente en término'; q('Sin fecha máxima','No se puede evaluar el vencimiento')
            elif fmax<HOY: oport='Sin respuesta (vencida)'
            else: oport='Pendiente en término'
        else:
            oport='No requiere respuesta'
        if requiere and cerrado and not respondio: q('Cerrado sin respuesta','Estado Cerrado pero sin fecha ni radicado ORFEO de respuesta')
        if requiere and (not cerrado) and respondio and r.estado is not None: q('Abierto con respuesta','Estado "Abierto" pero ya tiene respuesta registrada')
        if not pd.isna(fresp) and not pd.isna(frecibo) and fresp<frecibo: q('Respuesta anterior a recepción','Fecha de respuesta menor a la fecha de recibo')
        retraso_h = bdays(fmax,fresp) if oport=='Tardía' else (bdays(fmax,HOY) if oport=='Sin respuesta (vencida)' else np.nan)
        retraso_c = (fresp-fmax).days if oport=='Tardía' else ((HOY-fmax).days if oport=='Sin respuesta (vencida)' else np.nan)
        tiempo = bdays(frecibo,fresp) if (requiere and not pd.isna(fresp)) else np.nan
        out.append(dict(vigencia=int(r.vigencia),orden=r.orden,rad_ente=idstr(r.rad_ente),ente=r.ente,orfeo_entrada=idstr(r.orfeo_entrada),
            fecha_oficio=foficio,fecha_radicacion=frad,fecha_recibo=frecibo,organismo=org,nivel=nivel,organismos_involucrados=todos,
            dirigido_original=r.dirigido,responde_original=r.responde,asunto=r.asunto,clase=r.clase,dias_habiles_termino=dh,fecha_max=fmax,
            orfeo_respuesta=orfeo_txt,fecha_respuesta=fresp,estado_excel=r.estado,requiere_respuesta=requiere,
            respondio=('Sí' if respondio else 'No') if requiere else 'No aplica',
            oportunidad=oport,
            tardia=('Sí' if oport=='Tardía' else 'No') if requiere else 'No aplica',
            dias_retraso_habiles=retraso_h,dias_retraso_calendario=retraso_c,dias_hasta_responder_habiles=tiempo,
            observaciones=r.obs,fila_excel=int(r.fila_excel)))
    return pd.DataFrame(out), pd.DataFrame(calidad)
