// Setzt film/index.html aus film/src/* zusammen und bettet zwei Dinge aus der fertigen Tonspur ein:
//   - die Wortzeiten (_build/timeline.json), an denen jede Bewegung hängt,
//   - den Pegel der Stimme (_build/mix/stems/stimme.wav), der die Wellenformen der satz-Karte treibt.
//   node werkzeug/baue-film.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const P = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const F = path.join(P, 'film');
const src = (n) => fs.readFileSync(path.join(F, 'src', n), 'utf8');

const tl = JSON.parse(fs.readFileSync(path.join(P, '_build', 'timeline.json'), 'utf8'));
if (tl.geschaetzt) console.warn('Achtung: Timeline ist nur geschätzt (keine fertige Sprecherspur).');
const lines = {};
for (const l of tl.lines) lines[l.id] = { start: +l.start.toFixed(3), end: +l.end.toFixed(3), words: l.words.map((w) => [w[0], +w[1].toFixed(3), +w[2].toFixed(3)]) };
const dauer = +tl.duration.toFixed(3);

// Pegel der Stimme: RMS in Fenstern von 1/RATE s, als dB auf 0..1 abgebildet, wie die Karte es zeigt.
const RATE = 12;
function pegel(datei) {
  const b = fs.readFileSync(datei);
  let o = 12, fmt = null, data = null;
  while (o + 8 <= b.length) {
    const id = b.toString('ascii', o, o + 4), n = b.readUInt32LE(o + 4);
    if (id === 'fmt ') fmt = { kanaele: b.readUInt16LE(o + 10), rate: b.readUInt32LE(o + 12), bits: b.readUInt16LE(o + 22) };
    if (id === 'data') data = b.subarray(o + 8, o + 8 + n);
    o += 8 + n + (n % 2);
  }
  if (!fmt || !data || fmt.bits !== 16) throw new Error('stimme.wav: nur PCM 16 bit');
  const proFenster = Math.round(fmt.rate / RATE), schritt = 2 * fmt.kanaele, n = Math.floor(data.length / schritt);
  const out = [];
  for (let s = 0; s < n; s += proFenster) {
    let sum = 0, k = 0;
    for (let i = s; i < Math.min(n, s + proFenster); i++, k++) {
      const v = data.readInt16LE(i * schritt) / 32768;
      sum += v * v;
    }
    const db = 20 * Math.log10(Math.sqrt(sum / Math.max(1, k)) + 1e-9);
    out.push(+Math.max(0, Math.min(1, (db + 34) / 18)).toFixed(3));
  }
  return out;
}
const L = pegel(path.join(P, '_build', 'mix', 'stems', 'stimme.wav'));

const VO = { duration: dauer, lines, level: { rate: RATE, values: L } };

// Schriften: Bitter und Source Sans 3 als variable Schriften, Plex Mono in zwei Schnitten.
const fontCss = [
  `@font-face { font-family: 'Bitter'; src: url('assets/fonts/bitter-var.woff2') format('woff2'); font-weight: 100 900; font-style: normal; font-display: block; }`,
  `@font-face { font-family: 'Source Sans 3'; src: url('assets/fonts/sourcesans3-var.woff2') format('woff2'); font-weight: 200 900; font-style: normal; font-display: block; }`,
  `@font-face { font-family: 'IBM Plex Mono'; src: url('assets/fonts/plexmono-400.woff2') format('woff2'); font-weight: 400; font-style: normal; font-display: block; }`,
  `@font-face { font-family: 'IBM Plex Mono'; src: url('assets/fonts/plexmono-500.woff2') format('woff2'); font-weight: 500; font-style: normal; font-display: block; }`,
].join('\n');

// Icons aus film/assets/icons/ (CDN, Herkunft in assets/quellen.json) als <symbol> einbetten:
// so sind sie ab Bild 0 da, ohne Ladezeit. Markenzeichen behalten ihre Farben (fill steht in der Datei),
// die neutralen Lucide-Symbole zeichnen mit currentColor und nehmen die Farbe des Textes daneben.
const ICONS = ['mail', 'notizen', 'code-editor', 'ki-chat', 'lokal', 'slack', 'apple', 'windows', 'linux'];
function symbol(name) {
  const s = fs.readFileSync(path.join(F, 'assets', 'icons', name + '.svg'), 'utf8').replace(/<!--[\s\S]*?-->/g, '');
  const m = s.match(/<svg([^>]*)>([\s\S]*)<\/svg>/);
  if (!m) throw new Error('Icon ohne <svg>: ' + name);
  const vb = m[1].match(/viewBox="([^"]+)"/);
  if (!vb) throw new Error('Icon ohne viewBox: ' + name);
  const attr = (a) => {
    const r = m[1].match(new RegExp('\\s' + a + '="([^"]+)"'));
    return r ? ` ${a}="${r[1]}"` : '';
  };
  const g = ['fill', 'stroke', 'stroke-width', 'stroke-linecap', 'stroke-linejoin'].map(attr).join('');
  const inner = m[2].replace(/<title>[\s\S]*?<\/title>/g, '').replace(/\s+/g, ' ').trim();
  return `<symbol id="ic-${name}" viewBox="${vb[1]}"><g${g}>${inner}</g></symbol>`;
}
const body = src('body.html');
if (!body.includes('<!--ICONS-->')) throw new Error('body.html: Platzhalter <!--ICONS--> fehlt');
const bodyMitIcons = body.replace('<!--ICONS-->', ICONS.map(symbol).join('\n    '));

const html = `<!doctype html>
<html lang="de">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=1920, height=1080" />
    <title>satz · Sprechen statt tippen</title>
    <script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
    <style>
${fontCss}
${src('style.css')}
    </style>
  </head>
  <body>
    <div id="root" data-composition-id="main" data-start="0" data-duration="${dauer}" data-width="1920" data-height="1080">
${bodyMitIcons}
    </div>
    <script>
      const VO = ${JSON.stringify(VO)};
${src('szenen.js')}
    </script>
  </body>
</html>
`;
fs.writeFileSync(path.join(F, 'index.html'), html);
const laut = L.filter((v) => v > 0.5).length / L.length;
console.log(`index.html geschrieben · Dauer ${dauer} s · ${tl.lines.length} Zeilen · Pegel ${L.length} Werte (${Math.round(laut * 100)} % über 0,5)`);
