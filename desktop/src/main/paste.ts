import { clipboard, ClipboardItem } from 'electron'
import { execFile } from 'node:child_process'
import fs from 'node:fs'
import { de } from '../core/language'
import { ClipboardHandback, registerHandback, type ClipboardPort } from './clipboardHandback'

/**
 * Puts the transcript where the user was typing: on the clipboard, then
 * Ctrl+V. The card never takes the keyboard, so the app the user was in still
 * has it. The clipboard is handed back afterwards, in every form it held,
 * unless the user wants the transcript to stay there.
 *
 * Linux under Wayland lets no app send keystrokes to other apps; there satz
 * uses ydotool when it is installed, and otherwise leaves the text on the
 * clipboard and says so.
 */
export type KeyTap = () => void

/**
 * What the clipboard holds right now. Another app has it open for a moment
 * while it copies, and the read is refused then: asked again a few times
 * before it counts as unreadable. Rejects when it stays unreadable, which is
 * not the same as empty.
 */
async function readItems(): Promise<ClipboardItem[]> {
  let failure: unknown
  for (const wait of [0, 60, 180]) {
    if (wait) await new Promise(resolve => setTimeout(resolve, wait))
    try { return await clipboard.read() } catch (error) { failure = error }
  }
  throw failure
}

/** Every item on the clipboard, in every form, read out now (the live items change with the clipboard). Rejects when it cannot be read. */
async function save(): Promise<ClipboardItem[]> {
  const items = await readItems()
  const copies: ClipboardItem[] = []
  for (const item of items) {
    const payload: Record<string, string | Blob | Electron.ClipboardBookmark> = {}
    for (const type of item.types) {
      try { payload[type] = await item.getType(type) } catch { /* that form is gone already */ }
    }
    if (Object.keys(payload).length > 0) copies.push(new ClipboardItem(payload as never))
    // Something was there and none of it could be read: not an empty clipboard.
    else if (item.types.length > 0) throw new Error('none of the forms on the clipboard could be read')
  }
  return copies
}

/** Electron's clipboard, for the hand-back (clipboardHandback.ts). */
const system: ClipboardPort<ClipboardItem[]> = {
  save,
  isEmpty: items => items.length === 0,
  restore: items => clipboard.write(items).catch(() => {}),
  clear: () => clipboard.clear(),
  writeText: text => Promise.resolve(clipboard.writeText(text)),
  holdsOnly: async text => {
    // Unreadable: not known to hold just the transcript, so it is left alone.
    const items = await readItems().catch(() => [] as ClipboardItem[])
    const onlyText = items.length === 1 && items[0].types.every(type => type.startsWith('text/plain'))
    return onlyText && (await clipboard.readText()) === text
  },
}

/**
 * How long after the keystroke the clipboard comes back: a second, as on the
 * Mac. At 600 ms a busy app (Word, a remote desktop session, a VM) took
 * Ctrl+V after the old clipboard was back and pasted that instead of the
 * dictation, which then was neither on the screen nor on the clipboard.
 */
const PASTE_TAKES = 1000
const handback = new ClipboardHandback(system, PASTE_TAKES)
registerHandback(handback)

export const isWayland = () => process.platform === 'linux' && (process.env.XDG_SESSION_TYPE === 'wayland' || !!process.env.WAYLAND_DISPLAY)

function which(command: string): Promise<boolean> {
  return new Promise(resolve => execFile('sh', ['-c', `command -v ${command}`], error => resolve(!error)))
}

/** Where ydotoold listens: its own default depends on who started it, so look. */
function ydotoolSocket(): string | undefined {
  if (process.env.YDOTOOL_SOCKET) return process.env.YDOTOOL_SOCKET
  const candidates = [`${process.env.XDG_RUNTIME_DIR ?? ''}/.ydotool_socket`, '/tmp/.ydotool_socket', '/run/ydotoold/socket']
  return candidates.find(path => { try { return fs.statSync(path).isSocket() } catch { return false } })
}

function ydotoolPaste(log?: (message: string) => void): Promise<boolean> {
  const socket = ydotoolSocket()
  const env = socket ? { ...process.env, YDOTOOL_SOCKET: socket } : process.env
  // Left Ctrl (29) down, V (47) down and up, Ctrl up: Linux input event codes.
  // A ydotoold that does not answer must not hold up every paste after this one.
  return new Promise(resolve => execFile('ydotool', ['key', '29:1', '47:1', '47:0', '29:0'], { env, timeout: 5000 }, (error, _out, stderr) => {
    if (error) log?.(`ydotool: ${(stderr || error.message).trim().split('\n')[0]}`)
    resolve(!error)
  }))
}

export async function deliver(text: string, keyTap: KeyTap, keepsOnClipboard: boolean, log?: (message: string) => void): Promise<{ pasted: boolean; reason?: string }> {
  if (!text) return { pasted: true }
  // Handed back once the paste has been taken, and only while the clipboard
  // still holds just the transcript: something copied in the meantime stays,
  // also the same words copied with their formatting. An empty clipboard
  // becomes empty again. Overlapping pastes give back the clipboard from
  // before all of them (clipboardHandback.ts).
  return handback.deliver(text, async (): Promise<{ pasted: boolean; reason?: string }> => {
    if (isWayland()) {
      if ((await which('ydotool')) && (await ydotoolPaste(log))) return { pasted: true }
      // Leave the transcript on the clipboard: it is the fallback.
      return { pasted: false, reason: de('Auf der Zwischenablage. Mit Strg+V einfügen.', 'On the clipboard. Paste with Ctrl+V.') }
    }
    try {
      keyTap()
      return { pasted: true }
    } catch (error) {
      return { pasted: false, reason: de('Auf der Zwischenablage. Einfügen ging nicht.', 'On the clipboard. Pasting did not work.') + ` (${(error as Error).message})` }
    }
  }, keepsOnClipboard)
}
