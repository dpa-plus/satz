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
}

interface Handlers {
  trigger(down: boolean): void
  other(): void
  escape(): void
  log(message: string): void
}

export async function startKeyboard(handlers: Handlers): Promise<Keyboard> {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { uIOhook, UiohookKey } = require('uiohook-napi') as typeof import('uiohook-napi')
  const paste = () => uIOhook.keyTap(UiohookKey.V, [UiohookKey.Ctrl])

  if (isWayland()) {
    const devices = keyboardDevices()
    if (devices.length > 0) {
      for (const device of devices) readEvdev(device, handlers)
      return { description: `right Ctrl twice (keyboard devices: ${devices.length})`, paste }
    }
    handlers.log('Wayland without access to /dev/input: the shortcut is "satz --toggle" from a desktop shortcut')
    return { description: 'Wayland: desktop shortcut running "satz --toggle"', paste }
  }

  uIOhook.on('keydown', event => {
    if (event.keycode === UiohookKey.CtrlRight) handlers.trigger(true)
    else if (event.keycode === UiohookKey.Escape) { handlers.other(); handlers.escape() }
    else handlers.other()
  })
  uIOhook.on('keyup', event => {
    if (event.keycode === UiohookKey.CtrlRight) handlers.trigger(false)
  })
  uIOhook.start()
  return { description: 'right Ctrl twice', paste }
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

function readEvdev(device: string, handlers: Handlers) {
  // struct input_event on 64-bit Linux: 16 bytes of time, type, code, value.
  const size = 24
  let rest = Buffer.alloc(0)
  const stream = fs.createReadStream(device)
  stream.on('data', (chunk: Buffer | string) => {
    rest = Buffer.concat([rest, chunk as Buffer])
    while (rest.length >= size) {
      const type = rest.readUInt16LE(16), code = rest.readUInt16LE(18), value = rest.readInt32LE(20)
      rest = rest.subarray(size)
      if (type !== EV_KEY || value === 2) continue // 2: the keyboard's own repeat
      if (code === KEY_RIGHTCTRL) handlers.trigger(value === 1)
      else if (value === 1) {
        handlers.other()
        if (code === KEY_ESC) handlers.escape()
      }
    }
  })
  stream.on('error', error => handlers.log(`keyboard ${device}: ${error.message}`))
}
