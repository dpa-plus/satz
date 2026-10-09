import type { Language } from './language'

/**
 * sherpa-onnx (k2-fsa, Apache-2.0), satz's second engine on this computer:
 * NVIDIA's Parakeet and Canary, Moonshine and SenseVoice, Handy's models.
 * Each is a few single files in one of csukuangfj's Hugging Face repos,
 * fetched one by one (src/main/sherpaEngine.ts); this says which files, what
 * each one is to sherpa-onnx, and how its recognizer is set up.
 */

/** Which of sherpa-onnx's offline recognizers runs the model. */
export type SherpaKind = 'nemo-transducer' | 'canary' | 'moonshine' | 'sense-voice'

/** What a file is to the recognizer: the field of its model config it goes into. */
export type SherpaRole = 'encoder' | 'decoder' | 'joiner' | 'preprocessor' | 'uncachedDecoder' | 'cachedDecoder' | 'model' | 'tokens'

export interface SherpaFile {
  name: string
  role: SherpaRole
  /** From the repo's file list: a download is complete only at exactly this size. */
  bytes: number
  /** SHA-256 of the file (Hugging Face's LFS id, or computed for the small text files). */
  sha256: string
}

export interface SherpaSource {
  kind: SherpaKind
  /** csukuangfj/<repo> on Hugging Face. */
  repo: string
  /** The commit the files are fetched from: a file changed on main would fail its checksum and every download with it. */
  revision: string
  files: SherpaFile[]
  /**
   * Split at quiet moments into pieces of at most 30 s (core/windows.ts), as
   * Whisper is: Moonshine, SenseVoice and Canary were made for short clips.
   * Parakeet takes a whole dictation.
   */
  windowed: boolean
}

const parts: Record<SherpaKind, { field: string; roles: SherpaRole[] }> = {
  'nemo-transducer': { field: 'transducer', roles: ['encoder', 'decoder', 'joiner'] },
  canary: { field: 'canary', roles: ['encoder', 'decoder'] },
  moonshine: { field: 'moonshine', roles: ['preprocessor', 'encoder', 'uncachedDecoder', 'cachedDecoder'] },
  'sense-voice': { field: 'senseVoice', roles: ['model'] },
}

/** Where a file is downloaded from. */
export const sherpaURL = (source: SherpaSource, file: string) =>
  `https://huggingface.co/csukuangfj/${source.repo}/resolve/${source.revision}/${file}`

/** The files each kind needs, in a fixed order: what a complete download has. */
export function sherpaRoles(kind: SherpaKind): SherpaRole[] {
  return [...parts[kind].roles, 'tokens']
}

/**
 * The recognizer's config, as sherpa-onnx-node's createOfflineRecognizer
 * takes it. `file` gives a file's full path. Canary is told the language
 * (`spoken`, the one set under "Gesprochen auf"): it cannot tell by itself.
 * SenseVoice finds the language itself and writes numbers as digits.
 * Greedy search: the best of one, as satz's Whisper decodes.
 */
export function sherpaConfig(source: SherpaSource, file: (name: string) => string, spoken: Language, threads: number) {
  const path = (role: SherpaRole) => {
    const found = source.files.find(entry => entry.role === role)
    if (!found) throw new Error(`${source.repo} has no ${role}`)
    return file(found.name)
  }
  const { field, roles } = parts[source.kind]
  const model: Record<string, string | number> = Object.fromEntries(roles.map(role => [role, path(role)]))
  if (source.kind === 'canary') Object.assign(model, { srcLang: spoken, tgtLang: spoken, usePnc: 1 })
  if (source.kind === 'sense-voice') Object.assign(model, { language: '', useInverseTextNormalization: 1 })
  const modelConfig: Record<string, unknown> = { [field]: model, tokens: path('tokens'), numThreads: threads, provider: 'cpu', debug: 0 }
  if (source.kind === 'nemo-transducer') modelConfig.modelType = 'nemo_transducer'
  return {
    // Parakeet wants 128 mel bins; sherpa-onnx reads that from the model itself.
    featConfig: { sampleRate: 16_000, featureDim: 80 },
    modelConfig,
    decodingMethod: 'greedy_search',
  }
}

export type SherpaConfig = ReturnType<typeof sherpaConfig>

/**
 * The systems sherpa-onnx-node has a build for, as satz ships them: there is
 * none for Windows on ARM, so its models are not offered there at all.
 */
export const runsSherpa = (platform: string, arch: string) =>
  ['linux-x64', 'linux-arm64', 'win32-x64', 'darwin-arm64', 'darwin-x64'].includes(`${platform}-${arch}`)

/** The npm package with sherpa-onnx's native code for a system ("sherpa-onnx-win-x64"). */
export const sherpaPackage = (platform: string, arch: string) => `sherpa-onnx-${platform === 'win32' ? 'win' : platform}-${arch}`

/**
 * Tidies what a recognizer returns, without changing a word: Canary's
 * German came back with a space before each comma and full stop
 * ("Freitag , dann").
 */
export function tidySherpaText(text: string): string {
  return text.replace(/\s+([.,!?;:])/g, '$1').replace(/\s+/g, ' ').trim()
}
