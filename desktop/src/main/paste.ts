import { clipboard, ClipboardItem } from 'electron'
import { execFile } from 'node:child_process'
import fs from 'node:fs'
import { de } from '../core/language'

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

/** Every item on the clipboard, in every form, read out now (the live items change with the clipboard). */
async function save(): Promise<ClipboardItem[]> {
  const items = await clipboard.read().catch(() => [] as ClipboardItem[])
  const copies: ClipboardItem[] = []
  for (const item of items) {
    const payload: Record<string, string | Blob | Electron.ClipboardBookmark> = {}
    for (const type of item.types) {
      try { payload[type] = await item.getType(type) } catch { /* that form is gone already */ }
    }
    if (Object.keys(payload).length > 0) copies.push(new ClipboardItem(payload as never))
  }
  return copies
}

async function restore(items: ClipboardItem[]) {
  if (items.length > 0) await clipboard.write(items).catch(() => {})
}

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
  return new Promise(resolve => execFile('ydotool', ['key', '29:1', '47:1', '47:0', '29:0'], { env }, (error, _out, stderr) => {
    if (error) log?.(`ydotool: ${(stderr || error.message).trim().split('\n')[0]}`)
    resolve(!error)
  }))
}

export async function deliver(text: string, keyTap: KeyTap, keepsOnClipboard: boolean, log?: (message: string) => void): Promise<{ pasted: boolean; reason?: string }> {
  if (!text) return { pasted: true }
  const previous = await save()
  await clipboard.writeText(text)

  let pasted = false
  if (isWayland()) {
    if (await which('ydotool')) pasted = await ydotoolPaste(log)
    if (!pasted) {
      // Leave the transcript on the clipboard: it is the fallback.
      return { pasted: false, reason: de('Auf der Zwischenablage. Mit Strg+V einfügen.', 'On the clipboard. Paste with Ctrl+V.') }
    }
  } else {
    try {
      keyTap()
      pasted = true
    } catch (error) {
      return { pasted: false, reason: de('Auf der Zwischenablage. Einfügen ging nicht.', 'On the clipboard. Pasting did not work.') + ` (${(error as Error).message})` }
    }
  }
  // Handed back once the paste has been taken, and only while the transcript
  // is still what is there: something copied in the meantime stays.
  if (!keepsOnClipboard) setTimeout(async () => { if ((await clipboard.readText()) === text) await restore(previous) }, 600)
  return { pasted }
}
