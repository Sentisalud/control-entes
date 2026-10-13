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

create policy acc_ins on public.accesos for insert to authenticated with check (user_id = auth.uid() and public.current_rol() is not null);
create policy acc_read on public.accesos for select to authenticated using (public.current_rol() in ('admin','alcalde','control_interno') or user_id = auth.uid());
create policy inf_ins on public.informes for insert to authenticated with check (generado_por = auth.uid() and public.current_rol() is not null);
create policy inf_read on public.informes for select to authenticated using (public.current_rol() in ('admin','alcalde','control_interno') or generado_por = auth.uid());

-- El Alcalde también puede ver las cuentas (para el panel de actividad).
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.current_rol() in ('admin','alcalde','control_interno'));

revoke all on public.accesos, public.informes from anon;
grant select, insert on public.accesos, public.informes to authenticated;

drop trigger if exists trg_audit_informes on public.informes;
create trigger trg_audit_informes after insert on public.informes for each row execute function public.audit_trigger();
