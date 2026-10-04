// Bundles the main process, the preload script and the two pages into dist/.
import { build } from 'esbuild'
import fs from 'node:fs'

fs.mkdirSync('dist', { recursive: true })
const common = { bundle: true, sourcemap: 'inline', logLevel: 'warning', target: 'es2023' }
await Promise.all([
  build({ ...common, entryPoints: ['src/main/main.ts'], outfile: 'dist/main.js', platform: 'node', format: 'cjs', external: ['electron', 'uiohook-napi'] }),
  build({ ...common, entryPoints: ['src/main/preload.ts'], outfile: 'dist/preload.js', platform: 'node', format: 'cjs', external: ['electron'] }),
  build({ ...common, entryPoints: ['src/renderer/card.ts'], outfile: 'dist/card.js', platform: 'browser', format: 'iife' }),
  build({ ...common, entryPoints: ['src/renderer/settings.ts'], outfile: 'dist/settings.js', platform: 'browser', format: 'iife' }),
])
for (const file of ['card.html', 'card.css', 'settings.html', 'settings.css']) fs.copyFileSync(`src/renderer/${file}`, `dist/${file}`)
console.log('built dist/')
