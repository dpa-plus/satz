// Bundles the main process, the preload script and the pages into dist/.
import { build } from 'esbuild'
import fs from 'node:fs'

// From scratch, so pages that were renamed do not linger in the package.
fs.rmSync('dist', { recursive: true, force: true })
fs.mkdirSync('dist', { recursive: true })
const common = { bundle: true, sourcemap: 'inline', logLevel: 'warning', target: 'es2023' }
await Promise.all([
  // transformers.js goes into main.js; ONNX Runtime stays a package, for its native code.
  build({ ...common, entryPoints: ['src/main/main.ts'], outfile: 'dist/main.js', platform: 'node', format: 'cjs',
    external: ['electron', 'uiohook-napi', 'onnxruntime-node', 'onnxruntime-common'], alias: { sharp: './src/main/no-sharp.ts' } }),
  build({ ...common, entryPoints: ['src/main/preload.ts'], outfile: 'dist/preload.js', platform: 'node', format: 'cjs', external: ['electron'] }),
  build({ ...common, entryPoints: ['src/renderer/card.ts'], outfile: 'dist/card.js', platform: 'browser', format: 'iife' }),
  build({ ...common, entryPoints: ['src/renderer/settings.ts'], outfile: 'dist/settings.js', platform: 'browser', format: 'iife' }),
  build({ ...common, entryPoints: ['src/renderer/history.ts'], outfile: 'dist/history.js', platform: 'browser', format: 'iife' }),
  build({ ...common, entryPoints: ['src/renderer/window.ts'], outfile: 'dist/window.js', platform: 'browser', format: 'iife' }),
])
for (const file of ['card.html', 'card.css', 'window.html', 'settings.css', 'history.css', 'window.css']) fs.copyFileSync(`src/renderer/${file}`, `dist/${file}`)
// The window's pages in a plain browser, with a stand-in for the app.
if (process.argv.includes('--preview')) await build({ ...common, entryPoints: ['preview/mock.ts'], outfile: 'preview/mock.js', platform: 'browser', format: 'iife' })
console.log('built dist/')
