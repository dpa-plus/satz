import assert from 'node:assert/strict'
import { test } from 'node:test'
import { addressRefusal, customAddress, needsMessage, providerNeeds, switchRow, type Need } from '../src/core/browse'
import { allowsAddress, isOnOwnNetwork } from '../src/core/address'
import { microsoftHost } from '../src/core/transcriber'

/**
 * Where a request that carries a key may go, for Custom's address and
 * Microsoft's own address: https anywhere, plain http only on the user's own
 * network (this computer, a private or link-local address, a name without a
 * dot, .local, .lan, .home.arpa, .internal). The Mac app has the same table
 * (ProviderAddress); a change here is a change there. Before, only
 * localhost, 127.0.0.1 and [::1] were allowed, and the page said "Erst die
 * Adresse eintragen" for an address that was typed.
 */

const own = [
  // This computer.
  'http://localhost:9000/v1', 'http://127.0.0.1:8080/v1', 'http://127.5.6.7/v1', 'http://[::1]:8080/v1',
  // Private and link-local IPv4: the edges of each range.
  'http://10.0.0.5/v1', 'http://10.255.255.255/v1', 'http://172.16.0.1/v1', 'http://172.31.255.255/v1', 'http://192.168.1.20:11434/v1', 'http://169.254.10.10/v1',
  // Unique local and link-local IPv6.
  'http://[fd00::1]/v1', 'http://[fc00::1]/v1', 'http://[fdff:ffff::1]/v1', 'http://[fe80::1]/v1', 'http://[febf::1]/v1',
  // A name without a dot, and the names that only exist inside a network.
  'http://nas:8000/v1', 'http://whisper:9000', 'http://whisper.local:9000', 'http://box.lan/v1', 'http://x.home.arpa/v1', 'http://svc.internal/v1', 'http://a.b.local/v1',
  // The scheme and the host are not case sensitive.
  'HTTP://NAS.LOCAL/v1', ' http://192.168.1.20:11434/v1  ',
]

const elsewhere = [
  'http://example.com/v1', 'http://api.openai.com/v1', 'http://8.8.8.8/v1', 'http://[2001:db8::1]/v1',
  // Just outside each range.
  'http://172.15.255.255/v1', 'http://172.32.0.1/v1', 'http://192.169.0.1/v1', 'http://169.253.0.1/v1', 'http://169.255.0.1/v1', 'http://11.0.0.1/v1', 'http://0.0.0.0/v1', 'http://100.64.0.1/v1',
  'http://[fec0::1]/v1', 'http://[fbff::1]/v1', 'http://[fe7f::1]/v1', 'http://[::]/v1', 'http://[::ffff:127.0.0.1]/v1',
  // 134744072 is 8.8.8.8 to the URL parser, and so to the network stack.
  'http://134744072/v1', 'http://0x08080808/v1',
  // A private suffix in the middle of a public name is a public name.
  'http://nas.local.example.com/v1', 'http://local.example.com/v1', 'http://x.internal.evil.com/v1', 'http://foo.localhost/v1',
]

const noAddress = [
  'ftp://nas/v1', 'ftp://example.com/v1', 'file:///etc/passwd', 'ws://nas/v1', 'javascript:alert(1)', 'data:text/plain,x',
  '//nas/v1', '//example.com/v1', 'nas/v1', 'nas:8000/v1', 'example.com/v1', 'https://', 'http://', 'https:///', '', '   ',
]

test('Custom: https goes anywhere, http only on the own network, and the address sent is the one that was checked', () => {
  for (const address of own) assert.equal(customAddress(address), address.trim(), address)
  for (const address of ['https://example.com/v1', 'HTTPS://Example.com/v1', 'https://192.168.1.5/v1', 'https://8.8.8.8/v1', 'https://nas/v1', 'https://localhost/v1', ' https://api.openai.com/v1 ']) {
    assert.equal(customAddress(address), address.trim(), address)
  }
  for (const address of [...elsewhere, ...noAddress]) assert.equal(customAddress(address), null, address)
  // A preferences file edited by hand may hold anything here.
  for (const odd of [undefined, null, 5, {}, []]) assert.equal(customAddress(odd as never), null)
})

test('the rule on host names alone: IPv6 in brackets as the URL parser writes it, names in any case', () => {
  for (const host of ['localhost', 'LOCALHOST', '127.0.0.1', '[::1]', '::1', '[FD12:3456::1]', '10.1.2.3', 'nas', 'NAS', 'box.LAN', 'a-b_c.local']) assert.equal(isOnOwnNetwork(host), true, host)
  for (const host of ['', 'example.com', '8.8.8.8', '1.2.3', '010.0.0.1', '127.1', '300.1.1.1', '[2001:db8::1]', 'local.com', '12345', '0x7f000001', 'a b.local', '.local', 'nas.']) assert.equal(isOnOwnNetwork(host), false, host)
  assert.equal(allowsAddress(new URL('http://nas:8000/')), true)
  assert.equal(allowsAddress(new URL('https://example.com/')), true)
  assert.equal(allowsAddress(new URL('http://example.com/')), false)
  assert.equal(allowsAddress(new URL('ftp://nas/')), false)
})

test('Microsoft\'s own address follows the same rule, and "//host" is no address', () => {
  assert.equal(microsoftHost('eastus', 'https://my-speech.cognitiveservices.azure.com/speechtotext/x?y=1'), 'https://my-speech.cognitiveservices.azure.com')
  // No scheme: https.
  assert.equal(microsoftHost('eastus', 'my-speech.cognitiveservices.azure.com'), 'https://my-speech.cognitiveservices.azure.com')
  for (const address of own.map(address => address.trim())) assert.equal(microsoftHost('eastus', address), new URL(address).origin, address)
  for (const address of [...elsewhere, 'ftp://nas/x', 'file:///etc/passwd', '//nas', '//example.com/x', '\\\\nas\\share', 'https://']) assert.equal(microsoftHost('eastus', address), null, address)
  // Empty: the region decides.
  assert.equal(microsoftHost('eastus', '  '), 'https://eastus.api.cognitive.microsoft.com')
  assert.equal(microsoftHost('eastus', undefined), 'https://eastus.api.cognitive.microsoft.com')
})

const facts = { hasKey: true, customBaseURL: '', model: 'm', microsoftRegion: 'northeurope', microsoftEndpoint: '' }

test('an address that is typed and refused is told apart from one not typed yet, for Custom and for Microsoft', () => {
  assert.deepEqual(providerNeeds('custom', { ...facts, customBaseURL: '' }), ['address'])
  assert.deepEqual(providerNeeds('custom', { ...facts, customBaseURL: '   ' }), ['address'])
  assert.deepEqual(providerNeeds('custom', { ...facts, customBaseURL: 'http://example.com/v1' }), ['addressRefused'])
  assert.deepEqual(providerNeeds('custom', { ...facts, customBaseURL: 'ftp://nas/v1' }), ['addressRefused'])
  assert.deepEqual(providerNeeds('custom', { ...facts, customBaseURL: 'http://192.168.1.20:11434/v1' }), [])
  assert.deepEqual(providerNeeds('custom', { ...facts, hasKey: false, customBaseURL: 'http://example.com/v1', model: '' }), ['key', 'addressRefused', 'model'])
  assert.deepEqual(providerNeeds('microsoft', { ...facts, microsoftEndpoint: 'http://speech.example.com' }), ['addressRefused'])
  assert.deepEqual(providerNeeds('microsoft', { ...facts, microsoftEndpoint: 'http://speech.local:9000' }), [])
  // An empty own address with a region that cannot be one is the region that is missing.
  assert.deepEqual(providerNeeds('microsoft', { ...facts, microsoftRegion: 'east us' }), ['region'])
})

test('the page says why an address was refused, in both languages, and keeps the old words for an empty field', () => {
  assert.equal(addressRefusal('de'), 'Diese Adresse geht nicht: https, oder http nur im eigenen Netz.')
  assert.equal(addressRefusal('en'), 'This address won\'t work: https, or http only on your own network.')
  assert.equal(needsMessage(['addressRefused'], 'de'), 'Diese Adresse geht nicht: https, oder http nur im eigenen Netz.')
  assert.equal(needsMessage(['addressRefused'], 'en'), 'This address won\'t work: https, or http only on your own network.')
  // Not typed yet: as before.
  assert.equal(needsMessage(['address'], 'de'), 'Erst die Adresse eintragen.')
  assert.equal(needsMessage(['address'], 'en'), 'Enter the address first.')
  // What else is still to fill in comes first, then the reason.
  assert.equal(needsMessage(['key', 'addressRefused'], 'de'), 'Erst den Schlüssel eintragen. Diese Adresse geht nicht: https, oder http nur im eigenen Netz.')
  assert.equal(needsMessage(['key', 'addressRefused', 'model'], 'en'), 'Enter the key and model first. This address won\'t work: https, or http only on your own network.')
  assert.deepEqual(switchRow('custom', 'openrouter', 'de', ['addressRefused']), { text: 'Diktate gehen an OpenRouter. Diese Adresse geht nicht: https, oder http nur im eigenen Netz.', button: null })
  assert.deepEqual(switchRow('custom', 'openrouter', 'en', ['address']), { text: 'Dictation goes to OpenRouter. Enter the address first.', button: null })
  for (const needs of [['addressRefused'], ['key', 'addressRefused', 'model'], ['region']] as Need[][]) {
    for (const language of ['de', 'en'] as const) assert.doesNotMatch(`${needsMessage(needs, language)} ${switchRow('custom', 'groq', language, needs)?.text}`, /—/)
  }
})
