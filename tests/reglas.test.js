// Pruebas de las reglas de negocio puras. Sin dependencias: `node tests/reglas.test.js`
// Extrae las funciones directamente de index.html para que el desarrollador valide su port al lenguaje nativo.
const fs = require('fs'), assert = require('assert'), path = require('path');
const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1];

function extract(name) {
  const re = new RegExp('(?:^|\\n)\\s*(?:async\\s+)?(?:function\\s+' + name + '\\b|const\\s+' + name + '\\s*=)');
  const m = re.exec(script); if (!m) throw new Error('No se encontró ' + name);
  let i = m.index; const start = script.indexOf(name, i) - (script.slice(i, script.indexOf(name, i)).includes('function') ? 'function '.length : 'const '.length);
  const from = script.lastIndexOf('\n', script.indexOf(name, i)) + 1;
  let j = script.indexOf(name, i) + name.length, depth = 0, seen = false;
  const arrow = script.slice(j, j + 60).match(/^\s*=\s*(?:\([^)]*\)|\w+)\s*=>\s*(\{)?/);
  if (arrow && !arrow[1]) return script.slice(from, script.indexOf('\n', j));
  for (; j < script.length; j++) { const ch = script[j]; if (ch === '{') { depth++; seen = true; } else if (ch === '}') { depth--; if (seen && depth === 0) { j++; break; } } }
  if (script[j] === ';') j++;
  return script.slice(from, j);
}
const names = ['SEMP', 'semOf', 'statsOf', 'normPhone', 'fmtPhone', 'maskPII', 'shortTxt', 'squarify', 'pct1'];
const sandbox = names.map(extract).join('\n') + '\nreturn {SEMP, semOf, statsOf, normPhone, fmtPhone, maskPII, shortTxt, squarify, pct1};';
const R = new Function(sandbox)();

// --- semáforo
assert.strictEqual(R.semOf(5, 0.9), 'muestra');
assert.strictEqual(R.semOf(20, 0.19), 'verde');
assert.strictEqual(R.semOf(20, 0.20), 'amarillo');
assert.strictEqual(R.semOf(20, 0.399), 'amarillo');
assert.strictEqual(R.semOf(20, 0.40), 'rojo');

// --- estadísticas (opo: 0 a tiempo, 1 tardía, 2 sin respuesta, 3 pendiente)
const s = R.statsOf([{opo:0},{opo:0},{opo:1,ret:4},{opo:1,ret:6},{opo:2,ret:30},{opo:3},{opo:5}]);
assert.deepStrictEqual([s.ok, s.tar, s.sin, s.pend, s.ev, s.inc], [2, 2, 1, 1, 5, 3]);
assert.strictEqual(s.ret, 5);                 // retraso promedio de las tardías
assert.strictEqual(s.tasa, 3 / 5);
assert.strictEqual(s.sem, 'muestra');         // menos de 10 evaluados

// --- celulares
assert.strictEqual(R.normPhone('315 4297258'), '573154297258');
assert.strictEqual(R.normPhone('315-4297258'), '573154297258');
assert.strictEqual(R.normPhone('+57 310 487 0428'), '573104870428');
assert.strictEqual(R.normPhone('6024184242'), '');
assert.strictEqual(R.normPhone('12345'), '');
assert.strictEqual(R.fmtPhone('573104870428'), '+57 310 487 0428');

// --- datos personales
assert.ok(R.maskPII('Acción defensorial en favor de LINA MARIA TROCHEZ ESPINAL.').includes('[nombre reservado]'));
assert.ok(!R.maskPII('Acción defensorial en favor de LINA MARIA TROCHEZ ESPINAL.').includes('TROCHEZ'));
assert.ok(!R.maskPII('ESTUDIANTES JOSUE DAVID COLMENARES con PPT. 5329397').includes('5329397'));
assert.strictEqual(R.maskPII('Auditoría de recursos PAE e infraestructura educativa.'), 'Auditoría de recursos PAE e infraestructura educativa.');
assert.strictEqual(R.shortTxt('uno dos tres cuatro cinco', 12), 'uno dos...');

// --- treemap: las áreas suman el rectángulo y no se salen de él
const items = [{v:50},{v:30},{v:12},{v:8}], W = 800, H = 400;
const tiles = R.squarify(items, 0, 0, W, H);
assert.ok(Math.abs(tiles.reduce((a, t) => a + t.w * t.h, 0) - W * H) < 1);
tiles.forEach(t => assert.ok(t.x >= -0.01 && t.y >= -0.01 && t.x + t.w <= W + 0.01 && t.y + t.h <= H + 0.01));

console.log('OK: reglas de negocio verificadas');

// --- directorio: emparejamiento dependencia <-> responsable y nombre completo
{
  const D = new Function(['orgKey','fullName'].map(extract).join('\n') + '\nreturn {orgKey, fullName};')();
  assert.strictEqual(D.orgKey('  SECRETARIA   de educacion '), D.orgKey('Secretaría de Educación'));
  assert.strictEqual(D.orgKey('Departamento Administrativo de Gestión del Medio Ambiente (DAGMA)'), D.orgKey('Departamento Administrativo de Gestion del Medio Ambiente'));
  assert.notStrictEqual(D.orgKey('Secretaría de Salud Pública'), D.orgKey('Secretaría de Educación'));
  assert.strictEqual(D.fullName('Ana María Pérez'), true);
  assert.strictEqual(D.fullName('Ana'), false);
  assert.strictEqual(D.fullName('  '), false);
  console.log('OK: directorio verificado');
}
