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
