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
create policy dir_read on public.directorio for select to authenticated using (
  public.current_rol() in ('admin','alcalde','control_interno')
  or (public.current_rol() in ('secretario','enlace') and organismo = public.current_dep_name()));
create policy dir_ins on public.directorio for insert to authenticated with check (public.current_rol() in ('admin','alcalde'));
create policy dir_upd on public.directorio for update to authenticated using (public.current_rol() in ('admin','alcalde')) with check (public.current_rol() in ('admin','alcalde'));

-- Notificaciones: la bitácora no se edita ni se borra.
create policy notif_read on public.notificaciones for select to authenticated using (
  public.current_rol() in ('admin','alcalde','control_interno')
  or (public.current_rol() in ('secretario','enlace') and organismo = public.current_dep_name()));
create policy notif_ins on public.notificaciones for insert to authenticated with check (public.current_rol() in ('admin','alcalde','control_interno'));

revoke all on public.directorio, public.notificaciones from anon;
grant select, insert, update on public.directorio to authenticated;
grant select, insert on public.notificaciones to authenticated;

-- Trazabilidad en la cadena de auditoría SHA-256
drop trigger if exists trg_audit_dir on public.directorio;
create trigger trg_audit_dir after insert or update on public.directorio for each row execute function public.audit_trigger();
drop trigger if exists trg_audit_notif on public.notificaciones;
create trigger trg_audit_notif after insert on public.notificaciones for each row execute function public.audit_trigger();
