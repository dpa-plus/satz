/**
 * Where a request that carries a key may go: https to any host, plain http
 * only to an address on the user's own network, where nobody on the way can
 * read it. The key travels with the audio, so a typed "http://example.com/v1"
 * is refused, and "http://192.168.1.20:8000/v1" (a Whisper server at home) is
 * not. One rule for Custom's address and Microsoft's own address, and the
 * same one as the Mac app's (ProviderAddress in SettingsRules.swift): the two
 * lists are meant to say the same. browse.ts re-exports it.
 *
 * Judged from the spelling alone, on the host the URL parser hands over (it
 * has already turned "127.1" or "0x7f.1" into 127.0.0.1, and "134744072" into
 * 8.8.8.8, which is the address the request will go to): no name is looked
 * up, so what DNS would answer never decides.
 */

/** Names that only mean something inside a network. "nas.local.example.com" ends differently and is not one. */
const privateSuffixes = ['.local', '.lan', '.home.arpa', '.internal']

/** Letters, digits, hyphen and underscore, and something of them. */
const isName = (label: string) => /^[a-z0-9_-]+$/.test(label)

/** All digits or "0x…": a number that some resolvers read as an IPv4 address. */
const isNumber = (label: string) => /^[0-9]+$/.test(label) || /^0x[0-9a-f]*$/.test(label)

/** The four numbers of a dotted IPv4 address, in its canonical spelling only; null for anything else. */
function octets(host: string): number[] | null {
  const match = /^(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})$/.exec(host)
  const numbers = match ? match.slice(1).map(Number) : []
  return numbers.length === 4 && numbers.every(number => number <= 255) ? numbers : null
}

/** 127/8 is all of this computer, 10/8, 172.16/12, 192.168/16 and 169.254/16 are private or link-local. */
function ownIPv4([a, b]: number[]): boolean {
  return a === 127 || a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 169 && b === 254)
}

/** ::1, fc00::/7 (unique local) and fe80::/10 (link-local). `address` is bare and in the URL parser's compressed, lowercase spelling. */
function ownIPv6(address: string): boolean {
  if (address === '::1') return true
  const first = address.split(':')[0]
  if (!/^[0-9a-f]{1,4}$/.test(first)) return false
  const group = parseInt(first, 16)
  return (group & 0xfe00) === 0xfc00 || (group & 0xffc0) === 0xfe80
}

/**
 * Whether plain http may go to `hostname` (a URL's, so an IPv6 address comes
 * in brackets): this computer, a private or link-local address, a host name
 * without a dot ("nas"), or a name under .local, .lan, .home.arpa or .internal.
 */
export function isOnOwnNetwork(hostname: string): boolean {
  let host = hostname.toLowerCase()
  if (host.startsWith('[') && host.endsWith(']')) host = host.slice(1, -1)
  if (!host) return false
  if (host.includes(':')) return ownIPv6(host)
  if (host === 'localhost') return true
  const numbers = octets(host)
  if (numbers) return ownIPv4(numbers)
  // No dot: a name of the network the computer is on, resolved by its search
  // domain or mDNS. A number is not a name: it is an address in disguise.
  if (!host.includes('.')) return isName(host) && !isNumber(host)
  for (const suffix of privateSuffixes) {
    if (host.endsWith(suffix) && host.slice(0, -suffix.length).split('.').every(isName)) return true
  }
  return false
}

/** https with a host, or http with a host on the user's own network. Everything else (ftp:, file:, a missing host) is no address. */
export function allowsAddress(url: URL): boolean {
  if (!url.hostname) return false
  return url.protocol === 'https:' || (url.protocol === 'http:' && isOnOwnNetwork(url.hostname))
}
