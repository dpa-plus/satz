/**
 * Requests that carry a key go to the address the user chose and nowhere
 * else. A fetch that follows redirects by itself does not keep to that:
 * Electron's net.fetch forwards the Authorization header to the other origin,
 * and Node's fetch forwards a header of its own (x-goog-api-key,
 * Ocp-Apim-Subscription-Key) and the audio. Refusing every redirect
 * ('error') broke the ordinary one, though: a server that answers
 * ".../transcriptions" with a 307 to ".../transcriptions/". So the redirect
 * is looked at here: followed when it stays on the origin it started at,
 * refused when it leaves, and the second request never leaves.
 */

/** What the fetcher given here must do: hand a 3xx answer back as it is instead of following it. */
export interface ManualInit {
  method?: string
  headers?: Record<string, string>
  body?: BodyInit
  signal?: AbortSignal
}
export type ManualFetch = (url: string, init: ManualInit & { redirect: 'manual' }) => Promise<Response>

/** How many redirects one request may follow. */
export const MAX_REDIRECTS = 3

/** Why a redirect was not followed, in words for a log. */
export class RedirectRefused extends Error {
  constructor(detail: string) {
    super(detail)
    this.name = 'RedirectRefused'
  }
}

/**
 * Sends the request and follows its redirects as long as they stay on the
 * origin of `url`, at most MAX_REDIRECTS of them, with the same headers. A
 * redirect to another origin, one with no usable target, and a fourth one
 * reject with RedirectRefused, and nothing is sent to where it pointed.
 *
 * 301 and 302 repeat the request, body included (fetch would turn the POST
 * into a GET without the audio, which no transcription endpoint answers);
 * 307 and 308 say the same; 303 is the one that asks for a GET.
 */
export async function fetchWithinOrigin(fetcher: ManualFetch, url: string, init: ManualInit): Promise<Response> {
  const origin = new URL(url).origin
  let current = url
  let request = init
  for (let followed = 0; ; followed++) {
    const response = await fetcher(current, { ...request, redirect: 'manual' })
    if (![301, 302, 303, 307, 308].includes(response.status)) return response
    // Nothing of it is read, so the connection is not held up for it.
    void response.body?.cancel().catch(() => {})
    const location = response.headers.get('location')
    if (!location) throw new RedirectRefused('the redirect has no address')
    let target: URL
    try { target = new URL(location, current) } catch { throw new RedirectRefused('the redirect has no usable address') }
    if (target.origin !== origin) throw new RedirectRefused('the address answered with a redirect to another origin')
    if (followed >= MAX_REDIRECTS) throw new RedirectRefused(`the address redirected more than ${MAX_REDIRECTS} times`)
    current = target.href
    if (response.status === 303) request = asGet(request)
  }
}

/** The same request as a GET: no body, and so no type for it. */
function asGet({ body: _body, headers = {}, ...rest }: ManualInit): ManualInit {
  return { ...rest, method: 'GET', headers: Object.fromEntries(Object.entries(headers).filter(([name]) => name.toLowerCase() !== 'content-type')) }
}
