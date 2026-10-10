import type { Language } from './language'

/**
 * sherpa-onnx (k2-fsa, Apache-2.0), satz's second engine on this computer:
 * NVIDIA's Parakeet and Canary, Moonshine and SenseVoice, Cohere Transcribe
 * and Qwen3-ASR. Each is a few single files in a Hugging Face repo (csukuangfj's
 * for Handy's models, other owners' for the newer ones), fetched one by one
 * (src/main/sherpaEngine.ts); this says which files, what each one is to
 * sherpa-onnx, and how its recognizer is set up.
 */

/** Which of sherpa-onnx's offline recognizers runs the model. */
export type SherpaKind = 'nemo-transducer' | 'canary' | 'moonshine' | 'sense-voice' | 'cohere-transcribe' | 'qwen3-asr'

/**
 * What a file is to the recognizer: the field of its model config it goes
 * into. 'tokenizer' is Qwen3-ASR's folder of three files, whose config field
 * is the folder; 'data' is the weights an encoder keeps beside it, which are
 * in no field but must lie next to it under exactly that name.
 */
export type SherpaRole = 'encoder' | 'decoder' | 'joiner' | 'preprocessor' | 'uncachedDecoder' | 'cachedDecoder' | 'model' | 'tokens' | 'convFrontend' | 'tokenizer' | 'data'

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
  /** Whose repo on Hugging Face: csukuangfj for Handy's models, csukuangfj2 for sherpa-onnx's newer ones, community exports under their makers' names. */
  owner: string
  /** <owner>/<repo> on Hugging Face. */
  repo: string
  /** The commit the files are fetched from: a file changed on main would fail its checksum and every download with it. */
  revision: string
  files: SherpaFile[]
  /**
   * The longest piece, in seconds, a recording goes through the model in; a
   * longer one is split at quiet moments (core/windows.ts), as Whisper's is.
   * Moonshine, SenseVoice and Canary were made for short clips and lose words
   * past 30 s. Parakeet takes minutes, but its encoder holds 5000 frames, 400 s
   * of audio: one second more and ONNX Runtime refuses the whole call (on the
   * Mac it aborts the app). 240 s leaves room, and a dictation under four
   * minutes is still one piece.
   */
  window: number
}

/**
 * Whether each piece gets a second of silence after it. Canary dropped the
 * last word of a piece cut right after it ("ohne Gutschriften" came back as
 * "Ohne"), and with the second it kept it every time. Not Parakeet: after a
 * word cut off mid-way, silence made it write nothing at all.
 */
export const padsEnd = (kind: SherpaKind) => kind === 'canary'

/**
 * Whether a model writes sentences for steady noise (a fan, hiss): Cohere
 * Transcribe did, "Ich bin jetzt nicht mehr so gut" over and over for 12 s of
 * it, and Qwen3-ASR wrote "提纲：" for loud hiss on the Mac, where Parakeet and
 * Canary wrote nothing. Their pieces get one more check before they are sent
 * (speech.ts, isSteady), the same on the Mac.
 */
export const makesUpTextForNoise = (kind: SherpaKind) => kind === 'cohere-transcribe' || kind === 'qwen3-asr'

/** The config field each kind's parts go into, and which roles are parts of it; `files` are the roles a download holds beyond them. */
const parts: Record<SherpaKind, { field: string; roles: SherpaRole[]; files?: SherpaRole[] }> = {
  'nemo-transducer': { field: 'transducer', roles: ['encoder', 'decoder', 'joiner'] },
  canary: { field: 'canary', roles: ['encoder', 'decoder'] },
  moonshine: { field: 'moonshine', roles: ['preprocessor', 'encoder', 'uncachedDecoder', 'cachedDecoder'] },
  'sense-voice': { field: 'senseVoice', roles: ['model'] },
  // The encoder's weights are a second file, 2.7 GB, named in the encoder.
  'cohere-transcribe': { field: 'cohereTranscribe', roles: ['encoder', 'decoder'], files: ['data'] },
  // No tokens.txt: its tokenizer is the folder.
  'qwen3-asr': { field: 'qwen3Asr', roles: ['convFrontend', 'encoder', 'decoder', 'tokenizer'] },
}

/** Where a file is downloaded from. */
export const sherpaURL = (source: SherpaSource, file: string) =>
  `https://huggingface.co/${source.owner}/${source.repo}/resolve/${source.revision}/${file}`

/** The roles each kind's files have, in a fixed order: what a complete download holds (a role may be several files). */
export function sherpaRoles(kind: SherpaKind): SherpaRole[] {
  return [...parts[kind].roles, ...(parts[kind].files ?? []), ...(kind === 'qwen3-asr' ? [] : ['tokens' as const])]
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
  const model: Record<string, string | number> = Object.fromEntries(roles.map(role => [role, role === 'tokenizer' ? folderOf(file, source) : path(role)]))
  if (source.kind === 'canary') Object.assign(model, { srcLang: spoken, tgtLang: spoken, usePnc: 1 })
  if (source.kind === 'sense-voice') Object.assign(model, { language: '', useInverseTextNormalization: 1 })
  // Told the language for each piece too (sherpaEngine.ts); this one is what a piece without it would get.
  if (source.kind === 'cohere-transcribe') Object.assign(model, { language: spoken, usePunct: 1, useItn: 1 })
  // The C API starts these at zero, and a zero is refused: both set outright (qwen3Limits says why these).
  if (source.kind === 'qwen3-asr') Object.assign(model, qwen3Limits)
  const modelConfig: Record<string, unknown> = { [field]: model, tokens: source.kind === 'qwen3-asr' ? '' : path('tokens'), numThreads: threads, provider: 'cpu', debug: 0 }
  if (source.kind === 'nemo-transducer') modelConfig.modelType = 'nemo_transducer'
  return {
    // Parakeet wants 128 mel bins; sherpa-onnx reads that from the model itself.
    featConfig: { sampleRate: 16_000, featureDim: 80 },
    modelConfig,
    decodingMethod: 'greedy_search',
  }
}

/** Qwen3-ASR's tokenizer is a folder: the one its files lie in, named by the files (`tokenizer/vocab.json`). */
function folderOf(file: (name: string) => string, source: SherpaSource): string {
  const found = source.files.find(entry => entry.role === 'tokenizer')
  if (!found || !found.name.includes('/')) throw new Error(`${source.repo} has no tokenizer folder`)
  return file(found.name.slice(0, found.name.lastIndexOf('/')))
}

/**
 * Qwen3-ASR's limits per piece, in tokens. Its decoder holds 512 of them for
 * the prompt (15), the audio (13 a second) and the text together, and a
 * longer piece is cut short by sherpa-onnx: 40 s of audio (520 tokens) came
 * back as the single word "language". So pieces are
 * 15 s (195 tokens), which leaves 300 for the text and the word list
 * (a hot word is 4 tokens at most, the list 80 in all). The C API starts both
 * numbers at zero, and zero is refused: set outright.
 */
export const qwen3Limits = { maxNewTokens: 256, maxTotalLen: 512 }

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
