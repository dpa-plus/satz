import assert from 'node:assert/strict'
import test from 'node:test'
import { isNewerVersion, releaseAsset, readReleaseManifest, fetchRelease, releaseManifestURL } from '../src/core/updates'
import { Updates } from '../src/main/updates'

const asset = 'satz-windows-x64.zip'
const manifest = (version = 'v0.4.6', files: Record<string, unknown> = { [asset]: 123 }) => JSON.stringify({ version, files })
const response = (body = manifest()) => new Response(body, { headers: { 'content-type': 'application/json' } })

test('versions compare numerically and ignore the release prefix and build metadata', () => {
  assert.equal(isNewerVersion('v0.4.10', '0.4.9'), true)
  assert.equal(isNewerVersion('1.0.0', '0.99.99'), true)
  assert.equal(isNewerVersion('0.4.5+new', 'v0.4.5+old'), false)
  assert.equal(isNewerVersion('0.4.4', '0.4.5'), false)
  assert.equal(isNewerVersion('0.4.5', '0.4.5'), false)
})

test('prereleases follow SemVer precedence and never replace the same stable version', () => {
  const ordered = ['1.0.0-alpha', '1.0.0-alpha.1', '1.0.0-alpha.beta', '1.0.0-beta', '1.0.0-beta.2', '1.0.0-beta.11', '1.0.0-rc.1', '1.0.0']
  for (let i = 1; i < ordered.length; i++) assert.equal(isNewerVersion(ordered[i], ordered[i - 1]), true)
  assert.equal(isNewerVersion('1.0.0-rc.1', '1.0.0'), false)
  assert.equal(isNewerVersion('1.1.0-beta', '1.0.0'), true)
})

test('malformed or ambiguous versions never trigger an update', () => {
  for (const invalid of ['0.4', '01.4.5', '0.04.5', '0.4.05', '0.4.6-01', '0.4.6-', '0.4.6+', '0.4.6..1', 'v 0.4.6', '0.4.6\n', '0.4.6/evil', '', '9'.repeat(129)]) {
    assert.equal(isNewerVersion(invalid, '0.4.5'), false, invalid)
    assert.equal(isNewerVersion('0.4.6', invalid), false, invalid)
  }
})

test('only supported platform artifacts are selected, with Debian and archive names distinguished', () => {
  assert.equal(releaseAsset('win32', 'x64'), 'satz-windows-x64.zip')
  assert.equal(releaseAsset('win32', 'arm64'), 'satz-windows-arm64.zip')
  assert.equal(releaseAsset('linux', 'x64', 'deb'), 'satz-linux-amd64.deb')
  assert.equal(releaseAsset('linux', 'arm64', 'deb'), 'satz-linux-arm64.deb')
  assert.equal(releaseAsset('linux', 'x64', 'tar.gz'), 'satz-linux-x64.tar.gz')
  assert.equal(releaseAsset('linux', 'arm64', 'tar.gz'), 'satz-linux-arm64.tar.gz')
  assert.equal(releaseAsset('win32', 'ia32'), null)
  assert.equal(releaseAsset('darwin', 'arm64'), null)
})

test('the manifest only supplies a version and known asset existence, never the download address', () => {
  const value = JSON.parse(manifest())
  value.url = 'https://evil.invalid/payload'
  const result = readReleaseManifest(value, asset, '0.4.5')
  assert.deepEqual(result, { version: '0.4.6', downloadURL: 'https://cdn.prozesshub.eu/assets/clients/dpa/downloads/satz/latest/satz-windows-x64.zip' })
  assert.equal(readReleaseManifest(JSON.parse(manifest('v0.4.5')), asset, '0.4.5'), null)
  assert.equal(readReleaseManifest(JSON.parse(manifest('v0.4.4')), asset, '0.4.5'), null)
})

test('a missing artifact or malformed manifest is rejected', () => {
  for (const value of [null, [], {}, { version: 'v0.4.6' }, { version: 'latest', files: { [asset]: 1 } }, { version: 'v0.4.6', files: {} },
    ...[0, -1, '123', null, 1.5, Number.MAX_SAFE_INTEGER + 1].map(size => ({ version: 'v0.4.6', files: { [asset]: size } }))]) {
    assert.throws(() => readReleaseManifest(value, asset, '0.4.5'))
  }
  assert.throws(() => readReleaseManifest(JSON.parse(manifest()), '../payload', '0.4.5'))
})

test('fetch uses only the canonical manifest and refuses redirects', async () => {
  let requested: unknown[] = []
  const result = await fetchRelease(async (...args) => { requested = args; return response() }, asset, '0.4.5')
  assert.equal(requested[0], releaseManifestURL)
  assert.equal((requested[1] as RequestInit).redirect, 'error')
  assert.equal((requested[1] as RequestInit).credentials, 'omit')
  assert.equal(result?.version, '0.4.6')
})

test('HTTP errors, malformed JSON, empty responses and oversized declared bodies fail closed', async () => {
  for (const value of [new Response('no', { status: 503 }), new Response('no', { status: 302 }), response('{broken'), response(''),
    new Response(manifest(), { headers: { 'content-length': '1000000' } })]) {
    await assert.rejects(fetchRelease(async () => value, asset, '0.4.5'))
  }
})

test('a streamed response without Content-Length is capped and cancelled', async () => {
  let cancelled = false
  const body = new ReadableStream<Uint8Array>({
    start(controller) { controller.enqueue(new Uint8Array(16_385)) },
    cancel() { cancelled = true },
  })
  await assert.rejects(fetchRelease(async () => new Response(body), asset, '0.4.5'))
  assert.equal(cancelled, true)
})

test('the timeout covers a stalled connection and a stalled response body', async () => {
  let signal: AbortSignal | undefined
  await assert.rejects(fetchRelease(async (_url, init) => { signal = init?.signal as AbortSignal; return new Promise<Response>(() => {}) }, asset, '0.4.5', 10))
  assert.equal(signal?.aborted, true)
  await assert.rejects(fetchRelease(async () => new Response(new ReadableStream()), asset, '0.4.5', 10))
})

test('opening the window coalesces pending work and reuses a recent result', async () => {
  let calls = 0
  let resolve!: (value: Response) => void
  let now = 0
  const updates = new Updates('0.4.5', asset, async () => { calls++; return new Promise<Response>(done => { resolve = done }) }, () => {}, () => now)
  const first = updates.open()
  const second = updates.open()
  assert.equal(calls, 1)
  resolve(response())
  await Promise.all([first, second])
  assert.equal(updates.state.kind, 'available')
  assert.equal(updates.state.version, '0.4.6')
  await updates.open()
  assert.equal(calls, 1)
  now = 31 * 60_000
  const later = updates.open()
  assert.equal(calls, 2)
  resolve(response())
  await later
})

test('manual checks bypass cache and offline checks preserve an already known update', async () => {
  let offline = false
  let calls = 0
  const updates = new Updates('0.4.5', asset, async () => { calls++; if (offline) throw new Error('offline'); return response() })
  await updates.open()
  offline = true
  await updates.check(true)
  assert.equal(calls, 2)
  assert.equal(updates.state.kind, 'available')
  assert.equal(updates.state.manual, true)
  assert.equal(updates.downloadURL, 'https://cdn.prozesshub.eu/assets/clients/dpa/downloads/satz/latest/satz-windows-x64.zip')
  await updates.open()
  assert.equal(updates.state.manual, false)
})

test('offline startup stays silent, while a manual check can report failure and retry', async () => {
  let offline = true
  const updates = new Updates('0.4.5', asset, async () => { if (offline) throw new Error('offline'); return response(manifest('v0.4.5')) })
  await updates.open()
  assert.equal(updates.state.kind, 'unavailable')
  assert.equal(updates.state.manual, false)
  assert.equal(updates.downloadURL, null)
  offline = false
  await updates.check(true)
  assert.equal(updates.state.kind, 'current')
  assert.equal(updates.state.manual, true)
  assert.equal(updates.state.checking, false)
})

test('an unsupported platform never sends a network request', async () => {
  let calls = 0
  const updates = new Updates('0.4.5', null, async () => { calls++; return response() })
  await updates.open()
  assert.equal(calls, 0)
  assert.equal(updates.downloadURL, null)
})
