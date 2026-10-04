import { BrowserWindow, ipcMain, screen } from 'electron'
import path from 'node:path'

/**
 * The floating card's window. Like the Mac app's: it never changes size (the
 * card animates inside it), it is see-through around the card and lets clicks
 * there through, it never takes the keyboard from the app the user is typing
 * in, and the card stops at the edge of the screen when dragged.
 */
export const MARGIN = 18
export const CARD_WIDTH = 380
export const PILL_WIDTH = 200
const ROW = 40
const MAX_TEXT = 5 * 20 + 18
export const SIZE = { width: CARD_WIDTH + 2 * MARGIN, height: MAX_TEXT + 1 + ROW + 2 * MARGIN }
/** Linux takes clicks through a window shape instead of switching them on and off. */
const shaped = process.platform === 'linux'

export class CardWindow {
  readonly window: BrowserWindow
  private dragStart: { mouse: Electron.Point; origin: number[] } | null = null
  /** The card's outline inside the window, as the page last reported it. */
  private cardRect = { x: 0, y: 0, width: 0, height: 0 }
  private clickable = false
  private watcher: ReturnType<typeof setInterval> | null = null

  constructor(private spot: () => { x: number; y: number } | null, private saveSpot: (spot: { x: number; y: number }) => void) {
    this.window = new BrowserWindow({
      ...SIZE,
      show: false,
      frame: false,
      transparent: true,
      resizable: false,
      movable: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      skipTaskbar: true,
      focusable: false,
      hasShadow: false,
      alwaysOnTop: true,
      backgroundColor: '#00000000',
      webPreferences: {
        preload: path.join(__dirname, 'preload.js'),
        contextIsolation: true,
        nodeIntegration: false,
        backgroundThrottling: false,
      },
    })
    this.window.setAlwaysOnTop(true, 'screen-saver')
    this.window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true })
    if (shaped) {
      // Linux: the window's shape follows the card, so outside it there is
      // no window to click. Through XWayland satz does not even learn where
      // the pointer is while it is over other apps, so it cannot switch.
      this.window.setShape([{ x: 0, y: 0, width: 1, height: 1 }])
    } else {
      // Everything is see-through until the pointer is over the card itself.
      this.window.setIgnoreMouseEvents(true, { forward: true })
    }
    this.window.loadFile(path.join(__dirname, 'card.html'))

    ipcMain.on('card:rect', (_e, rect: { x: number; y: number; width: number; height: number }) => {
      this.cardRect = rect
      if (shaped && rect.width > 0 && rect.height > 0) this.window.setShape([rect])
    })
    // Windows and macOS also forward the pointer entering the card: clickable at once.
    ipcMain.on('card:pointer-inside', () => this.setClickable(true))
    ipcMain.on('card:drag', (_e, phase: 'start' | 'move' | 'end') => this.drag(phase))
  }

  /** Near the bottom centre of the screen holding the mouse, or where the user put it. */
  show() {
    if (!this.window.isVisible()) {
      this.place()
      this.window.showInactive()
      this.window.setAlwaysOnTop(true, 'screen-saver')
    }
    this.watchPointer()
  }

  hide() {
    this.window.hide()
    if (this.watcher) clearInterval(this.watcher)
    this.watcher = null
  }

  /**
   * Clicks pass through the see-through part of the window. The pointer is
   * checked against the card's outline every few frames: Electron forwards
   * mouse movement to an ignoring window only on Windows and macOS, and even
   * there a jump of the pointer straight onto a button was missed.
   */
  private watchPointer() {
    if (this.watcher || shaped) return
    this.watcher = setInterval(() => {
      if (this.window.isDestroyed() || !this.window.isVisible()) return
      const point = screen.getCursorScreenPoint()
      const [wx, wy] = this.window.getPosition()
      const r = this.cardRect
      const inside = this.dragStart !== null ||
        (point.x >= wx + r.x && point.x < wx + r.x + r.width && point.y >= wy + r.y && point.y < wy + r.y + r.height)
      this.setClickable(inside)
    }, 16)
  }

  private setClickable(inside: boolean) {
    if (inside === this.clickable || this.window.isDestroyed()) return
    this.clickable = inside
    this.window.setIgnoreMouseEvents(!inside, { forward: true })
  }

  private display() { return screen.getDisplayNearestPoint(screen.getCursorScreenPoint()) }

  /** The pill centred near the bottom; the card grows to the left from there. */
  private base(area: Electron.Rectangle) {
    return {
      x: Math.round(area.x + area.width / 2 + PILL_WIDTH / 2 + MARGIN - SIZE.width),
      y: Math.round(area.y + area.height - 96 + MARGIN - SIZE.height),
    }
  }

  /** The see-through margin may leave the screen, the card never does. */
  private clamp(x: number, y: number, area: Electron.Rectangle) {
    return {
      x: Math.round(Math.min(Math.max(x, area.x - MARGIN), area.x + area.width - SIZE.width + MARGIN)),
      y: Math.round(Math.min(Math.max(y, area.y - MARGIN), area.y + area.height - SIZE.height + MARGIN)),
    }
  }

  place() {
    const area = this.display().workArea
    const base = this.base(area)
    const offset = this.spot() ?? { x: 0, y: 0 }
    const { x, y } = this.clamp(base.x + offset.x, base.y + offset.y, area)
    this.window.setBounds({ x, y, ...SIZE })
  }

  /** Moves with the mouse on the screen, and stops at the wall. */
  private drag(phase: 'start' | 'move' | 'end') {
    const mouse = screen.getCursorScreenPoint()
    if (phase === 'start') {
      this.dragStart = { mouse, origin: this.window.getPosition() }
      return
    }
    if (!this.dragStart) return
    const area = screen.getDisplayNearestPoint(mouse).workArea
    const wanted = this.clamp(this.dragStart.origin[0] + mouse.x - this.dragStart.mouse.x, this.dragStart.origin[1] + mouse.y - this.dragStart.mouse.y, area)
    this.window.setBounds({ ...wanted, ...SIZE })
    if (phase === 'end') {
      this.dragStart = null
      const base = this.base(area)
      this.saveSpot({ x: wanted.x - base.x, y: wanted.y - base.y })
    }
  }

  send(channel: string, value: unknown) {
    if (!this.window.isDestroyed()) this.window.webContents.send(channel, value)
  }
}
