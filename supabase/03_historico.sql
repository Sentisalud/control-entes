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
