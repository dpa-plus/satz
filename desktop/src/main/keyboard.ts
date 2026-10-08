import { spawn, type ChildProcess } from 'node:child_process'
import fs from 'node:fs'
import { isWayland } from './paste'

/**
 * The global keyboard: right Ctrl for the shortcut, Escape to discard, and
 * Ctrl+V to paste.
 *
 * Windows and Linux under X11 go through libuiohook (a low-level keyboard
 * hook, no special rights needed on Windows). Under Wayland no app can watch
 * the keyboard of other apps; there satz reads the keyboard devices directly
 * when the user is in the `input` group, and otherwise relies on a desktop
 * shortcut that runs `satz --toggle`.
 */
export interface Keyboard {
  description: string
  paste(): void
  /** Lets go of the keyboard devices, so quitting does not wait for a key. */
  stop(): void
}

interface Handlers {
  trigger(down: boolean): void
  other(): void
  /** @param withTrigger right Ctrl was down: Escape while holding to talk. */
  escape(withTrigger: boolean): void
  log(message: string): void
}

export async function startKeyboard(handlers: Handlers): Promise<Keyboard> {
  const noKeystrokes = () => { throw new Error('this system takes no keystrokes from satz') }

  if (isWayland()) {
    // Under Wayland libuiohook sees nothing and its keystrokes reach no one:
    // not even loaded (paste.ts uses ydotool or the clipboard there).
    const devices = keyboardDevices()
    if (devices.length > 0) {
      const readers = new EvdevReaders(handlers)
      return { description: `right Ctrl twice (keyboard devices: ${devices.length})`, paste: noKeystrokes, stop: () => readers.stop() }
    }
    handlers.log('Wayland without access to /dev/input: the shortcut is "satz --toggle" from a desktop shortcut')
    return { description: 'Wayland: desktop shortcut running "satz --toggle"', paste: noKeystrokes, stop: () => {} }
  }

  let hook: typeof import('uiohook-napi')
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    hook = require('uiohook-napi')
  } catch (error) {
    // satz still starts: "satz --toggle" works, texts go to the clipboard.
    handlers.log(`keyboard hook unavailable: ${(error as Error).message.split('\n')[0]}`)
    return { description: 'keyboard hook unavailable: desktop shortcut running "satz --toggle"', paste: noKeystrokes, stop: () => {} }
  }
  const { uIOhook, UiohookKey } = hook
  uIOhook.on('keydown', event => {
    if (event.keycode === UiohookKey.CtrlRight) handlers.trigger(true)
    else if (event.keycode === UiohookKey.Escape) { handlers.other(); handlers.escape(event.ctrlKey) }
    else handlers.other()
  })
  uIOhook.on('keyup', event => {
    if (event.keycode === UiohookKey.CtrlRight) handlers.trigger(false)
  })
  try {
    uIOhook.start()
  } catch (error) {
    // satz still starts: "satz --toggle" works, texts go to the clipboard.
    handlers.log(`keyboard hook did not start: ${(error as Error).message}`)
    return { description: 'keyboard hook unavailable: desktop shortcut running "satz --toggle"', paste: noKeystrokes, stop: () => {} }
  }
  return { description: 'right Ctrl twice', paste: () => uIOhook.keyTap(UiohookKey.V, [UiohookKey.Ctrl]), stop: () => uIOhook.stop() }
}

// MARK: - Linux evdev

const KEY_ESC = 1, KEY_RIGHTCTRL = 97, EV_KEY = 1

/** Keyboards among /dev/input/event*, if this user may read them. */
function keyboardDevices(): string[] {
  let text = ''
  try { text = fs.readFileSync('/proc/bus/input/devices', 'utf8') } catch { return [] }
  const devices: string[] = []
  for (const block of text.split('\n\n')) {
    const handlers = /H: Handlers=(.*)/.exec(block)?.[1] ?? ''
    const ev = /B: EV=([0-9a-f]+)/.exec(block)?.[1]
    // EV_KEY and EV_REP: a real keyboard, not a power button.
    if (!handlers.includes('kbd') || !ev || (parseInt(ev, 16) & 0x100002) !== 0x100002) continue
    const event = /event\d+/.exec(handlers)?.[0]
    if (!event) continue
    try {
      fs.accessSync(`/dev/input/${event}`, fs.constants.R_OK)
      devices.push(`/dev/input/${event}`)
    } catch { /* not allowed */ }
  }
  return devices
}

/**
 * One `cat` per keyboard device, read through a pipe. fs streams read devices
 * on libuv's thread pool, where each blocks a thread until a key is pressed:
 * four keyboards starved name lookups and file reads, and quitting waited
 * for a key. The devices are looked for again every few seconds, so a
 * keyboard plugged in or paired later works too.
 */
class EvdevReaders {
  private readers = new Map<string, ChildProcess>()
  private timer: NodeJS.Timeout
  private rightCtrl = false

  constructor(private handlers: Handlers) {
    this.scan()
    this.timer = setInterval(() => this.scan(), 5000)
  }

  private scan() {
    for (const device of keyboardDevices()) if (!this.readers.has(device)) this.read(device)
  }

  private read(device: string) {
    // struct input_event on 64-bit Linux: 16 bytes of time, type, code, value.
    const size = 24
    let rest = Buffer.alloc(0)
    const reader = spawn('cat', [device], { stdio: ['ignore', 'pipe', 'ignore'] })
    this.readers.set(device, reader)
    reader.stdout!.on('data', (chunk: Buffer) => {
      rest = Buffer.concat([rest, chunk])
      while (rest.length >= size) {
        const type = rest.readUInt16LE(16), code = rest.readUInt16LE(18), value = rest.readInt32LE(20)
        rest = rest.subarray(size)
        if (type !== EV_KEY || value === 2) continue // 2: the keyboard's own repeat
        if (code === KEY_RIGHTCTRL) { this.rightCtrl = value === 1; this.handlers.trigger(value === 1) }
        else if (value === 1) {
          this.handlers.other()
          if (code === KEY_ESC) this.handlers.escape(this.rightCtrl)
        }
      }
    })
    // Unplugged: forgotten, so the next scan opens it again when it is back.
    reader.on('exit', () => { if (this.readers.get(device) === reader) this.readers.delete(device) })
    reader.on('error', error => this.handlers.log(`keyboard ${device}: ${error.message}`))
  }

  stop() {
    clearInterval(this.timer)
    for (const reader of this.readers.values()) reader.kill()
    this.readers.clear()
  }
}
