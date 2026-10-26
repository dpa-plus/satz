const releaseBase = 'https://cdn.prozesshub.eu/assets/clients/dpa/downloads/satz/latest'
export const releaseManifestURL = `${releaseBase}/release.json`
const maximumManifestBytes = 16_384

interface Version { parts: bigint[]; prerelease: string[] }

function version(value: unknown): Version | null {
  if (typeof value !== 'string' || value.length > 128) return null
  const match = /^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/.exec(value)
  // `$` also matches before a final newline in JavaScript.
  if (!match || match[0] !== value) return null
  const prerelease = match[4]?.split('.') ?? []
  if (prerelease.some(part => /^\d+$/.test(part) && part.length > 1 && part[0] === '0')) return null
  return { parts: match.slice(1, 4).map(BigInt), prerelease }
}

export function isNewerVersion(candidate: unknown, installed: unknown): boolean {
  const next = version(candidate)
  const current = version(installed)
  if (!next || !current) return false
  for (let i = 0; i < 3; i++) if (next.parts[i] !== current.parts[i]) return next.parts[i] > current.parts[i]
  if (!next.prerelease.length || !current.prerelease.length) return !next.prerelease.length && !!current.prerelease.length
  for (let i = 0; i < Math.max(next.prerelease.length, current.prerelease.length); i++) {
    const a = next.prerelease[i]
    const b = current.prerelease[i]
    if (a === b) continue
    if (a === undefined || b === undefined) return b === undefined
    const numericA = /^\d+$/.test(a)
    const numericB = /^\d+$/.test(b)
    if (numericA !== numericB) return !numericA
    return numericA ? BigInt(a) > BigInt(b) : a > b
  }
  return false
}

export function releaseAsset(platform: string, arch: string, linuxPackage: 'deb' | 'tar.gz' = 'tar.gz'): string | null {
  if (arch !== 'arm64' && arch !== 'x64') return null
  if (platform === 'win32') return `satz-windows-${arch}.zip`
  if (platform === 'linux') return `satz-linux-${linuxPackage === 'deb' && arch === 'x64' ? 'amd64' : arch}.${linuxPackage}`
  return null
}

const knownAssets = new Set(['win32', 'linux'].flatMap(platform => ['x64', 'arm64'].flatMap(arch => ['deb', 'tar.gz'].map(kind => releaseAsset(platform, arch, kind as 'deb' | 'tar.gz')!))))
export interface Release { version: string; downloadURL: string }
export interface UpdateState {
  kind: 'idle' | 'available' | 'current' | 'unavailable'
  currentVersion: string
  version?: string
  checking: boolean
  manual: boolean
}

export function readReleaseManifest(value: unknown, asset: string, installed: string): Release | null {
  if (!knownAssets.has(asset) || !version(installed) || !value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid release manifest')
  const manifest = value as Record<string, unknown>
  if (!version(manifest.version) || !manifest.files || typeof manifest.files !== 'object' || Array.isArray(manifest.files)) throw new Error('Invalid release manifest')
  const size = (manifest.files as Record<string, unknown>)[asset]
  if (typeof size !== 'number' || !Number.isSafeInteger(size) || size <= 0) throw new Error('Release artifact unavailable')
  return isNewerVersion(manifest.version, installed) ? { version: (manifest.version as string).replace(/^v/, ''), downloadURL: `${releaseBase}/${asset}` } : null
}

export type UpdateFetch = (url: string, init?: RequestInit) => Promise<Response>

/** A stalled server or body cannot hold up a check, even if its fetch ignores cancellation. */
export async function fetchRelease(fetcher: UpdateFetch, asset: string, installed: string, timeout = 5_000): Promise<Release | null> {
  const controller = new AbortController()
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined
  let timer: ReturnType<typeof setTimeout>
  const deadline = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => { controller.abort(); void reader?.cancel().catch(() => {}); reject(new Error('Update check timed out')) }, timeout)
  })
  const read = async () => {
    const response = await fetcher(releaseManifestURL, { signal: controller.signal, redirect: 'error', credentials: 'omit', cache: 'no-store' })
    if (!response.ok || !response.body) throw new Error('Update check unavailable')
    const declared = Number(response.headers.get('content-length'))
    if (declared > maximumManifestBytes) { void response.body.cancel().catch(() => {}); throw new Error('Release manifest too large') }
    reader = response.body.getReader()
    const chunks: Uint8Array[] = []
    let length = 0
    try {
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        length += value.byteLength
        if (length > maximumManifestBytes) throw new Error('Release manifest too large')
        chunks.push(value)
      }
    } finally { void reader.cancel().catch(() => {}) }
    const body = new Uint8Array(length)
    let offset = 0
    for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength }
    return readReleaseManifest(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(body)), asset, installed)
  }
  try { return await Promise.race([read(), deadline]) }
  finally { clearTimeout(timer!); controller.abort() }
}
