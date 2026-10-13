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
