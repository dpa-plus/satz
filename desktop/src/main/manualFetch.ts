import type { EventEmitter } from 'node:events'
import type { ManualFetch } from '../core/redirect'

/**
 * Electron's network stack (the system proxy, the certificate store) for a
 * request that must not follow a redirect by itself. net.fetch cannot do
 * that: with redirect 'manual' it cancels the request instead of handing the
 * 3xx answer back, so the address in it is lost, and left to follow, it
 * forwards the Authorization header to another origin. net.request can stop
 * at the redirect: its 'redirect' event arrives with the new address, and
 * without followRedirect() the request ends there. That answer becomes the
 * 3xx Response that core/redirect.ts decides about; nothing is sent to the
 * address in it from here.
 *
 * Written against what the app needs (a string or form body, an answer
 * read whole), so a request and a response are what net.request has, not
 * the whole of fetch.
 */
export interface RequestLike extends EventEmitter {
  setHeader(name: string, value: string): void
  end(chunk?: Buffer): void
  abort(): void
}
export interface IncomingLike extends EventEmitter {
  statusCode: number
  headers: Record<string, string | string[]>
}

/** What a canceled call rejects with: the name every fetch uses (core/transcriber.ts, abortError). */
const aborted = () => new DOMException('This operation was aborted', 'AbortError')

/** @param open Electron's `options => net.request(options)`; a stand-in in the tests. */
export function makeManualFetch(open: (options: { method: string; url: string; redirect: 'manual' }) => RequestLike): ManualFetch {
  return async (url, init) => {
    const headers = new Headers(init.headers)
    let body: Buffer | undefined
    if (init.body !== undefined) {
      // A form body becomes its bytes and its type with the boundary, the way fetch would send it.
      const encoded = new Response(init.body)
      const type = encoded.headers.get('content-type')
      if (type && !headers.has('content-type')) headers.set('content-type', type)
      body = Buffer.from(await encoded.arrayBuffer())
    }
    const signal = init.signal
    if (signal?.aborted) throw aborted()

    return new Promise<Response>((resolve, reject) => {
      let settled = false
      let request: RequestLike | undefined
      const finish = (settle: () => void) => {
        if (settled) return
        settled = true
        signal?.removeEventListener('abort', cancel)
        settle()
      }
      const cancel = () => finish(() => { request?.abort(); reject(aborted()) })
      signal?.addEventListener('abort', cancel, { once: true })
      try {
        request = open({ method: init.method ?? 'GET', url, redirect: 'manual' })
        headers.forEach((value, name) => request?.setHeader(name, value))
        // A redirect ends the request here: the 3xx answer with where it points, which is all that is read of it.
        request.on('redirect', (status: number, _method: string, location: string) => {
          finish(() => { resolve(new Response(null, { status, headers: { location } })); request?.abort() })
        })
        request.on('response', (response: IncomingLike) => {
          const chunks: Buffer[] = []
          response.on('data', (chunk: Buffer) => chunks.push(chunk))
          response.on('end', () => finish(() => {
            const answer = new Headers()
            for (const [name, value] of Object.entries(response.headers)) for (const one of Array.isArray(value) ? value : [value]) answer.append(name, one)
            resolve(new Response([204, 205, 304].includes(response.statusCode) ? null : Buffer.concat(chunks), { status: response.statusCode, headers: answer }))
          }))
          response.on('aborted', () => finish(() => reject(new Error('The connection was closed before the answer was complete'))))
          response.on('error', (error: Error) => finish(() => reject(error)))
        })
        request.on('error', (error: Error) => finish(() => reject(error)))
        request.end(body)
      } catch (error) {
        finish(() => reject(error))
      }
    })
  }
}
