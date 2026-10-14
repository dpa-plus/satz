import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { localModel } from '../src/core/localModels'
import { isSteady } from '../src/core/speech'
import { decodeWAV, resample } from '../src/core/wav'
import { SherpaEngine, type SherpaAddon } from '../src/main/sherpaEngine'

// Codex's bug hunt, 14.10.2026, F01: Cohere and Qwen3 lost "Ja, genau." said
// before a long pause. The steady-noise check called the whole piece a fan,
// because the phrase was under a tenth of it. The cases are shared with the
// Mac (Tests/SatzKitTests/CodexFixSteadyNoiseTests.swift).

const rate = 16_000
const fixtures = path.join(__dirname, '..', '..', 'Tests', 'Fixtures', 'CodexFixSteadyNoise')

interface Noise { kind: 'hiss' | 'fan' | 'tone' | 'pink'; amplitude?: number; level?: number; seed?: number; hertz?: number; pole?: number }
interface Case { name: string; seconds: number; noise?: Noise; clip?: { at: number; gain?: number; until?: number }; taps?: number[]; steady: boolean }

const { cases } = JSON.parse(fs.readFileSync(path.join(fixtures, 'cases.json'), 'utf8')) as { cases: Case[] }
const phrase = decodeWAV(fs.readFileSync(path.join(fixtures, 'ja-genau.wav'))).samples
const named = (name: string) => cases.find(entry => entry.name.startsWith(name))!

/** Codex's generator, so the first cases are its fixtures and the Mac makes the same numbers. */
function white(count: number, seed: number): Float64Array {
  const out = new Float64Array(count)
  let x = seed
  for (let i = 0; i < count; i++) {
    x = (1664525 * x + 1013904223) >>> 0
    out[i] = (x / 4294967296) * 2 - 1
  }
  return out
}

function audio(entry: Case, withClip = true): Float32Array {
  const count = Math.round(entry.seconds * rate)
  const out = new Float32Array(count)
  const noise = entry.noise
  if (noise?.kind === 'hiss') white(count, noise.seed!).forEach((value, i) => { out[i] = value * noise.amplitude! })
  if (noise?.kind === 'fan' || noise?.kind === 'pink') {
    let low = 0
    const b = [0, 0, 0, 0, 0, 0, 0]
    const pink = (w: number) => {
      b[0] = 0.99886 * b[0] + w * 0.0555179; b[1] = 0.99332 * b[1] + w * 0.0750759; b[2] = 0.969 * b[2] + w * 0.153852
      b[3] = 0.8665 * b[3] + w * 0.3104856; b[4] = 0.55 * b[4] + w * 0.5329522; b[5] = -0.7616 * b[5] - w * 0.016898
      const value = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362
      b[6] = w * 0.115926
      return value
    }
    const shaped = white(count, noise.seed!).map(value => noise.kind === 'pink' ? pink(value) : (low = (noise.pole ?? 0.92) * low + value))
    const level = Math.sqrt(shaped.reduce((sum, value) => sum + value * value, 0) / count)
    shaped.forEach((value, i) => { out[i] = (value / level) * noise.level! })
  }
  for (const second of entry.taps ?? []) {
    const at = Math.floor(second * rate)
    for (let i = 0; i < 400 && at + i < count; i++) out[at + i] += 0.12 * Math.exp(-i / 100) * (Math.sin((2 * Math.PI * 180 * i) / rate) + 0.5 * Math.sin((2 * Math.PI * 2200 * i) / rate))
  }
  if (noise?.kind === 'tone') for (let i = 0; i < count; i++) out[i] = noise.amplitude! * Math.sin((2 * Math.PI * noise.hertz! * i) / rate)
  if (entry.clip && withClip) {
    const at = Math.round(entry.clip.at * rate)
    const length = entry.clip.until === undefined ? phrase.length : Math.floor(entry.clip.until * rate)
    for (let i = 0; i < length && at + i < count; i++) out[at + i] += phrase[i] * (entry.clip.gain ?? 1)
  }
  return out
}

test('Codex F01: a short phrase anywhere in a piece keeps it, and hiss, fans, rumble, pink noise, a hum, a pure tone and key taps are steady (the table the Mac reads too)', () => {
  assert.ok(cases.length >= 15)
  for (const entry of cases) assert.equal(isSteady(audio(entry), rate), entry.steady, entry.name)
})

/** Codex's 36 s recording: the phrase, the pause to 31 s, then a sentence (5 s of the speed clip read aloud). */
function recording(entry: Case, withClip = true): Float32Array {
  const { samples, sampleRate } = decodeWAV(fs.readFileSync(path.join(__dirname, '..', 'assets', 'speedtest.wav')))
  const out = new Float32Array(36 * rate)
  out.set(audio(entry, withClip))
  out.set(resample(samples, sampleRate).subarray(0, 5 * rate), 31 * rate)
  return out
}

/** What the recognizer writes for a piece: the phrase if it starts with it (said at 1 s), else the sentence. */
function says(piece: Float32Array): string {
  const said = piece.subarray(1.2 * rate, 1.5 * rate)
  return Math.sqrt(said.reduce((sum, value) => sum + value * value, 0) / said.length) > 0.02 ? 'Ja, genau.' : 'Die Lieferung kommt morgen um 10 Uhr.'
}

/** Cohere or Qwen3 with sherpa-onnx as a recorder: the seconds of each piece it was given. */
async function heard(id: string, samples: Float32Array): Promise<{ text: string; pieces: number[] }> {
  const pieces: number[] = []
  const addon: SherpaAddon = {
    async createOfflineRecognizerAsync(config) { return { config } },
    offlineRecognizerSetConfig() {},
    createOfflineStream() { return { samples: new Float32Array(0) } },
    offlineStreamSetOption() {},
    acceptWaveformOffline(stream, wave) { (stream as { samples: Float32Array }).samples = wave.samples },
    async decodeOfflineStreamAsync(_recognizer, stream) {
      const piece = (stream as { samples: Float32Array }).samples
      pieces.push(piece.length / rate)
      return JSON.stringify({ text: says(piece) })
    },
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-steady-'))
  try {
    for (const entry of localModel(id)!.sherpa!.files) {
      fs.mkdirSync(path.dirname(path.join(dir, id, entry.name)), { recursive: true })
      fs.writeFileSync(path.join(dir, id, entry.name), '')
    }
    const engine = new SherpaEngine(dir, () => {}, () => {}, undefined, () => addon)
    return { text: await engine.transcribe(samples, id, [], 'de'), pieces }
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
}

test('Codex F01: Cohere and Qwen3 hear the phrase before a long pause, and a piece of hiss alone is still never sent', async () => {
  for (const [id, fixture] of [['sherpa/cohere-transcribe', 'Codex F01, Cohere'], ['sherpa/qwen3-asr-0.6b', 'Codex F01, Qwen']]) {
    const both = await heard(id, recording(named(fixture)))
    assert.equal(both.text, 'Ja, genau. Die Lieferung kommt morgen um 10 Uhr.', id)
    assert.equal(both.pieces.length, 2, `${id}: ${JSON.stringify(both.pieces)}`)
    assert.ok(both.pieces[0] >= named(fixture).seconds, `${id}: the first piece holds the phrase and its pause`)
    // The same recording without the phrase: only the sentence is heard.
    const hiss = await heard(id, recording(named(fixture), false))
    assert.equal(hiss.text, 'Die Lieferung kommt morgen um 10 Uhr.', id)
    assert.equal(hiss.pieces.length, 1, `${id}: ${JSON.stringify(hiss.pieces)}`)
  }
})
