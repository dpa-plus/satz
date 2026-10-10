import type { Language } from './language'
import { runsSherpa, type SherpaFile, type SherpaSource } from './sherpa'

/**
 * The models satz offers for the provider "Lokal", one card each in
 * Settings: what each downloads, what it is good at, Handy's scores for its
 * accuracy and speed, the published German error rate where there is one,
 * and how fast it ran on this computer once measured. The one place these
 * models are named; the settings, the download's progress bar, the model
 * menus and both engines read it.
 *
 * Two engines. Whisper runs through transformers.js (whisperEngine.ts): all
 * are onnx-community repos whose three files satz loads (localFiles.ts)
 * exist and whose 4-bit decoders take no `cache_position`, which
 * transformers.js 4.3.1 never sends; each was run end to end on 09.10.2026,
 * and is fetched from the commit it was run at (`WhisperSource`).
 * Left out on purpose: the *.en models (one model for English alone is
 * enough: Distil Large v3.5), lite-whisper (no language table),
 * whisper-small-ONNX and whisper-large-v3-turbo-ONNX (their 4-bit decoders
 * want `cache_position`) and Xenova/whisper-large* (no 4-bit decoder).
 * Handy's models run through sherpa-onnx (sherpaEngine.ts), from single
 * files in csukuangfj's repos (core/sherpa.ts); the newer ones (Cohere
 * Transcribe, Qwen3-ASR) from csukuangfj2's, and two community exports
 * (Canary 1B v2, the German Parakeet) from their makers'. Each repo is
 * named with its owner and the commit it was run at.
 */
export interface LocalModel {
  id: string
  name: string
  engine: 'whisper' | 'sherpa'
  /** One plain sentence under the name. */
  description: { de: string; en: string }
  /** What is downloaded: Whisper's 8-bit encoder, 4-bit decoder and tokenizer.json (the few kB of JSON beside them left out), or every sherpa file. */
  bytes: number
  /** The original model, as the benchmarks name it. */
  original: string
  /** Who made the original, for the model menus. */
  maker: string
  /**
   * How it knows which language it hears. 'auto': it finds out itself
   * (Whisper between German and English, Parakeet V3 and SenseVoice among
   * theirs). 'spoken': it is told the one set under "Gesprochen auf"
   * (Canary). A language: the only one it writes, and always told that one
   * (onlyLanguage): Distil Large v3.5 writes English only, and primeLine
   * tuned theirs on German alone.
   */
  language: 'auto' | 'spoken' | Language
  /** What it writes, as language codes ("yue" is Cantonese): the card's globe line. Whisper's are the two satz lets it choose from. */
  languages: string[]
  /** Handy's scores from 0 to 1, the card's two bars. The speed counts until the model is measured here. */
  accuracy: number
  speed: number
  /** Where a sherpa-onnx model's files come from, and how it runs. */
  sherpa?: SherpaSource
  /** The commit and the files of a Whisper repo; none for one typed in by hand. */
  whisper?: WhisperSource
}

/** The three files satz loads from a Whisper repo (transformers.js names them for the encoder at 8 bits and the decoder at 4). */
export const whisperFiles = ['onnx/encoder_model_quantized.onnx', 'onnx/decoder_model_merged_q4.onnx', 'tokenizer.json']

/** What a Whisper file has to be, from the repo's file list at the commit. */
export interface WhisperFile {
  name: string
  bytes: number
  /** The two ONNX files are LFS files: Hugging Face lists their SHA-256. */
  sha256?: string
  /** tokenizer.json is a plain git file, listed by its git blob id: the SHA-1 of "blob <bytes>", a NUL byte and the content. */
  gitOid?: string
}

/**
 * Whisper's files come from one commit of the onnx-community repo, not
 * whatever `main` holds that day (src/main/whisperEngine.ts asks for it, and
 * checks each file while it arrives): a re-upload there broke every new
 * download before, and a repo that changes must not change what satz runs.
 */
export interface WhisperSource {
  revision: string
  files: WhisperFile[]
}

/** The encoder, the decoder and the tokenizer of a Whisper repo, each as `[bytes, SHA-256 or git blob id]`. */
function pinned(revision: string, encoder: [number, string], decoder: [number, string], tokenizer: [number, string]): WhisperSource {
  const [encoderFile, decoderFile, tokenizerFile] = whisperFiles
  return { revision, files: [
    { name: encoderFile, bytes: encoder[0], sha256: encoder[1] },
    { name: decoderFile, bytes: decoder[0], sha256: decoder[1] },
    { name: tokenizerFile, bytes: tokenizer[0], gitOid: tokenizer[1] },
  ] }
}

const whisperModel = { engine: 'whisper' as const, language: 'auto' as const, languages: ['de', 'en'], maker: 'OpenAI' }
const total = (files: SherpaFile[]) => files.reduce((sum, file) => sum + file.bytes, 0)

/** One sherpa-onnx model; its size is the sum of its files. */
function sherpaModel(model: Omit<LocalModel, 'engine' | 'bytes' | 'sherpa'>, sherpa: SherpaSource): LocalModel {
  return { ...model, engine: 'sherpa', bytes: total(sherpa.files), sherpa }
}

// The 25 languages NVIDIA lists for Parakeet TDT 0.6B v3, as Handy has them.
const european = ['bg', 'hr', 'cs', 'da', 'nl', 'en', 'et', 'fi', 'fr', 'de', 'el', 'hu', 'it', 'lv', 'lt', 'mt', 'pl', 'pt', 'ro', 'sk', 'sl', 'es', 'sv', 'ru', 'uk']

/**
 * The default first. Then those that write German, most accurate first;
 * the German-only ones; then those that write no German, most accurate
 * first. Sizes and checksums from each repo's file list (09.10.2026; the
 * four added on 10.10.2026 from theirs at the commits named).
 */
export const localModels: LocalModel[] = [
  { ...whisperModel, id: 'onnx-community/whisper-large-v3-turbo', name: 'Whisper Large v3 Turbo', bytes: 981_450_034, original: 'openai/whisper-large-v3-turbo',
    whisper: pinned('360ebcde2559d60bb474678be3c1de9ef347d01a', [644822195, 'd2f853dc3254fdc0079f55dd4433ea716ac98ec5574d3b475f288f2a77cebba9'], [334147222, '8b933ac24074a24a1635084d06a4ed37e387ef22d980f184a5fc27418e9ceeb8'], [2480617, '3a5e2ba63acdcac9a19ba56cf9bd27f185bfff61']),
    description: { de: 'Ausgewogen: genau und schnell.', en: 'Balanced: accurate and fast.' }, accuracy: 0.80, speed: 0.40 },
  sherpaModel({ id: 'sherpa/cohere-transcribe', name: 'Cohere Transcribe', original: 'CohereLabs/cohere-transcribe-03-2026', maker: 'Cohere', language: 'spoken',
    languages: ['de', 'en', 'es', 'fr', 'it', 'nl', 'pl', 'pt', 'el', 'ar', 'ja', 'ko', 'vi', 'zh'],
    description: { de: 'Am genauesten auf Deutsch, groß.', en: 'The most accurate in German, but big.' }, accuracy: 0.90, speed: 0.35 }, {
    // Cannot tell the language (it is told, like Canary) and makes something up for noise, which the speech check in front of every piece keeps from it.
    // At most 35 s per piece: 30 s, cut at a quiet moment. Its encoder's weights are a second file that must lie beside it under exactly that name.
    kind: 'cohere-transcribe', owner: 'csukuangfj2', repo: 'sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01', revision: '156a470cf08eefe706a0004f3c52d9ee567ca7a0', window: 30, files: [
      { name: 'encoder.int8.onnx', role: 'encoder', bytes: 3_090_822, sha256: 'cf704f8cfa90e3f0a76f9ffc05998bdf00ba9ae983192c14a85a3a5eb008b367' },
      { name: 'encoder.int8.onnx.data', role: 'data', bytes: 2_731_503_072, sha256: 'bcf1b7148c8518ae52df1ad2d2fc2b4e89261ea23e6c874eef1d9f55bcbaa4a3' },
      { name: 'decoder.int8.onnx', role: 'decoder', bytes: 153_250_705, sha256: '8372ca6c8ff4db8b916ca3592f5c757a715e691b9edec751ba19b29fc854baf9' },
      { name: 'tokens.txt', role: 'tokens', bytes: 207_437, sha256: '013ede043ae2480e3a9205cc34550d9686100cc682bacc90f702facdfbb93035' },
    ] }),
  { ...whisperModel, id: 'onnx-community/whisper-large-v3-ONNX', name: 'Whisper Large v3', bytes: 1_445_984_744, original: 'openai/whisper-large-v3',
    whisper: pinned('3b6257ad5e67aa523c7c07f4fea04d445eecc4a6', [644795348, 'f438cff17ce55089f5046c7392421ec646cdf3081098a6510558578321a15c3f'], [797258751, 'd02d5453f8dd09f7c5d34cb0c7432131c4e151f4797387282a59ad82db388655'], [3930645, '33c8354828689f5daef89956ad477df739eccd16']),
    description: { de: 'Sehr genau, aber langsam.', en: 'Very accurate, but slow.' }, accuracy: 0.85, speed: 0.30 },
  sherpaModel({ id: 'sherpa/canary-1b-v2', name: 'Canary 1B v2', original: 'nvidia/canary-1b-v2', maker: 'NVIDIA', language: 'spoken', languages: ['en', 'de', 'es', 'fr'],
    description: { de: 'Genauer als der kleine Canary, aber größer und langsamer.', en: 'More accurate than the small Canary, but bigger and slower.' }, accuracy: 0.85, speed: 0.55 }, {
    // A community export (Sarphix, CC-BY-4.0). The model writes 25 languages; sherpa-onnx 1.13.8 knows four of them by name.
    kind: 'canary', owner: 'Sarphix', repo: 'canary-1b-v2-sherpa-onnx-int8', revision: '7d513cd4f39f6c7dc75c13a284b5e345b37f6198', window: 30, files: [
      { name: 'encoder.int8.onnx', role: 'encoder', bytes: 857_602_351, sha256: '0d8f349aaa015d47c81d88c4ba3a5461c19bc09ebb72bf4c61698eec9f09e968' },
      { name: 'decoder.int8.onnx', role: 'decoder', bytes: 558_682_707, sha256: 'e68d839a8939a0c1d55d03fd5c6e6d3f113cfc97038027ffe566b8e3a4be2cd8' },
      { name: 'tokens.txt', role: 'tokens', bytes: 224_406, sha256: '399db68418b655f50275779cfe425c55a5ef6dda12cf38375d709566927ef513' },
    ] }),
  sherpaModel({ id: 'sherpa/parakeet-v3', name: 'Parakeet V3', original: 'nvidia/parakeet-tdt-0.6b-v3', maker: 'NVIDIA', language: 'auto', languages: european,
    description: { de: 'Schnell und genau. 25 europäische Sprachen.', en: 'Fast and accurate. 25 European languages.' }, accuracy: 0.80, speed: 0.85 }, {
    kind: 'nemo-transducer', owner: 'csukuangfj', repo: 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8', revision: '2bda32ec70b097a55adaa07d9a7173915b43cc78', window: 240, files: [
      { name: 'encoder.int8.onnx', role: 'encoder', bytes: 652_184_281, sha256: 'acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247' },
      { name: 'decoder.int8.onnx', role: 'decoder', bytes: 11_845_275, sha256: '179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e' },
      { name: 'joiner.int8.onnx', role: 'joiner', bytes: 6_355_277, sha256: '3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3' },
      { name: 'tokens.txt', role: 'tokens', bytes: 93_939, sha256: 'd58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d' },
    ] }),
  { ...whisperModel, id: 'onnx-community/whisper-medium-ONNX', name: 'Whisper Medium', bytes: 786_438_953, original: 'openai/whisper-medium',
    whisper: pinned('d3978248a6b5de6df7ec29ddfbde3993845fa806', [313154567, '2507d090bf9f1d468f4c1cef274aa34eda025894118f5476e24a0d80308a5315'], [469353892, 'ddd9200a8e1045a8432467e685632075fda1fca9cede9014e9556169b615bde5'], [3930494, '7e30a8ca85fc59e4ce975a4e6d488771714891fb']),
    description: { de: 'Gute Genauigkeit, mittleres Tempo.', en: 'Good accuracy, medium speed.' }, accuracy: 0.75, speed: 0.60 },
  sherpaModel({ id: 'sherpa/canary-180m', name: 'Canary 180M Flash', original: 'nvidia/canary-180m-flash', maker: 'NVIDIA', language: 'spoken', languages: ['en', 'de', 'es', 'fr'],
    description: { de: 'Sehr schnell. Englisch, Deutsch, Spanisch, Französisch.', en: 'Very fast. English, German, Spanish, French.' }, accuracy: 0.75, speed: 0.85 }, {
    kind: 'canary', owner: 'csukuangfj', repo: 'sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8', revision: '9077164e0d3dd1d5353743e89ceaa1d3a770838c', window: 30, files: [
      { name: 'encoder.int8.onnx', role: 'encoder', bytes: 132_678_643, sha256: '7a75b4e2a5857a6dcc0819503bbe3fad66943db4a3ccf21d3f27c633667d303f' },
      { name: 'decoder.int8.onnx', role: 'decoder', bytes: 74_437_848, sha256: 'e41a2ab9c0c2fe81a1e8ade5a45fb02a74bc4db7d1f91b89a54a25e2cf79cba2' },
      { name: 'tokens.txt', role: 'tokens', bytes: 53_555, sha256: '2dae6fc7815f9640645e0c765522b278ee0cef49b482d91f6913e334628d3e77' },
    ] }),
  sherpaModel({ id: 'sherpa/qwen3-asr-0.6b', name: 'Qwen3-ASR 0.6B', original: 'Qwen/Qwen3-ASR-0.6B-hf', maker: 'Alibaba', language: 'auto',
    languages: ['en', 'de', 'es', 'fr', 'it', 'pt', 'nl', 'pl', 'ru', 'cs', 'da', 'el', 'fi', 'hu', 'mk', 'ro', 'sv', 'tr', 'ar', 'fa', 'hi', 'id', 'ms', 'th', 'vi', 'fil', 'zh', 'yue', 'ja', 'ko'],
    description: { de: 'Klein, erkennt die Sprache selbst. Nimmt den Wortschatz als Hinweis.', en: 'Small, tells the language by itself. Takes the word list as a hint.' }, accuracy: 0.75, speed: 0.55 }, {
    kind: 'qwen3-asr', owner: 'csukuangfj2', repo: 'sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25', revision: '68818b2313fe77bd06f6a7c5068ff3ef59d02b8a', window: 15, files: [
      { name: 'conv_frontend.onnx', role: 'convFrontend', bytes: 44_148_281, sha256: 'd22dc4423e0940e49884e903d2ea2f7e5567c14fc1aed97e4e26d6b8f208ef9e' },
      { name: 'encoder.int8.onnx', role: 'encoder', bytes: 182_491_662, sha256: '60748d3e6744a57c9c91e1b17424a6c2990567e8adceb0783940c03ed98fa9d9' },
      { name: 'decoder.int8.onnx', role: 'decoder', bytes: 755_914_231, sha256: '4f6885be5959ae26af3089d38ee7972c5fafbeeb1cf8d5e76eab6d8b61ca5771' },
      { name: 'tokenizer/vocab.json', role: 'tokenizer', bytes: 2_776_833, sha256: 'ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910' },
      { name: 'tokenizer/merges.txt', role: 'tokenizer', bytes: 1_671_853, sha256: '8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5' },
      { name: 'tokenizer/tokenizer_config.json', role: 'tokenizer', bytes: 12_487, sha256: '4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c' },
    ] }),
  { ...whisperModel, id: 'onnx-community/whisper-small', name: 'Whisper Small', bytes: 327_955_953, original: 'openai/whisper-small',
    whisper: pinned('36050c46d777d46dc4b5f43f6d90574fc38f8732', [92326160, 'a43a83f3c5361cd591cfa7c36f14b43cf7cb22f47a415cc14a8d557be800fa92'], [233149327, '795c61b344576719c2b249cc9911c78b4cc552c8c6a5407be21a3380a0791b13'], [2480466, '1e95340ff836fad1b5932e800fb7b8c5e6d78a74']),
    description: { de: 'Schnell, ordentlich auf Englisch.', en: 'Fast, decent in English.' }, accuracy: 0.60, speed: 0.85 },
  { ...whisperModel, id: 'onnx-community/whisper-base', name: 'Whisper Base', bytes: 149_284_199, original: 'openai/whisper-base',
    whisper: pinned('1846881b6b3a3024392c1eea3ad983695bc23925', [23201314, '5862993336bf33acd23736071aae2b32261d3b1b2f37780194460d4ef974dd46'], [123602419, '09f83b71ceedc97dab1d90b914715dc532a646a147abda11d83c64867b7c319c'], [2480466, '1e95340ff836fad1b5932e800fb7b8c5e6d78a74']),
    description: { de: 'Sehr schnell, ungenau.', en: 'Very fast, rough.' }, accuracy: 0.45, speed: 0.90 },
  { ...whisperModel, id: 'onnx-community/whisper-tiny', name: 'Whisper Tiny', bytes: 99_319_158, original: 'openai/whisper-tiny',
    whisper: pinned('ff4177021cc41f7db950912b73ea4fdf7d01d8e7', [10124990, '2af4a414ca47aa30f61246017e5fe82b0a8d229281d1255ba666a2a7f6b84d19'], [86713702, 'a7573efde84f7d018d59e50e7f860c03e26623d68e23eb6037b76135367e72eb'], [2480466, '1e95340ff836fad1b5932e800fb7b8c5e6d78a74']),
    description: { de: 'Am schnellsten, sehr ungenau.', en: 'Fastest, very rough.' }, accuracy: 0.35, speed: 0.95 },
  sherpaModel({ id: 'sherpa/parakeet-german', name: 'Parakeet V3 German', original: 'primeline/parakeet-primeline', maker: 'primeLine', language: 'de', languages: ['de'],
    description: { de: 'Auf Deutsch nachtrainiert, schnell. Schreibt „ss“ statt „ß“.', en: 'Retrained on German, fast. Writes "ss" for "ß".' }, accuracy: 0.80, speed: 0.85 }, {
    // A community export (x-ian) of primeLine's fine-tune. The repo holds other files (a speaker model, a handler) that satz leaves alone.
    kind: 'nemo-transducer', owner: 'x-ian', repo: 'sherpa-onnx-parakeet-primeline-de-int8', revision: '2a97df7e501bc25c6106a150a3379c5272088c53', window: 240, files: [
      { name: 'encoder.int8.onnx', role: 'encoder', bytes: 652_282_298, sha256: 'ecb67ffb98a12bf46eaf7657cb2f714f6569511817a831296325dd32bc4daa30' },
      { name: 'decoder.int8.onnx', role: 'decoder', bytes: 11_845_275, sha256: 'fb4ddefe200706cabb27ee3fc1c81efa50555a4c8a8e00b663cc795216fb9369' },
      { name: 'joiner.int8.onnx', role: 'joiner', bytes: 6_355_277, sha256: '8220c0d117d81bdd0d8c770881932ac340f1ce4b36932941d561d11ad1aaffce' },
      { name: 'tokens.txt', role: 'tokens', bytes: 93_939, sha256: 'd58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d' },
    ] }),
  { ...whisperModel, id: 'onnx-community/whisper-large-v3-turbo-german-ONNX', name: 'Whisper Large v3 Turbo German', bytes: 982_774_635, original: 'primeLine/whisper-large-v3-turbo-german',
    whisper: pinned('7a86cb9d63ad2517468c15fdac7dc9bb6d2abaed', [644795356, 'ac189ad19f63aa243af53cccd4dc4b82f27b2538c301cee7f861bf2076a39973'], [334048634, '997b30e5561f844e57424a8ea62a5d2b6fa7247aa060239f4b4142a40cb7a508'], [3930645, '33c8354828689f5daef89956ad477df739eccd16']),
    maker: 'primeLine', language: 'de', languages: ['de'], description: { de: 'Turbo, auf Deutsch trainiert.', en: 'Turbo, trained on German.' }, accuracy: 0.80, speed: 0.40 },
  sherpaModel({ id: 'sherpa/parakeet-v2', name: 'Parakeet V2', original: 'nvidia/parakeet-tdt-0.6b-v2', maker: 'NVIDIA', language: 'en', languages: ['en'],
    description: { de: 'Nur Englisch, das beste für Englisch.', en: 'English only. The best for English.' }, accuracy: 0.85, speed: 0.85 }, {
    kind: 'nemo-transducer', owner: 'csukuangfj', repo: 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8', revision: '1ab9323565ddb038682214b292f588070a538ce2', window: 240, files: [
      { name: 'encoder.int8.onnx', role: 'encoder', bytes: 652_184_296, sha256: 'a32b12d17bbbc309d0686fbbcc2987b5e9b8333a7da83fa6b089f0a2acd651ab' },
      { name: 'decoder.int8.onnx', role: 'decoder', bytes: 7_257_753, sha256: 'b6bb64963457237b900e496ee9994b59294526439fbcc1fecf705b31a15c6b4e' },
      { name: 'joiner.int8.onnx', role: 'joiner', bytes: 1_739_080, sha256: '7946164367946e7f9f29a122407c3252b680dbae9a51343eb2488d057c3c43d2' },
      { name: 'tokens.txt', role: 'tokens', bytes: 9_384, sha256: 'ec182b70dd42113aff6c5372c75cac58c952443eb22322f57bbd7f53977d497d' },
    ] }),
  { ...whisperModel, id: 'onnx-community/distil-large-v3.5-ONNX', name: 'Distil-Whisper Large v3.5', bytes: 949_690_520, original: 'distil-whisper/distil-large-v3.5',
    whisper: pinned('d908cd7fba0fb226f14b14ad955f22797ecfe5d5', [644795348, 'f438cff17ce55089f5046c7392421ec646cdf3081098a6510558578321a15c3f'], [300964527, '7d330d2a5b0ca10585d9687ac1690e1dfd0c99f46ebdfa35d6b914ebd7cd696f'], [3930645, '33c8354828689f5daef89956ad477df739eccd16']),
    maker: 'Hugging Face', language: 'en', languages: ['en'], description: { de: 'Schnell, nur Englisch.', en: 'Fast, English only.' }, accuracy: 0.75, speed: 0.45 },
  sherpaModel({ id: 'sherpa/moonshine-base', name: 'Moonshine Base', original: 'UsefulSensors/moonshine-base', maker: 'Useful Sensors', language: 'en', languages: ['en'],
    description: { de: 'Sehr schnell, nur Englisch. Kommt gut mit Akzenten klar.', en: 'Very fast, English only. Handles accents well.' }, accuracy: 0.70, speed: 0.90 }, {
    kind: 'moonshine', owner: 'csukuangfj', repo: 'sherpa-onnx-moonshine-base-en-int8', revision: '052b0798ad1bf046a140fdd4efcd9426530fa3f5', window: 30, files: [
      { name: 'preprocess.onnx', role: 'preprocessor', bytes: 14_077_290, sha256: 'ffa630d395c5ccf76f5d4954be5b882df76aaf6491519ec01fd82ea7a3819fb2' },
      { name: 'encode.int8.onnx', role: 'encoder', bytes: 50_311_494, sha256: '7e38770f776f2e5583a53b052936005df2ba5c833d7e09c2a5fd796b94bf73e2' },
      { name: 'uncached_decode.int8.onnx', role: 'uncachedDecoder', bytes: 122_120_451, sha256: 'c01f4b35093bcac20d352d23a75a539e772964579f9d024a90e5e6f09cae9987' },
      { name: 'cached_decode.int8.onnx', role: 'cachedDecoder', bytes: 99_983_837, sha256: '2db74e51cedf64a8b1be3c8192e0bb5e4923af0e90bd9e87f8e8771873f8ea03' },
      { name: 'tokens.txt', role: 'tokens', bytes: 436_688, sha256: '1165c2aeb9f72f457a83be2d459a09054f27490acd9b41bd43794dfd25e296ea' },
    ] }),
  // The original export: the 2025-09-09 one is tuned for Cantonese and wrote
  // English as "PNNYES … BULLDOSZING THE GROOSSER" (this one writes it right).
  sherpaModel({ id: 'sherpa/sense-voice', name: 'SenseVoice', original: 'FunAudioLLM/SenseVoiceSmall', maker: 'Alibaba', language: 'auto', languages: ['zh', 'en', 'ja', 'ko', 'yue'],
    description: { de: 'Sehr schnell. Chinesisch, Englisch, Japanisch, Koreanisch, Kantonesisch.', en: 'Very fast. Chinese, English, Japanese, Korean, Cantonese.' }, accuracy: 0.65, speed: 0.95 }, {
    kind: 'sense-voice', owner: 'csukuangfj', repo: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17', revision: '2365baeacb507f821a0c8120fcee3d484dba7a07', window: 30, files: [
      { name: 'model.int8.onnx', role: 'model', bytes: 239_233_841, sha256: 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51' },
      { name: 'tokens.txt', role: 'tokens', bytes: 315_894, sha256: 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc' },
    ] }),
  sherpaModel({ id: 'sherpa/moonshine-tiny', name: 'Moonshine Tiny', original: 'UsefulSensors/moonshine-tiny', maker: 'Useful Sensors', language: 'en', languages: ['en'],
    description: { de: 'Extrem schnell, nur Englisch.', en: 'Extremely fast, English only.' }, accuracy: 0.55, speed: 0.95 }, {
    kind: 'moonshine', owner: 'csukuangfj', repo: 'sherpa-onnx-moonshine-tiny-en-int8', revision: 'bf2b762c076d8ea61e2af0b3851c9564fb77552e', window: 30, files: [
      { name: 'preprocess.onnx', role: 'preprocessor', bytes: 6_800_738, sha256: 'f33addce61a143460fe753b5ee5b7db255e5140b5b779c065b94f6c83ff0bf4e' },
      { name: 'encode.int8.onnx', role: 'encoder', bytes: 18_249_187, sha256: '8774dfba578de027ec6595c2c654a0836434489bc963a0db124a7f181f571acb' },
      { name: 'uncached_decode.int8.onnx', role: 'uncachedDecoder', bytes: 53_216_096, sha256: '216737000dd5881a17aa043f6bbd286add33e4c3b0ae257153e2ec15438bdc41' },
      { name: 'cached_decode.int8.onnx', role: 'cachedDecoder', bytes: 45_264_830, sha256: '2aff28bba6a03d8dcf5c9feac45462629bae37317442299f28115ad09da773f6' },
      { name: 'tokens.txt', role: 'tokens', bytes: 436_688, sha256: '1165c2aeb9f72f457a83be2d459a09054f27490acd9b41bd43794dfd25e296ea' },
    ] }),
]

/** The catalog's entry for an id, undefined for one typed in by hand earlier. */
export const localModel = (id: string) => localModels.find(model => model.id === id)

/** The models this system can run: sherpa-onnx has no build for Windows on ARM, so there its models are left out without a word. */
export const offeredModels = (platform: string, arch: string) => localModels.filter(model => model.engine !== 'sherpa' || runsSherpa(platform, arch))

/** The cards Settings shows: the models offered, and the model in use when it is not in the catalog. */
export const localModelIds = (inUse: string, offered: LocalModel[] = localModels) =>
  [...offered.map(model => model.id), ...(inUse && !localModel(inUse) ? [inUse] : [])]

/** The engine an id runs on; one typed in by hand is a Whisper repo. */
export const engineOf = (id: string) => localModel(id)?.engine ?? 'whisper'

/** The language a single-language model always decodes in; undefined where the model finds out (or is told) and for a model typed in by hand. */
export function onlyLanguage(id: string): Language | undefined {
  const language = localModel(id)?.language
  return language === 'de' || language === 'en' ? language : undefined
}

/**
 * What a model that cannot tell the language (Canary) is told: the one
 * chosen for it among those it writes, else the language set under
 * "Gesprochen auf" (German or English, the app's own setting, which Whisper
 * and the replacements use), else its first. Undefined for every other model.
 */
export function toldLanguage(id: string, chosen: string | null | undefined, spoken: Language): string | undefined {
  const model = localModel(id)
  if (model?.language !== 'spoken') return undefined
  if (chosen && model.languages.includes(chosen)) return chosen
  return model.languages.includes(spoken) ? spoken : model.languages[0]
}

/** A German error rate means something only for a model that writes German. */
const hearsGerman = (model: LocalModel) => model.languages.includes('de')

// MARK: - German errors

/**
 * Word error rate in German on FLEURS, of the original models (satz runs
 * 8-bit and 4-bit builds; nobody publishes numbers for those). Large v3,
 * Turbo and Parakeet V3 from the Open ASR Leaderboard's German file (checked
 * against it on 09.10.2026: 3.2, 3.67 and 4.16), Cohere Transcribe, Canary 1B
 * v2 and Qwen3-ASR 0.6B from the same file on 10.10.2026 (3.33, 3.43 and 5.41;
 * the leaderboard names Qwen's "-hf"), medium, small, base and tiny from the
 * Whisper paper (arXiv 2212.04356, Table 13), the only place they are
 * published. None for the German fine-tunes and Canary 180M Flash (the
 * leaderboard has no row for them; the makers' own numbers are on other
 * test sets) and the models that write no German.
 */
export const shippedGermanErrors: Record<string, number> = {
  'openai/whisper-large-v3-turbo': 3.67,
  'openai/whisper-large-v3': 3.2,
  'CohereLabs/cohere-transcribe-03-2026': 3.33,
  'nvidia/canary-1b-v2': 3.43,
  'nvidia/parakeet-tdt-0.6b-v3': 4.16,
  'Qwen/Qwen3-ASR-0.6B-hf': 5.41,
  'openai/whisper-medium': 6.5,
  'openai/whisper-small': 10.2,
  'openai/whisper-base': 17.9,
  'openai/whisper-tiny': 27.8,
}

/** Where a German error rate comes from, named in the bar's help: the Whisper paper for the four it alone has numbers for. */
const whisperPaper = new Set(['openai/whisper-medium', 'openai/whisper-small', 'openai/whisper-base', 'openai/whisper-tiny'])
const errorSource = (original: string, language: Language) => (whisperPaper.has(original) ? (language === 'de' ? 'Whisper-Paper' : 'Whisper paper') : 'Open ASR Leaderboard')

/** The leaderboard's German results; a new row there reaches satz within a day. */
export const germanErrorsURL = 'https://huggingface.co/datasets/hf-audio/multilingual_evals/resolve/main/multilingual_de.csv'

/**
 * `model,RTFx,FLEURS WER,MCV WER`, read by the column names: the leaderboard
 * has added and dropped columns several times. Only the models satz offers
 * that write German; a row that is not a number between 0 and 100 is left out.
 */
export function parseGermanErrors(csv: string): Record<string, number> {
  const [header, ...rows] = csv.split(/\r?\n/).filter(line => line.trim()).map(csvFields)
  const model = header?.indexOf('model') ?? -1
  const wer = header?.indexOf('FLEURS WER') ?? -1
  if (model < 0 || wer < 0) return {}
  const wanted = new Set(localModels.filter(hearsGerman).map(entry => entry.original))
  const found: Record<string, number> = {}
  for (const row of rows) {
    const rate = Number(row[wer])
    if (wanted.has(row[model]) && row[wer]?.trim() && rate > 0 && rate < 100) found[row[model]] = rate
  }
  return found
}

/** One CSV line's fields; quotes allow commas inside a field. */
function csvFields(line: string): string[] {
  const fields: string[] = []
  let field = '', quoted = false
  for (let i = 0; i < line.length; i++) {
    const c = line[i]
    if (quoted && c === '"' && line[i + 1] === '"') { field += '"'; i++ }
    else if (c === '"') quoted = !quoted
    else if (c === ',' && !quoted) { fields.push(field.trim()); field = '' }
    else field += c
  }
  fields.push(field.trim())
  return fields
}

/** Today's numbers where the leaderboard has them, the shipped ones for the rest. */
export const germanErrors = (live: Record<string, number> = {}) => ({ ...shippedGermanErrors, ...live })

// MARK: - Speed

/** What a speed test on this computer found, kept beside the model (`<id>.speed.json`). */
export interface Speed {
  /** Seconds of work for 10 seconds of speech: what waiting after a dictation feels like. */
  secondsPer10: number
  /** ISO date of the test. */
  date: string
  /** The satz that measured it. */
  version: string
  /** Processor and core count. */
  machine: string
}

/** One run's wall time over a clip, as seconds per 10 s of speech. */
export const secondsPer10 = (elapsedMs: number, clipSeconds: number) => (elapsedMs / 1000) * 10 / clipSeconds

/** Measured on this computer with this satz; anything else is shown with its date. */
export const measuredHere = (speed: Speed, machine: string, version: string) => speed.machine === machine && speed.version === version

/**
 * The speed bar for a measured model: seconds per 10 s of speech on a log
 * scale, 0.2 s or less full, 1 s at 0.7, 3 s at 0.4, 10 s or more at 0.1.
 * Waiting feels like a ratio: 0.5 s against 1 s matters as much as 5 against 10.
 */
export function speedScore(secondsPer10: number): number {
  const points: [number, number][] = [[0.2, 1], [1, 0.7], [3, 0.4], [10, 0.1]]
  if (!(secondsPer10 > points[0][0])) return 1
  for (let i = 1; i < points.length; i++) {
    const [[s0, v0], [s1, v1]] = [points[i - 1], points[i]]
    if (secondsPer10 <= s1) return v0 + (v1 - v0) * (Math.log(secondsPer10 / s0) / Math.log(s1 / s0))
  }
  return 0.1
}

// MARK: - Words

const number = (value: number, digits: number, language: Language) =>
  value.toLocaleString(language === 'de' ? 'de-DE' : 'en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits })

/** "981 MB", "1,4 GB" (decimal units, as the download's own file sizes). */
export function formatSize(bytes: number, language: Language): string {
  const mb = Math.round(bytes / 1e6)
  return mb < 1000 ? `${mb} MB` : `${number(bytes / 1e9, 1, language)} GB`
}

/** "0,7 s für 10 s Sprechen"; whole seconds from ten on. */
export function formatSpeed(seconds: number, language: Language): string {
  const shown = number(Math.max(0.1, seconds), seconds < 10 ? 1 : 0, language)
  return language === 'de' ? `${shown} s für 10 s Sprechen` : `${shown} s per 10 s of speech`
}

export function formatGermanErrors(rate: number, language: Language): string {
  return language === 'de' ? `${number(rate, 1, language)} % Fehler auf Deutsch` : `${number(rate, 1, language)} % errors in German`
}

/** A language's name in German or English ("Kantonesisch"). */
export const languageName = (code: string, language: Language) => new Intl.DisplayNames([language], { type: 'language' }).of(code) ?? code

/**
 * The card's globe line: "Nur Englisch", "Deutsch und Englisch",
 * "Englisch, Deutsch, Spanisch, Französisch", "25 Sprachen"; the help says
 * how the model knows which one it hears, and lists them where the line
 * only counts them.
 */
export function languageLine(model: LocalModel, language: Language): { text: string; help: string } {
  const t = (de: string, en: string) => (language === 'de' ? de : en)
  const names = model.languages.map(code => languageName(code, language))
  const text = names.length === 1 ? t(`Nur ${names[0]}`, `${names[0]} only`)
    : names.length === 2 ? t(`${names[0]} und ${names[1]}`, `${names[0]} and ${names[1]}`)
      : names.length <= 5 ? names.join(', ') : t(`${names.length} Sprachen`, `${names.length} languages`)
  const how = model.language === 'spoken' ? t('Hört auf die Sprache unter „Gesprochen auf“.', 'Listens for the language set under "Spoken in".')
    : model.language !== 'auto' ? t('Schreibt nur diese Sprache.', 'Writes this language only.')
      : model.engine === 'whisper' ? t('Erkennt selbst, ob Deutsch oder Englisch gesprochen wird.', 'Tells German from English by itself.')
        : t('Erkennt die Sprache selbst.', 'Tells the language by itself.')
  return { text, help: names.length > 5 ? `${how} ${names.join(', ')}.` : how }
}

/** A bar on a model's card: how full, and the numbers behind it. */
export interface Bar { value: number; help: string }

/**
 * The two bars on a model's card. Accuracy is Handy's score, with the
 * published German error rate in its help where there is one. Speed comes
 * from the measurement on this computer once there is one, else from the
 * fixed score, and says which. A model typed in by hand has no accuracy and
 * a speed only once measured.
 */
export function modelBars(id: string, language: Language, options: { speed?: Speed | null; here?: boolean; errors?: Record<string, number>; downloaded?: boolean } = {}): { accuracy?: Bar; speed?: Bar } {
  const t = (de: string, en: string) => (language === 'de' ? de : en)
  const model = localModel(id)
  const rate = model && hearsGerman(model) ? germanErrors(options.errors)[model.original] : undefined
  const accuracy = model && {
    value: model.accuracy,
    help: rate === undefined ? t('Geschätzt', 'Estimated')
      : `${formatGermanErrors(rate, language)} ${t(`(FLEURS, ${errorSource(model!.original, language)}, Originalmodell, nicht die geladene Fassung)`, `(FLEURS, ${errorSource(model!.original, language)}, full model, not the downloaded build)`)}`,
  }
  const measured = options.speed
  let speed: Bar | undefined
  if (measured) {
    const date = new Date(measured.date).toLocaleDateString(language === 'de' ? 'de-DE' : 'en-US')
    speed = { value: speedScore(measured.secondsPer10), help: `${formatSpeed(measured.secondsPer10, language)}, ${options.here
      ? t('gemessen auf diesem Computer', 'measured on this computer')
      : t(`gemessen am ${date} mit satz ${measured.version} auf ${measured.machine}`, `measured on ${date} with satz ${measured.version} on ${measured.machine}`)}` }
  } else if (model) {
    speed = { value: model.speed, help: options.downloaded
      ? t('Geschätzt, noch nicht auf diesem Computer gemessen', 'Estimated, not measured on this computer yet')
      : t('Geschätzt. satz misst das Tempo nach dem Laden.', 'Estimated. satz measures the speed after downloading.') }
  }
  return { ...(accuracy ? { accuracy } : {}), ...(speed ? { speed } : {}) }
}

// MARK: - Language

/**
 * Whisper's language guess, between German and English only: its pick over
 * all its languages made the small models hear Dutch, and a model without a
 * language table failed every dictation. `logits` are the scores of the first
 * token after the start; a token the model does not have never wins.
 */
export function germanOrEnglish(logits: ArrayLike<number>, tokens: { de?: number | null; en?: number | null }): number | undefined {
  const usable = [tokens.de, tokens.en].filter((token): token is number => typeof token === 'number' && token >= 0 && token < logits.length)
  return usable.reduce<number | undefined>((best, next) => (best === undefined || logits[next] > logits[best] ? next : best), undefined)
}
