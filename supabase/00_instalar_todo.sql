-- =====================================================================
-- INSTALADOR COMPLETO · Control de Entes · Alcaldía de Santiago de Cali
-- Contiene, en orden, los scripts 01 a 06. Ejecutar UNA sola vez en el SQL Editor
-- de un proyecto de Supabase vacío. Luego importar los CSV: primero el histórico,
-- después el directorio.
-- =====================================================================

-- >>>>>>>>>>>>>>>>>>>> 01_schema.sql <<<<<<<<<<<<<<<<<<<<
-- =====================================================================
-- CONTROL DE ENTES · Alcaldía de Santiago de Cali
-- Esquema completo para Supabase (ejecutar una sola vez en SQL Editor)
--
-- CAPA 1  Roles y políticas (RLS)            -> profiles, current_rol(), policies
-- CAPA 2  Auditoría inmutable SHA-256        -> audit_log, audit_trigger(), verificar_cadena_auditoria()
-- CAPA 3  Validación y anti-duplicados       -> UNIQUE + cerrar_requerimiento()
-- CAPA 4  Riesgo por vencimiento y escalamiento -> v_requerimientos (semáforo), escalar_requerimiento()
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- Catálogos
-- ---------------------------------------------------------------------
create table if not exists public.config (
  id                   int primary key default 1 check (id = 1),
  dias_rojo            int  not null default 5 check (dias_rojo between 1 and 30),
  correo_disciplinario text not null default ''
);
insert into public.config (id) values (1) on conflict do nothing;

create table if not exists public.entes (
  id         bigint generated always as identity primary key,
  nombre     text not null unique,
  sigla      text not null default '',
  tipo       text not null default 'Otro',
  activo     boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.dependencias (
  id                bigint generated always as identity primary key,
  nombre            text not null unique,
  secretario_nombre text not null default '',
  correo            text not null default '',
  telefono          text not null default '',
  activo            boolean not null default true,
  created_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- CAPA 1 · Perfiles y roles
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  email          text,
  nombre         text,
  rol            text not null default 'enlace'
                 check (rol in ('admin','alcalde','secretario','enlace','control_interno')),
  dependencia_id bigint references public.dependencias(id),
  activo         boolean not null default false,
  created_at     timestamptz not null default now()
);

-- Toda cuenta nueva nace como 'enlace'. Solo queda ACTIVA si usa correo @cali.gov.co.
-- Un admin puede activar cuentas con otro dominio manualmente.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, nombre, activo)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email, '@', 1)),
    lower(new.email) like '%@cali.gov.co'
  );
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.current_rol()
returns text language sql stable security definer set search_path = public as $$
  select rol from public.profiles where id = auth.uid() and activo
$$;

create or replace function public.current_dep()
returns bigint language sql stable security definer set search_path = public as $$
  select dependencia_id from public.profiles where id = auth.uid() and activo
$$;

-- ---------------------------------------------------------------------
-- Requerimientos
-- ---------------------------------------------------------------------
create table if not exists public.requerimientos (
  id              uuid primary key default gen_random_uuid(),
  radicado        text not null,
  vigencia        int  not null,
  ente_id         bigint not null references public.entes(id),
  dependencia_id  bigint not null references public.dependencias(id),
  asunto          text not null check (length(trim(asunto)) > 3),
  fecha_radicacion date not null default current_date,
  fecha_limite    date not null,
  estado          text not null default 'abierto' check (estado in ('abierto','cerrado')),
  orfeo_salida    text,
  fecha_cierre    date,
  soporte_path    text,
  soporte_hash    text,
  escalado_at     timestamptz,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),

  -- CAPA 3 · anti-duplicados a nivel de base de datos
  constraint requerimientos_radicado_unq unique (radicado),
  constraint requerimientos_orfeo_unq    unique (orfeo_salida),
  constraint requerimientos_radicado_fmt check (radicado ~ '^[0-9]{4}[A-Z]{2}[0-9]{4,10}$'),
  constraint requerimientos_limite_ok    check (fecha_limite >= fecha_radicacion),
  constraint requerimientos_cierre_ok    check (
    (estado = 'abierto' and orfeo_salida is null and fecha_cierre is null)
    or
    (estado = 'cerrado' and orfeo_salida ~ '^[0-9]{10,20}$' and fecha_cierre is not null)
  )
);
create index if not exists idx_req_vigencia on public.requerimientos (vigencia, estado, fecha_limite);
create index if not exists idx_req_dep      on public.requerimientos (dependencia_id);

-- CAPA 4 · semáforo calculado por vencimiento (umbral configurable en public.config)
create or replace view public.v_requerimientos with (security_invoker = true) as
select
  r.*,
  e.nombre as ente,
  e.sigla  as ente_sigla,
  d.nombre as dependencia,
  (r.fecha_limite - current_date) as dias_restantes,
  case
    when r.estado = 'cerrado' then 'verde'
    when (r.fecha_limite - current_date) <= (select dias_rojo from public.config where id = 1) then 'rojo'
    else 'amarillo'
  end as semaforo
from public.requerimientos r
join public.entes e        on e.id = r.ente_id
join public.dependencias d on d.id = r.dependencia_id;

create table if not exists public.alertas_log (
  id                bigint generated always as identity primary key,
  requerimiento_id  uuid not null references public.requerimientos(id),
  canal             text not null check (canal in ('whatsapp','correo','registro','disciplinario')),
  enviado_por       uuid default auth.uid(),
  created_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- CAPA 2 · Auditoría inmutable (cadena de custodia SHA-256)
-- Cada fila incluye el hash de la fila anterior: alterar o borrar cualquier
-- registro rompe la cadena y verificar_cadena_auditoria() lo detecta.
-- ---------------------------------------------------------------------
create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  tabla       text not null,
  registro_id text not null,
  accion      text not null,
  usuario     text not null,
  payload     jsonb not null,
  cambios     jsonb not null default '{}',   -- en UPDATE: {campo: {de: valor anterior, a: valor nuevo}}
  prev_hash   text not null,
  hash        text not null,
  created_at  timestamptz not null default now()
);

create or replace function public.audit_hash(
  p_prev text, p_tabla text, p_accion text, p_registro text,
  p_usuario text, p_ts timestamptz, p_payload jsonb, p_cambios jsonb default '{}'
) returns text language sql immutable set search_path = public, extensions as $$
  select encode(
    extensions.digest(
      p_prev || '|' || p_tabla || '|' || p_accion || '|' || p_registro || '|' || p_usuario || '|' ||
      to_char(p_ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|' || p_payload::text || '|' || p_cambios::text,
      'sha256'),
    'hex')
$$;

create or replace function public.audit_trigger()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  v_prev    text;
  v_payload jsonb;
  v_cambios jsonb := '{}'::jsonb;
  v_id      text;
  v_user    text := coalesce(auth.uid()::text, 'sistema');
  v_ts      timestamptz := date_trunc('microseconds', clock_timestamp());
begin
  perform pg_advisory_xact_lock(727001);   -- serializa la cadena
  select hash into v_prev from public.audit_log order by id desc limit 1;
  v_prev := coalesce(v_prev, repeat('0', 64));

  if tg_op = 'DELETE' then
    v_payload := to_jsonb(old);  v_id := old.id::text;
  else
    v_payload := to_jsonb(new);  v_id := new.id::text;
  end if;
  if tg_op = 'UPDATE' then
    select coalesce(jsonb_object_agg(n.key, jsonb_build_object('de', o.value, 'a', n.value)), '{}'::jsonb)
      into v_cambios
      from jsonb_each(to_jsonb(new)) n
      left join jsonb_each(to_jsonb(old)) o on o.key = n.key
     where n.value is distinct from o.value;
  end if;

  insert into public.audit_log (tabla, registro_id, accion, usuario, payload, cambios, prev_hash, hash, created_at)
  values (tg_table_name, v_id, tg_op, v_user, v_payload, v_cambios, v_prev,
          public.audit_hash(v_prev, tg_table_name, tg_op, v_id, v_user, v_ts, v_payload, v_cambios), v_ts);

  return coalesce(new, old);
end $$;

create or replace function public.audit_block_changes()
returns trigger language plpgsql as $$
begin
  raise exception 'La pista de auditoría es inmutable: no se permite % sobre audit_log', tg_op;
end $$;

drop trigger if exists trg_audit_immutable on public.audit_log;
create trigger trg_audit_immutable
  before update or delete on public.audit_log
  for each row execute function public.audit_block_changes();

drop trigger if exists trg_audit_immutable_trunc on public.audit_log;
create trigger trg_audit_immutable_trunc
  before truncate on public.audit_log
  for each statement execute function public.audit_block_changes();

drop trigger if exists trg_audit_req on public.requerimientos;
create trigger trg_audit_req after insert or update or delete on public.requerimientos
  for each row execute function public.audit_trigger();

drop trigger if exists trg_audit_profiles on public.profiles;
create trigger trg_audit_profiles after update or delete on public.profiles
  for each row execute function public.audit_trigger();

drop trigger if exists trg_audit_alertas on public.alertas_log;
create trigger trg_audit_alertas after insert on public.alertas_log
  for each row execute function public.audit_trigger();

drop trigger if exists trg_audit_entes on public.entes;
create trigger trg_audit_entes after insert or update on public.entes
  for each row execute function public.audit_trigger();

drop trigger if exists trg_audit_deps on public.dependencias;
create trigger trg_audit_deps after insert or update on public.dependencias
  for each row execute function public.audit_trigger();

create or replace function public.verificar_cadena_auditoria()
returns table (ok boolean, total bigint, primer_id_roto bigint)
language plpgsql security definer set search_path = public, extensions as $$
declare
  r      record;
  v_prev text := repeat('0', 64);
  v_calc text;
  n      bigint := 0;
begin
  if public.current_rol() is null then
    raise exception 'Sin permiso';
  end if;
  for r in select * from public.audit_log order by id loop
    n := n + 1;
    v_calc := public.audit_hash(v_prev, r.tabla, r.accion, r.registro_id, r.usuario, r.created_at, r.payload, r.cambios);
    if r.prev_hash <> v_prev or r.hash <> v_calc then
      return query select false, n, r.id;
      return;
    end if;
    v_prev := r.hash;
  end loop;
  return query select true, n, null::bigint;
end $$;

-- ---------------------------------------------------------------------
-- CAPA 3 · Cierre de requerimiento con validación (servidor)
-- ---------------------------------------------------------------------
create or replace function public.cerrar_requerimiento(
  p_id uuid, p_orfeo text, p_fecha date, p_path text default null, p_hash text default null
) returns public.requerimientos
language plpgsql security definer set search_path = public as $$
declare
  v_rol text := public.current_rol();
  v_dep bigint := public.current_dep();
  v_req public.requerimientos;
begin
  if v_rol not in ('admin','secretario','enlace') then
    raise exception 'Tu rol no puede registrar respuestas ORFEO';
  end if;

  select * into v_req from public.requerimientos where id = p_id for update;
  if not found then raise exception 'El requerimiento no existe'; end if;
  if v_rol <> 'admin' and v_req.dependencia_id is distinct from v_dep then
    raise exception 'Este requerimiento pertenece a otra dependencia';
  end if;
  if v_req.estado = 'cerrado' then raise exception 'El requerimiento ya está cerrado'; end if;
  if p_orfeo !~ '^[0-9]{10,20}$' then raise exception 'El radicado ORFEO debe tener entre 10 y 20 dígitos'; end if;
  if p_fecha > current_date then raise exception 'La fecha de envío no puede ser futura'; end if;
  if p_fecha < v_req.fecha_radicacion then raise exception 'La fecha de envío no puede ser anterior a la radicación'; end if;

  begin
    update public.requerimientos
       set estado = 'cerrado', orfeo_salida = p_orfeo, fecha_cierre = p_fecha,
           soporte_path = p_path, soporte_hash = p_hash
     where id = p_id
     returning * into v_req;
  exception when unique_violation then
    raise exception 'El radicado ORFEO % ya fue registrado en otro requerimiento', p_orfeo;
  end;
  return v_req;
end $$;

-- ---------------------------------------------------------------------
-- CAPA 4 · Escalamiento
-- ---------------------------------------------------------------------
create or replace function public.escalar_requerimiento(p_id uuid, p_canal text default 'registro')
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.current_rol() not in ('admin','alcalde','control_interno','enlace') then
    raise exception 'Tu rol no puede escalar alertas';
  end if;
  if not exists (select 1 from public.requerimientos where id = p_id and estado = 'abierto') then
    raise exception 'El requerimiento no existe o ya está cerrado';
  end if;
  insert into public.alertas_log (requerimiento_id, canal) values (p_id, p_canal);
  update public.requerimientos set escalado_at = now() where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- CAPA 1 · Row Level Security
-- ---------------------------------------------------------------------
alter table public.config         enable row level security;
alter table public.entes          enable row level security;
alter table public.dependencias   enable row level security;
alter table public.profiles       enable row level security;
alter table public.requerimientos enable row level security;
alter table public.alertas_log    enable row level security;
alter table public.audit_log      enable row level security;

-- Lectura de catálogos y configuración: cualquier usuario activo
drop policy if exists config_read on public.config;
create policy config_read  on public.config        for select to authenticated using (public.current_rol() is not null);
drop policy if exists config_write on public.config;
create policy config_write on public.config        for update to authenticated using (public.current_rol() = 'admin') with check (public.current_rol() = 'admin');
drop policy if exists entes_read on public.entes;
create policy entes_read   on public.entes         for select to authenticated using (public.current_rol() is not null);
drop policy if exists entes_ins on public.entes;
create policy entes_ins    on public.entes         for insert to authenticated with check (public.current_rol() = 'admin');
drop policy if exists entes_upd on public.entes;
create policy entes_upd    on public.entes         for update to authenticated using (public.current_rol() = 'admin') with check (public.current_rol() = 'admin');
drop policy if exists deps_read on public.dependencias;
create policy deps_read    on public.dependencias  for select to authenticated using (public.current_rol() is not null);
drop policy if exists deps_ins on public.dependencias;
create policy deps_ins     on public.dependencias  for insert to authenticated with check (public.current_rol() = 'admin');
drop policy if exists deps_upd on public.dependencias;
create policy deps_upd     on public.dependencias  for update to authenticated using (public.current_rol() = 'admin') with check (public.current_rol() = 'admin');

-- Perfiles: cada quien ve el suyo; admin y control interno ven todos; solo admin modifica
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.current_rol() in ('admin','control_interno'));
drop policy if exists profiles_upd on public.profiles;
create policy profiles_upd  on public.profiles for update to authenticated
  using (public.current_rol() = 'admin') with check (public.current_rol() = 'admin');

-- Requerimientos: secretario/enlace solo ven su dependencia. Nadie borra. El cierre es vía cerrar_requerimiento().
drop policy if exists req_read on public.requerimientos;
create policy req_read on public.requerimientos for select to authenticated using (
  public.current_rol() in ('admin','alcalde','control_interno')
  or (public.current_rol() in ('secretario','enlace') and dependencia_id = public.current_dep())
);
drop policy if exists req_ins on public.requerimientos;
create policy req_ins on public.requerimientos for insert to authenticated with check (
  public.current_rol() = 'admin'
  or (public.current_rol() = 'enlace' and dependencia_id = public.current_dep())
);
drop policy if exists req_upd on public.requerimientos;
create policy req_upd on public.requerimientos for update to authenticated
  using (public.current_rol() = 'admin') with check (public.current_rol() = 'admin');

-- Alertas y auditoría: solo lectura para roles de supervisión
drop policy if exists alertas_read on public.alertas_log;
create policy alertas_read on public.alertas_log for select to authenticated
  using (public.current_rol() in ('admin','alcalde','control_interno'));
drop policy if exists audit_read on public.audit_log;
create policy audit_read on public.audit_log for select to authenticated
  using (public.current_rol() in ('admin','alcalde','control_interno'));

revoke all on public.audit_log from anon, authenticated;
grant select on public.audit_log to authenticated;
revoke all on public.alertas_log from anon, authenticated;
grant select on public.alertas_log to authenticated;
revoke execute on all functions in schema public from anon;

grant usage on schema public to authenticated;
grant select, insert, update on public.entes, public.dependencias, public.requerimientos to authenticated;
grant select, update on public.profiles, public.config to authenticated;
grant select on public.v_requerimientos to authenticated;
grant execute on function public.cerrar_requerimiento(uuid, text, date, text, text) to authenticated;
grant execute on function public.escalar_requerimiento(uuid, text) to authenticated;
grant execute on function public.verificar_cadena_auditoria() to authenticated;
grant execute on function public.current_rol(), public.current_dep() to authenticated;

-- ---------------------------------------------------------------------
-- Almacenamiento privado de soportes PDF
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('soportes', 'soportes', false, 10485760, array['application/pdf'])
on conflict (id) do nothing;

drop policy if exists soportes_read on storage.objects;
create policy soportes_read on storage.objects for select to authenticated
  using (bucket_id = 'soportes' and public.current_rol() is not null);
drop policy if exists soportes_ins on storage.objects;
create policy soportes_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'soportes' and public.current_rol() in ('admin','secretario','enlace'));


-- >>>>>>>>>>>>>>>>>>>> 02_seed.sql <<<<<<<<<<<<<<<<<<<<
-- Catálogos iniciales (ejecutar después de 01_schema.sql).
-- Los nombres de dependencias y entes son los mismos del histórico 2024-2026 para que el alcance por dependencia funcione.

insert into public.entes (nombre, sigla, tipo) values
  ('Contraloría General de Santiago de Cali', 'CGSC', 'Fiscal'),
  ('Contraloría General de la República', 'CGR', 'Fiscal'),
  ('Contraloría de Bogotá D.C', 'CB', 'Fiscal'),
  ('Defensoría del Pueblo', 'DP', 'Ministerio Público'),
  ('Otro', '', 'Otro'),
  ('Personería Municipal Santiago de Cali', 'PMC', 'Ministerio Público'),
  ('Personería de Bogotá D.C', 'PB', 'Ministerio Público'),
  ('Procuraduría General de la Nación', 'PGN', 'Ministerio Público'),
  ('Procuraduría Provincial de Cali', 'PPC', 'Ministerio Público'),
  ('Procuraduría Regional del Valle', 'PRV', 'Ministerio Público')
on conflict (nombre) do nothing;

insert into public.dependencias (nombre) values
  ('Departamento Administrativo de Contratación Pública'),
  ('Departamento Administrativo de Control Disciplinario Interno'),
  ('Departamento Administrativo de Control Interno'),
  ('Departamento Administrativo de Desarrollo e Innovación Institucional'),
  ('Departamento Administrativo de Gestión Jurídica Pública'),
  ('Departamento Administrativo de Gestión del Medio Ambiente (DAGMA)'),
  ('Departamento Administrativo de Hacienda Municipal'),
  ('Departamento Administrativo de Planeación Municipal'),
  ('Departamento Administrativo de Tecnologías de la Información y las Comunicaciones'),
  ('Oficina de la Secretaría Privada y Despacho del Alcalde'),
  ('Secretaría de Bienestar Social'),
  ('Secretaría de Cultura'),
  ('Secretaría de Desarrollo Económico'),
  ('Secretaría de Desarrollo Territorial y Participación Ciudadana'),
  ('Secretaría de Educación'),
  ('Secretaría de Gestión del Riesgo de Emergencias y Desastres'),
  ('Secretaría de Gobierno'),
  ('Secretaría de Infraestructura'),
  ('Secretaría de Movilidad'),
  ('Secretaría de Paz y Cultura Ciudadana'),
  ('Secretaría de Salud Pública'),
  ('Secretaría de Seguridad y Justicia'),
  ('Secretaría de Turismo'),
  ('Secretaría de Vivienda Social y Hábitat'),
  ('Secretaría del Deporte y la Recreación'),
  ('Teatro Municipal Enrique Buenaventura'),
  ('Unidad Administrativa Especial Estudios Takeshima'),
  ('Unidad Administrativa Especial de Gestión de Bienes y Servicios'),
  ('Unidad Administrativa Especial de Protección Animal'),
  ('Unidad Administrativa Especial de Servicios Públicos Municipales')
on conflict (nombre) do nothing;


-- >>>>>>>>>>>>>>>>>>>> 03_historico.sql <<<<<<<<<<<<<<<<<<<<
-- =====================================================================
-- Histórico de requerimientos 2024-2026 (cargado desde los Excel de control)
-- Ejecutar después de 01_schema.sql. Luego importar historico_requerimientos.csv
-- desde Table Editor > historico_requerimientos > Insert > Import data from CSV.
-- =====================================================================

create table if not exists public.historico_requerimientos (
  id                     bigint generated always as identity primary key,
  vigencia               int  not null,
  radicacion_ente        text,
  ente                   text,
  orfeo_entrada          text,
  fecha_recibo           date,
  organismo              text not null,
  tipo_organismo         text,
  asunto                 text,
  termino_dias_habiles   int,
  fecha_maxima           date,
  orfeo_respuesta        text,
  fecha_respuesta        date,
  respondio              text check (respondio in ('Sí','No','No aplica')),
  tardia                 text check (tardia in ('Sí','No','No aplica')),
  oportunidad            text not null check (oportunidad in
                           ('A tiempo','Tardía','Sin respuesta (vencida)','Pendiente en término',
                            'Respondida (sin fecha para medir)','No requiere respuesta')),
  retraso_dias_habiles   int,
  dias_habiles_responder int,
  estado_excel           text,
  observaciones          text,
  fila_excel             int
);
create index if not exists idx_hist_org on public.historico_requerimientos (organismo, vigencia);

-- Nombre de la dependencia del usuario (debe coincidir con la columna organismo).
create or replace function public.current_dep_name()
returns text language sql stable security definer set search_path = public as $$
  select d.nombre from public.profiles p join public.dependencias d on d.id = p.dependencia_id
  where p.id = auth.uid() and p.activo
$$;
grant execute on function public.current_dep_name() to authenticated;

alter table public.historico_requerimientos enable row level security;
-- El Alcalde, el administrador y Control Interno ven todo; secretarios y enlaces solo su dependencia.
drop policy if exists hist_read on public.historico_requerimientos;
create policy hist_read on public.historico_requerimientos for select to authenticated
  using (
    public.current_rol() in ('admin','alcalde','control_interno')
    or (public.current_rol() in ('secretario','enlace') and organismo = public.current_dep_name())
  );
revoke all on public.historico_requerimientos from anon;
grant select on public.historico_requerimientos to authenticated;

-- Ranking de cumplimiento por organismo y vigencia.
-- Semáforo: verde < 20% de incumplimiento, rojo >= 40%, mínimo 10 casos evaluados.
create or replace view public.v_cumplimiento_organismo with (security_invoker = true) as
select
  organismo,
  vigencia,
  count(*) filter (where oportunidad = 'A tiempo')                                   as a_tiempo,
  count(*) filter (where oportunidad = 'Tardía')                                     as tardias,
  count(*) filter (where oportunidad = 'Sin respuesta (vencida)')                    as sin_respuesta,
  count(*) filter (where oportunidad in ('Tardía','Sin respuesta (vencida)'))        as incumplimientos,
  count(*) filter (where oportunidad in ('A tiempo','Tardía','Sin respuesta (vencida)')) as evaluables,
  round(100.0 * count(*) filter (where oportunidad in ('Tardía','Sin respuesta (vencida)'))
        / nullif(count(*) filter (where oportunidad in ('A tiempo','Tardía','Sin respuesta (vencida)')), 0), 1) as pct_incumplimiento,
  case
    when count(*) filter (where oportunidad in ('A tiempo','Tardía','Sin respuesta (vencida)')) < 10 then 'MUESTRA INSUFICIENTE'
    when 1.0 * count(*) filter (where oportunidad in ('Tardía','Sin respuesta (vencida)'))
         / count(*) filter (where oportunidad in ('A tiempo','Tardía','Sin respuesta (vencida)')) >= 0.40 then 'ROJO'
    when 1.0 * count(*) filter (where oportunidad in ('Tardía','Sin respuesta (vencida)'))
         / count(*) filter (where oportunidad in ('A tiempo','Tardía','Sin respuesta (vencida)')) < 0.20 then 'VERDE'
    else 'AMARILLO'
  end as semaforo
from public.historico_requerimientos
where tipo_organismo <> 'Otro'
group by organismo, vigencia;
grant select on public.v_cumplimiento_organismo to authenticated;


-- >>>>>>>>>>>>>>>>>>>> 04_directorio_notificaciones.sql <<<<<<<<<<<<<<<<<<<<
-- =====================================================================
-- Directorio del gabinete (solo secretarios y directores) y bitácora de notificaciones.
-- Ejecutar después de 03_historico.sql. Luego importar datos_privados/directorio_gabinete.csv
-- en la tabla directorio (Table Editor > Insert > Import data from CSV).
-- =====================================================================

create table if not exists public.directorio (
  id         bigint generated always as identity primary key,
  organismo  text not null,
  cargo      text not null,
  nombre     text not null default '',
  telefono   text not null default '' check (telefono = '' or telefono ~ '^57[0-9]{10}$'),
  updated_by uuid default auth.uid(),
  updated_at timestamptz not null default now(),
  unique (organismo, cargo)
);

create table if not exists public.notificaciones (
  id           bigint generated always as identity primary key,
  organismo    text not null,
  destinatario text not null default '',
  telefono     text not null default '',
  plantilla    text not null,
  n_items      int  not null default 0,
  canal        text not null default 'whatsapp' check (canal in ('whatsapp')),
  mensaje      text not null,
  enviado_por  uuid default auth.uid(),
  created_at   timestamptz not null default now()
);
create index if not exists idx_notif_org on public.notificaciones (organismo, created_at desc);

alter table public.directorio     enable row level security;
alter table public.notificaciones enable row level security;

-- Directorio: supervisión ve todo; secretarios y enlaces solo el de su dependencia; escribe admin y alcalde.
drop policy if exists dir_read on public.directorio;
create policy dir_read on public.directorio for select to authenticated using (
  public.current_rol() in ('admin','alcalde','control_interno')
  or (public.current_rol() in ('secretario','enlace') and organismo = public.current_dep_name()));
drop policy if exists dir_ins on public.directorio;
create policy dir_ins on public.directorio for insert to authenticated with check (public.current_rol() in ('admin','alcalde'));
drop policy if exists dir_upd on public.directorio;
create policy dir_upd on public.directorio for update to authenticated using (public.current_rol() in ('admin','alcalde')) with check (public.current_rol() in ('admin','alcalde'));

-- Notificaciones: la bitácora no se edita ni se borra.
drop policy if exists notif_read on public.notificaciones;
create policy notif_read on public.notificaciones for select to authenticated using (
  public.current_rol() in ('admin','alcalde','control_interno')
  or (public.current_rol() in ('secretario','enlace') and organismo = public.current_dep_name()));
drop policy if exists notif_ins on public.notificaciones;
create policy notif_ins on public.notificaciones for insert to authenticated with check (public.current_rol() in ('admin','alcalde','control_interno'));

revoke all on public.directorio, public.notificaciones from anon;
grant select, insert, update on public.directorio to authenticated;
grant select, insert on public.notificaciones to authenticated;

-- Trazabilidad en la cadena de auditoría SHA-256
drop trigger if exists trg_audit_dir on public.directorio;
create trigger trg_audit_dir after insert or update on public.directorio for each row execute function public.audit_trigger();
drop trigger if exists trg_audit_notif on public.notificaciones;
create trigger trg_audit_notif after insert on public.notificaciones for each row execute function public.audit_trigger();


-- >>>>>>>>>>>>>>>>>>>> 05_actividad_informes.sql <<<<<<<<<<<<<<<<<<<<
-- =====================================================================
-- Actividad del equipo e informes generados. Ejecutar después de 04_directorio_notificaciones.sql.
-- =====================================================================

-- Quién ingresó y cuándo (solo se inserta; no se edita).
create table if not exists public.accesos (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists idx_accesos_user on public.accesos (user_id, created_at desc);

-- Informes ejecutivos generados desde la aplicación (con la huella SHA-256 de los datos usados).
create table if not exists public.informes (
  id          bigint generated always as identity primary key,
  generado_por uuid not null default auth.uid(),
  alcance     text not null,                  -- 'Todas las dependencias' o el nombre de la dependencia
  vigencias   text not null,
  corte       date,
  n_registros int  not null default 0,
  huella      text not null,
  created_at  timestamptz not null default now()
);

alter table public.accesos  enable row level security;
alter table public.informes enable row level security;

drop policy if exists acc_ins on public.accesos;
create policy acc_ins on public.accesos for insert to authenticated with check (user_id = auth.uid() and public.current_rol() is not null);
drop policy if exists acc_read on public.accesos;
create policy acc_read on public.accesos for select to authenticated using (public.current_rol() in ('admin','alcalde','control_interno') or user_id = auth.uid());
drop policy if exists inf_ins on public.informes;
create policy inf_ins on public.informes for insert to authenticated with check (generado_por = auth.uid() and public.current_rol() is not null);
drop policy if exists inf_read on public.informes;
create policy inf_read on public.informes for select to authenticated using (public.current_rol() in ('admin','alcalde','control_interno') or generado_por = auth.uid());

-- El Alcalde también puede ver las cuentas (para el panel de actividad).
drop policy if exists profiles_read on public.profiles;
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.current_rol() in ('admin','alcalde','control_interno'));

revoke all on public.accesos, public.informes from anon;
grant select, insert on public.accesos, public.informes to authenticated;

drop trigger if exists trg_audit_informes on public.informes;
create trigger trg_audit_informes after insert on public.informes for each row execute function public.audit_trigger();


-- >>>>>>>>>>>>>>>>>>>> 06_directorio_validaciones.sql <<<<<<<<<<<<<<<<<<<<
-- =====================================================================
-- 06 · Directorio del gabinete sin errores para WhatsApp
-- Ejecutar después de 05_actividad_informes.sql.
--
-- Garantiza en el servidor (no solo en la app) que:
--   1. Cada responsable queda amarrado a una dependencia que existe, con el
--      nombre oficial exacto (corrige tildes, mayúsculas y espacios).
--   2. El nombre va completo (al menos nombres y apellidos) si hay celular.
--   3. El celular es colombiano (57 + 10 dígitos que inician en 3) y no se
--      repite entre dos responsables.
-- Además crea la vista v_directorio_verificacion para revisar cruces
-- entre dependencias, histórico y directorio antes de salir a producción.
-- =====================================================================

-- Llave normalizada: sin tildes, minúsculas, sin paréntesis ni signos.
create or replace function public.org_key(t text)
returns text language sql immutable as $$
  select trim(regexp_replace(regexp_replace(regexp_replace(
           translate(lower(coalesce(t,'')),'áéíóúüñàèìòù','aeiouunaeiou'),
         '\(.*?\)',' ','g'),'[^a-z0-9 ]',' ','g'),'\s+',' ','g'))
$$;

-- Nombre oficial de una dependencia a partir de cualquier variante escrita.
create or replace function public.org_oficial(t text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select h.organismo from public.historico_requerimientos h where public.org_key(h.organismo) = public.org_key(t) limit 1),
    (select d.nombre from public.dependencias d where public.org_key(d.nombre) = public.org_key(t) limit 1))
$$;

create or replace function public.directorio_validar()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_of text;
begin
  new.organismo := regexp_replace(trim(new.organismo),'\s+',' ','g');
  new.cargo     := regexp_replace(trim(new.cargo),'\s+',' ','g');
  new.nombre    := regexp_replace(trim(coalesce(new.nombre,'')),'\s+',' ','g');
  new.telefono  := regexp_replace(coalesce(new.telefono,''),'\D','','g');
  if new.telefono ~ '^3[0-9]{9}$' then new.telefono := '57' || new.telefono; end if;

  v_of := public.org_oficial(new.organismo);
  if v_of is null then
    raise exception 'La dependencia "%" no existe. Usa el nombre oficial de la lista de dependencias.', new.organismo;
  end if;
  new.organismo := v_of;

  if new.telefono <> '' and new.telefono !~ '^573[0-9]{9}$' then
    raise exception 'El celular debe tener 10 dígitos e iniciar en 3.';
  end if;
  if new.telefono <> '' and array_length(regexp_split_to_array(new.nombre,' '),1) < 2 then
    raise exception 'Escribe el nombre completo del responsable (nombres y apellidos).';
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_dir_validar on public.directorio;
create trigger trg_dir_validar before insert or update on public.directorio
  for each row execute function public.directorio_validar();

-- Un mismo celular no puede quedar en dos dependencias.
create unique index if not exists ux_directorio_telefono on public.directorio (telefono) where telefono <> '';

-- Normaliza lo que ya esté cargado (dispara el trigger sobre cada fila).
update public.directorio set organismo = organismo;

-- Vista de verificación: ejecutar  select * from public.v_directorio_verificacion;
-- Debe devolver cero filas antes de salir a producción.
create or replace view public.v_directorio_verificacion with (security_invoker = true) as
  select 'Dependencia sin responsable en el directorio' as problema, h.organismo as dependencia, null::text as detalle
    from (select distinct organismo from public.historico_requerimientos
          where tipo_organismo in ('Secretaría','Departamento','UAE','Despacho')) h
   where not exists (select 1 from public.directorio d where public.org_key(d.organismo) = public.org_key(h.organismo))
  union all
  select 'Responsable sin celular válido', d.organismo, d.cargo || ' · ' || coalesce(nullif(d.nombre,''),'sin nombre')
    from public.directorio d where d.telefono !~ '^573[0-9]{9}$'
  union all
  select 'Responsable sin nombre completo', d.organismo, d.cargo
    from public.directorio d where array_length(regexp_split_to_array(trim(d.nombre),'\s+'),1) < 2 or trim(d.nombre) = ''
  union all
  select 'Cuenta de secretario o enlace cuya dependencia no coincide con el histórico', dp.nombre, p.email
    from public.profiles p join public.dependencias dp on dp.id = p.dependencia_id
   where p.rol in ('secretario','enlace')
     and not exists (select 1 from public.historico_requerimientos h where h.organismo = dp.nombre);
revoke all on public.v_directorio_verificacion from anon;
grant select on public.v_directorio_verificacion to authenticated;

