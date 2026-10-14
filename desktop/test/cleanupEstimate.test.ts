import assert from 'node:assert/strict'
import test from 'node:test'
import { systemPrompt } from '../src/core/cleanup'
import { addSample, averageChars, estimate, factsLine, measuredSeconds, menuTitle, modelFacts, promptChars, runDollars, smallDollars, tryLine, type Sample } from '../src/core/cleanupEstimate'

const close = (actual: number | undefined, expected: number, tolerance: number, what: string) =>
  assert.ok(actual !== undefined && Math.abs(actual - expected) <= tolerance, `${what}: ${actual} is not about ${expected}`)

test('the fixed example: Gemini 3.5 Flash-Lite on OpenRouter, "light", no vocabulary, 400 characters', () => {
  // By hand, from the spec's 5.1:
  // The prompt for "light" is 1,302 characters, its three examples with their
  // wrapping 437, and 40 more: 1,779 characters, ceil(1779 / 4.5) = 396 tokens.
  assert.equal(systemPrompt('light').length, 1302)
  assert.equal(promptChars('light', []), 1779)
  // The dictation: ceil(400 / 4.5) = 89 tokens; out 89 × 0.95 = 84.55; in 396 + 89 = 485.
  // Per dictation: (485 × 0.30 + 84.55 × 2.50) / 1e6 = 0.000356875 $.
  // 400 characters are 400 / 14 = 28.6 s of talking: 126 dictations an hour, 0.04497 $.
  // Seconds: 0.8 + (84.55 × 1 − 80) / 250 = 0.8182.
  const e = estimate({ provider: 'openrouter', model: 'google/gemini-3.5-flash-lite', level: 'light', vocabulary: [], avgChars: 400 })
  close(e.dollarsPerHour, 0.044966, 0.0005, 'dollars per hour')
  close(e.seconds, 0.8182, 0.005, 'seconds')
  assert.equal(e.measured, false)
  assert.equal(e.talkingSeconds, 30)
  assert.equal(menuTitle(e, 'de'), 'Gemini 3.5 Flash-Lite · Google · +0,8 s · 0,04 $ pro Stunde')
  assert.equal(menuTitle(e, 'en'), 'Gemini 3.5 Flash-Lite · Google · +0.8 s · $0.04 an hour')
  assert.equal(factsLine(e, 'de'), 'Etwa +0,8 s pro Diktat und 0,04 $ pro Stunde Sprechen, für Diktate von etwa 30 Sekunden. Schnell. Schreibt bei „Ausformuliert“ wenig um.')
  assert.equal(factsLine(e, 'en'), 'About +0.8 s per dictation and $0.04 per hour of talking, for dictations of about 30 seconds. Fast. Rewrites little at “Polished”.')
})

test('Claude counts 1.7 times the tokens: the price and the time grow with it', () => {
  const haiku = estimate({ provider: 'openrouter', model: 'anthropic/claude-haiku-5.5', level: 'light', vocabulary: [], avgChars: 400 })
  // (485 × 0.10 + 84.55 × 0.50) / 1e6 × 1.7 × 126 = 0.01944 $; 1.6 + (84.55 × 1.7 − 80) / 165 = 1.986 s.
  close(haiku.dollarsPerHour, 0.01944, 0.0002, 'dollars per hour')
  close(haiku.seconds, 1.986, 0.005, 'seconds')
  assert.equal(menuTitle(haiku, 'de'), 'Claude Haiku 5.5 · Anthropic · +2,0 s · 0,02 $ pro Stunde')
})

test('under a cent, free, and an unknown price', () => {
  // DeepSeek V4.1 Flash is just over a cent: (485 × 0.021 + 84.55 × 0.891) / 1e6 × 126 = 0.0108 $.
  assert.match(menuTitle(estimate({ provider: 'openrouter', model: 'deepseek/deepseek-v4.1-flash', level: 'light', vocabulary: [], avgChars: 400 }), 'de'), / · 0,01 \$ pro Stunde$/)
  const cheap = estimate({ provider: 'openrouter', model: 'deepseek/deepseek-v4.1-flash', level: 'light', vocabulary: [], avgChars: 400, livePrice: { input: 0.01, output: 0.05 } })
  assert.match(menuTitle(cheap, 'de'), / · unter 0,01 \$ pro Stunde$/)
  assert.match(menuTitle(cheap, 'en'), / · under \$0\.01 an hour$/)
  const ollama = estimate({ provider: 'ollama', model: 'qwen3.8:8b', level: 'light', vocabulary: [], avgChars: 400 })
  assert.equal(ollama.dollarsPerHour, 0)
  assert.equal(ollama.seconds, undefined)
  assert.equal(menuTitle(ollama, 'en'), 'qwen3.8:8b · Ollama · free')
  assert.equal(factsLine(ollama, 'de'), 'Zeit: noch nicht gemessen. Läuft auf diesem Computer, kostenlos. Kleine Modelle beantworten manchmal Fragen im Text; satz fügt dann das Original ein.')
  const custom = estimate({ provider: 'custom', model: 'm', level: 'light', vocabulary: [], avgChars: 400 })
  assert.equal(custom.dollarsPerHour, undefined)
  // The Mac's words for what is not known: the price is said to be unknown.
  assert.equal(factsLine(custom, 'en'), 'Time: not measured yet. Price unknown.')
  assert.equal(factsLine(custom, 'de'), 'Zeit: noch nicht gemessen. Preis unbekannt.')
})

test('the facts line where the time or the price is not known, in the Mac\'s words', () => {
  const run = (seconds: number): Sample => ({ seconds, date: '2026-10-14T10:00:00Z' })
  // Time known, price not: a typed OpenAI id (estimated: none; measured here).
  const measured = estimate({ provider: 'openai', model: 'gpt-7-typed', level: 'light', vocabulary: [], avgChars: 400, samples: [run(1.2), run(1.2)] })
  assert.equal(factsLine(measured, 'de'), '+1,2 s pro Diktat, gemessen auf diesem Computer. Preis unbekannt.')
  assert.equal(factsLine(measured, 'en'), '+1.2 s per dictation, measured on this computer. Price unknown.')
  // Azure: a time from the catalog's typed row, the price depends on the deployment, and no "for dictations of" clause.
  const azure = estimate({ provider: 'azure', model: 'my-deployment', level: 'light', vocabulary: [], avgChars: 400 })
  assert.equal(factsLine(azure, 'de'), 'Etwa +1,5 s pro Diktat. Preis je nach Bereitstellung.')
  assert.equal(factsLine(azure, 'en'), 'About +1.5 s per dictation. Price depends on the deployment.')
  // Price known, time not: the price alone, as a sentence of its own; under a cent it begins "Unter".
  const typed = estimate({ provider: 'openrouter', model: 'new/model', level: 'light', vocabulary: [], avgChars: 400, livePrice: { input: 0.01, output: 0.05 } })
  assert.equal(factsLine(typed, 'de'), 'Zeit: noch nicht gemessen. Unter 0,01 $ pro Stunde Sprechen.')
  assert.equal(factsLine(typed, 'en'), 'Time: not measured yet. Under $0.01 per hour of talking.')
  // Free with a time (a local run, measured): no price words, no "free" of our own; the note says it.
  const local = estimate({ provider: 'ollama', model: 'gemma4:4b', level: 'light', vocabulary: [], avgChars: 400, samples: [run(0.9), run(0.9)] })
  assert.equal(factsLine(local, 'en'), '+0.9 s per dictation, measured on this computer. Runs on this computer, free. Small models sometimes answer questions in the text; satz then pastes the original.')
  // A model OpenRouter lists at 0: free, with its time, and nothing about a price.
  const free = estimate({ provider: 'openrouter', model: 'google/gemini-3.5-flash-lite', level: 'light', vocabulary: [], avgChars: 400, livePrice: { input: 0, output: 0 } })
  assert.equal(free.free, true)
  assert.match(menuTitle(free, 'en'), / · free$/)
  assert.match(factsLine(free, 'en'), /^About \+0\.8 s per dictation\. Fast\./)
})

test('the maker in the menu: the model\'s, else the provider\'s name in the language shown; Azure is Microsoft', () => {
  const title = (provider: Parameters<typeof estimate>[0]['provider'], model: string, language: 'de' | 'en') =>
    menuTitle(estimate({ provider, model, level: 'light', vocabulary: [], avgChars: 400 }), language)
  assert.equal(title('custom', 'm', 'de'), 'm · Eigener')
  assert.equal(title('custom', 'm', 'en'), 'm · Custom')
  assert.equal(title('azure', 'my-deployment', 'en'), 'my-deployment · Microsoft · +1.5 s')
  assert.equal(title('openrouter', 'acme/model-1', 'en'), 'acme/model-1 · acme')
  assert.equal(title('lmstudio', 'qwen-local', 'en'), 'qwen-local · LM Studio · free')
  assert.equal(title('google', 'gemini-9', 'en'), 'gemini-9 · Google')
})

test('Claude\'s tokenizer counts more wherever the id is Claude\'s, also when it is typed', () => {
  assert.equal(modelFacts('openrouter', 'anthropic/claude-haiku-9', { input: 0.1, output: 0.5 }).tokenFactor, 1.7)
  assert.equal(modelFacts('anthropic', 'claude-haiku-9').tokenFactor, 1.7)
  assert.equal(modelFacts('openrouter', 'openai/gpt-9').tokenFactor, 1)
  assert.equal(modelFacts('openrouter', 'anthropic/claude-haiku-5.5').tokenFactor, 1.7, 'the catalog\'s')
  const dear = estimate({ provider: 'openrouter', model: 'anthropic/claude-haiku-9', level: 'light', vocabulary: [], avgChars: 400, livePrice: { input: 0.1, output: 0.5 } })
  const same = estimate({ provider: 'openrouter', model: 'openai/gpt-9', level: 'light', vocabulary: [], avgChars: 400, livePrice: { input: 0.1, output: 0.5 } })
  close(dear.dollarsPerHour! / same.dollarsPerHour!, 1.7, 1e-9, 'the same price at Claude\'s count')
})

test('characters are counted as Unicode scalars: the length of a dictation and of the prompt', () => {
  assert.equal(averageChars([{ text: '😀'.repeat(300) }, ...[300, 300, 300, 300].map(n => ({ text: 'x'.repeat(n) }))]), 300)
  assert.equal(promptChars('custom', [], '😀'.repeat(10)), promptChars('custom', [], 'x'.repeat(10)))
})

test('an Azure deployment is priced like the OpenAI model its name contains, else "depends on the deployment"', () => {
  const luna = estimate({ provider: 'azure', model: 'prod-gpt-6-luna', level: 'light', vocabulary: [], avgChars: 400 })
  assert.ok(luna.dollarsPerHour! > 0)
  close(luna.seconds, 1.5, 0.6, 'seconds')
  assert.deepEqual(modelFacts('azure', 'gpt-6.1-sol-eu').price, { input: 2, output: 10 })
  const unknown = estimate({ provider: 'azure', model: 'my-deployment', level: 'light', vocabulary: [], avgChars: 400 })
  assert.equal(unknown.dollarsPerHour, undefined)
  assert.match(factsLine(unknown, 'de'), /Preis je nach Bereitstellung\.$/)
  assert.match(factsLine(unknown, 'en'), /Price depends on the deployment\.$/)
})

test('OpenRouter\'s live price wins over the catalog, and a typed id gets its price only from there', () => {
  const live = estimate({ provider: 'openrouter', model: 'google/gemini-3.5-flash-lite', level: 'light', vocabulary: [], avgChars: 400, livePrice: { input: 0.6, output: 5 } })
  close(live.dollarsPerHour, 0.044966 * 2, 0.001, 'twice the price')
  const typed = estimate({ provider: 'openrouter', model: 'new/model', level: 'light', vocabulary: [], avgChars: 400 })
  assert.equal(typed.dollarsPerHour, undefined)
  const typedLive = estimate({ provider: 'openrouter', model: 'new/model', level: 'light', vocabulary: [], avgChars: 400, livePrice: { input: 0.3, output: 2.5 } })
  close(typedLive.dollarsPerHour, 0.044966, 0.0005, 'live')
  assert.equal(factsLine(typedLive, 'en'), 'Time: not measured yet. $0.04 per hour of talking.')
})

test('measured: the median once there are two, said as measured; the last 20 kept', () => {
  const run = (seconds: number): Sample => ({ seconds, date: '2026-10-14T10:00:00Z' })
  assert.equal(measuredSeconds(undefined), undefined)
  assert.equal(measuredSeconds([run(3)]), undefined, 'one run could have loaded the model')
  assert.equal(measuredSeconds([run(0.9), run(1.3)]), 1.1)
  assert.equal(measuredSeconds([run(5), run(0.8), run(0.9)]), 0.9)
  let samples: Record<string, Sample[]> = {}
  for (let i = 1; i <= 25; i++) samples = addSample(samples, 'openrouter|m', run(i))
  assert.equal(samples['openrouter|m'].length, 20)
  assert.equal(samples['openrouter|m'][0].seconds, 6, 'the oldest went')
  const e = estimate({ provider: 'openrouter', model: 'google/gemini-3.5-flash-lite', level: 'light', vocabulary: [], avgChars: 400, samples: [run(0.9), run(0.9)] })
  assert.equal(e.measured, true)
  assert.equal(factsLine(e, 'de'), '+0,9 s pro Diktat, gemessen auf diesem Computer, und 0,04 $ pro Stunde Sprechen. Schnell. Schreibt bei „Ausformuliert“ wenig um.')
  assert.equal(factsLine(e, 'en'), '+0.9 s per dictation, measured on this computer, and $0.04 per hour of talking. Fast. Rewrites little at “Polished”.')
})

test('how long the user\'s dictations are: the median of the last 50, as said, once there are five', () => {
  assert.equal(averageChars([]), 400)
  assert.equal(averageChars([{ text: 'x'.repeat(100) }]), 400)
  const history = [100, 200, 300, 50, 700].map(n => ({ text: 'x'.repeat(n) }))
  assert.equal(averageChars(history), 200)
  assert.equal(averageChars([{ text: 'short', original: 'x'.repeat(900) }, ...history.slice(1)]), 300, 'the original, before cleanup')
  const many = Array.from({ length: 80 }, (_, i) => ({ text: 'x'.repeat(i < 50 ? 10 : 1000) }))
  assert.equal(averageChars(many), 10, 'only the newest 50')
  const e = estimate({ provider: 'openrouter', model: 'google/gemini-3.5-flash-lite', level: 'light', vocabulary: [], avgChars: 1400 })
  assert.equal(e.talkingSeconds, 100)
})

test('a run\'s cost: OpenRouter says it, elsewhere the tokens at the price', () => {
  assert.equal(runDollars({ dollars: 0.0002, inputTokens: 1, outputTokens: 1 }, { input: 1, output: 1 }), 0.0002)
  close(runDollars({ inputTokens: 1000, outputTokens: 100 }, { input: 0.3, output: 2.5 }), 0.00055, 1e-9, 'tokens at the price')
  assert.equal(runDollars({ inputTokens: 1000 }, { input: 0.3, output: 2.5 }), undefined)
  assert.equal(runDollars({ inputTokens: 1000, outputTokens: 100 }, undefined), undefined)
})

test('the line under a try: its time, and its cost where known, in up to four decimals and without the model\'s name', () => {
  assert.equal(tryLine(0.72, 0.0001, 'de'), '0,7 s · 0,0001 $')
  assert.equal(tryLine(0.72, 0.0001, 'en'), '0.7 s · $0.0001')
  assert.equal(tryLine(2.04, undefined, 'de'), '2,0 s')
  assert.equal(tryLine(0.8, 0.000123, 'de'), '0,8 s · 0,0001 $')
  assert.equal(tryLine(0.8, 0.0002, 'de'), '0,8 s · 0,0002 $')
  assert.equal(tryLine(1.4, 0.0123, 'de'), '1,4 s · 0,01 $', 'from a cent on, two decimals')
  assert.equal(tryLine(1.4, 1.5, 'en'), '1.4 s · $1.50')
})

test('a cost under a hundredth of a cent says so, and half of it still rounds to 0,0001 (0.00005 is a hair under in binary)', () => {
  assert.equal(smallDollars(0.00004, 'de'), 'unter 0,0001 $')
  assert.equal(smallDollars(0.00004, 'en'), 'under $0.0001')
  assert.equal(smallDollars(0, 'de'), '0 $', 'what cost nothing')
  assert.equal(smallDollars(0, 'en'), '$0')
  assert.equal(smallDollars(0.00005, 'de'), '0,0001 $')
  assert.equal(smallDollars(0.000049999, 'de'), 'unter 0,0001 $')
  assert.equal(smallDollars(0.0099, 'de'), '0,0099 $')
  // A regular space before the dollar sign, not a no-break one: the same as the model menu's prices.
  assert.doesNotMatch(smallDollars(0.0002, 'de'), /\u00a0/)
  assert.equal(tryLine(0.5, 0.05, 'de'), '0,5 s · 0,05 $')
})
