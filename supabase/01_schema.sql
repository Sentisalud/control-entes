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
create policy config_read  on public.config        for select to authenticated using (public.current_rol() is not null);
create policy config_write on public.config        for update to authenticated using (public.current_rol() = 'admin') with check (public.current_rol() = 'admin');
create policy entes_read   on public.entes         for select to authenticated using (public.current_rol() is not null);
create policy entes_ins    on public.entes         for insert to authenticated with check (public.current_rol() = 'admin');
create policy entes_upd    on public.entes         for update to authenticated using (public.current_rol() = 'admin') with check (public.current_rol() = 'admin');
create policy deps_read    on public.dependencias  for select to authenticated using (public.current_rol() is not null);
create policy deps_ins     on public.dependencias  for insert to authenticated with check (public.current_rol() = 'admin');
create policy deps_upd     on public.dependencias  for update to authenticated using (public.current_rol() = 'admin') with check (public.current_rol() = 'admin');

-- Perfiles: cada quien ve el suyo; admin y control interno ven todos; solo admin modifica
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.current_rol() in ('admin','control_interno'));
create policy profiles_upd  on public.profiles for update to authenticated
  using (public.current_rol() = 'admin') with check (public.current_rol() = 'admin');

-- Requerimientos: secretario/enlace solo ven su dependencia. Nadie borra. El cierre es vía cerrar_requerimiento().
create policy req_read on public.requerimientos for select to authenticated using (
  public.current_rol() in ('admin','alcalde','control_interno')
  or (public.current_rol() in ('secretario','enlace') and dependencia_id = public.current_dep())
);
create policy req_ins on public.requerimientos for insert to authenticated with check (
  public.current_rol() = 'admin'
  or (public.current_rol() = 'enlace' and dependencia_id = public.current_dep())
);
create policy req_upd on public.requerimientos for update to authenticated
  using (public.current_rol() = 'admin') with check (public.current_rol() = 'admin');

-- Alertas y auditoría: solo lectura para roles de supervisión
create policy alertas_read on public.alertas_log for select to authenticated
  using (public.current_rol() in ('admin','alcalde','control_interno'));
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

create policy soportes_read on storage.objects for select to authenticated
  using (bucket_id = 'soportes' and public.current_rol() is not null);
create policy soportes_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'soportes' and public.current_rol() in ('admin','secretario','enlace'));
