import { app, BrowserWindow, clipboard, ipcMain, Menu, nativeImage, Notification, session as electronSession, shell, Tray } from 'electron'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { de, setLanguage } from '../core/language'
import { Session, type AudioSource } from '../core/session'
import { transcribe } from '../core/transcriber'
import { DoubleTap } from '../core/trigger'
import { encodeWAV } from '../core/wav'
import { CardWindow } from './card'
import { startKeyboard, type Keyboard } from './keyboard'
import { deliver, isWayland } from './paste'
import { FileSource, MicHub, MicRecorder } from './recorder'
import { Store } from './store'
import { MediaPause, systemPlayers } from './media'

/**
 * satz for Windows and Linux. Double-tap right Ctrl, talk, double-tap again:
 * the text goes where you were typing. The Mac app's behaviour, rebuilt on
 * Electron so one codebase serves both.
 */
const args = process.argv.slice(1)
const flag = (name: string) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined }
const testAudio = flag('--test-audio')?.split(path.delimiter === ';' ? ';' : ':').filter(Boolean) ?? []
const devPort = flag('--dev-control')
const testMode = devPort !== undefined
const realPasteInTest = args.includes('--test-paste')

if (process.platform === 'linux' && !process.env.SATZ_NATIVE_WAYLAND) {
  // Under Wayland a window cannot keep itself on top or place itself; through
  // XWayland it can.
  app.commandLine.appendSwitch('ozone-platform', 'x11')
}

// One satz at a time; a second start passes its command to the first.
if (!app.requestSingleInstanceLock({ argv: args })) {
  app.quit()
} else {
  app.whenReady().then(start)
}

function log(message: string) {
  const line = `${new Date().toISOString()} ${message}`
  console.log(line)
  try { fs.appendFileSync(path.join(app.getPath('userData'), 'satz.log'), line + '\n') } catch { /* no log then */ }
}

async function start() {
  app.setAppUserModelId('plus.dpa.satz')
  const store = new Store()
  setLanguage(store.prefs.language)
  log(`satz ${app.getVersion()} on ${process.platform} ${process.arch}, ${isWayland() ? 'Wayland' : 'X11/Windows'}${testMode ? ', test mode' : ''}`)

  electronSession.defaultSession.setPermissionRequestHandler((_wc, permission, callback) => callback(permission === 'media'))
  electronSession.defaultSession.setPermissionCheckHandler((_wc, permission) => permission === 'media')

  const card = new CardWindow(() => store.prefs.cardSpot, spot => store.update({ cardSpot: spot }))

  // The microphone, recorded in the card window.
  let recordingRequest = 0
  const pending = new Map<number, { resolve: () => void; reject: (e: Error) => void }>()
  const hub = new MicHub({
    start: () => new Promise((resolve, reject) => {
      const id = ++recordingRequest
      pending.set(id, { resolve, reject })
      card.send('rec:start', id)
    }),
    stop: () => card.send('rec:stop', null),
  })
  ipcMain.on('rec:started', (_e, id: number, error?: string) => {
    const waiting = pending.get(id)
    pending.delete(id)
    if (!waiting) return
    if (error) waiting.reject(new Error(error))
    else waiting.resolve()
  })
  ipcMain.on('rec:chunk', (_e, chunk: Float32Array) => hub.push(chunk))

  const delivered: string[] = []
  let keyboard: Keyboard | null = null

  const session = new Session({
    makeSource: (): AudioSource => (testAudio.length > 0 ? new FileSource(testAudio.shift()!) : new MicRecorder(hub)),
    transcribe: samples => transcribe(store.transcriberSettings(), encodeWAV(samples), store.readKey() ?? ''),
    replacements: () => store.activeReplacements,
    hasKey: () => store.hasKey(),
    endpointMissing: () => store.endpointMissing,
    triggerMode: () => store.prefs.triggerMode,
    log,
    deliver: async text => {
      if (testMode && !realPasteInTest) {
        delivered.push(text)
        // Test mode runs in the test VMs; the history shows what it heard.
        store.addHistory(text, true)
        historyChanged()
        return { pasted: true }
      }
      // A moment for the shortcut's own keys to come up before Ctrl+V.
      await new Promise(resolve => setTimeout(resolve, 120))
      const outcome = await deliver(text, () => keyboard?.paste(), store.prefs.keepsOnClipboard, log)
      log(`paste: ${outcome.pasted ? 'sent Ctrl+V' : 'clipboard only'}, ${text.length} characters`)
      store.addHistory(text, outcome.pasted)
      delivered.push(text)
      historyChanged()
      return outcome
    },
  })

  let pushQueued = false
  const pushState = () => {
    if (pushQueued) return
    pushQueued = true
    setTimeout(() => {
      pushQueued = false
      card.send('card:state', {
        phase: session.phase,
        runs: session.doc.runs(),
        levels: session.levels,
        showsText: store.prefs.showsText,
        hasRealText: session.hasRealText,
        bright: session.breathBright,
        language: store.prefs.language,
      })
    }, 16)
  }
  session.onChange = pushState
  // Never in test mode, where it would pause the user's music, unless a test asks.
  const mediaPause = new MediaPause(systemPlayers(log), () => store.prefs.pausesMedia && (!testMode || args.includes('--test-media')), log)
  session.onOpen = () => { card.show(); pushState() }
  session.onRecord = () => mediaPause.dictationStarted()
  session.onClose = () => { card.hide(); refreshTray(); mediaPause.dictationEnded() }

  ipcMain.on('card:ready', pushState)
  ipcMain.on('card:button', (_e, button: string) => {
    switch (button) {
      case 'mic': session.toggleMicrophone(); break
      case 'eye': store.update({ showsText: !store.prefs.showsText }); pushState(); break
      case 'close': session.discard(); break
      case 'undo': session.undoDiscard(); break
      case 'retry': session.retry(); break
    }
  })
  ipcMain.on('card:caret', (_e, offset: number) => session.userMovedCaret(offset))

  // The shortcut: right Ctrl twice; Escape discards while recording.
  const doubleTap = new DoubleTap(() => session.press(), () => session.release())
  keyboard = await startKeyboard({
    trigger: (down: boolean) => (down ? doubleTap.keyDown(true) : doubleTap.keyUp(true)),
    other: () => doubleTap.keyDown(false),
    escape: () => { if (['starting', 'listening'].includes(session.phase.kind)) session.discard() },
    log,
  })
  log(`shortcut: ${keyboard.description}`)

  // A second start ("satz --toggle", e.g. from a desktop shortcut) acts like
  // the shortcut. Opened from the app menu again, satz shows the history:
  // without it, starting a running tray app looked like nothing happened.
  app.on('second-instance', (_e, argv) => {
    if (argv.includes('--toggle')) session.press()
    else if (argv.includes('--settings')) openSettings()
    else openHistory()
  })

  // Tray.
  const iconPath = path.join(__dirname, '..', 'assets', process.platform === 'win32' ? 'tray.png' : 'tray.png')
  const tray = new Tray(nativeImage.createFromPath(iconPath))
  tray.setToolTip('satz')
  function refreshTray() {
    const recent: Electron.MenuItemConstructorOptions[] = store.history.slice(0, 4).map(entry => ({
      label: entry.text.length > 60 ? entry.text.slice(0, 57) + '…' : entry.text,
      click: () => { clipboard.writeText(entry.text) },
    }))
    const menu = Menu.buildFromTemplate([
      ...(recent.length ? [{ label: de('Zuletzt (klicken zum Kopieren)', 'Recent (click to copy)'), enabled: false }, ...recent] : []),
      { label: de(`Ganzer Verlauf (${store.history.length})…`, `All history (${store.history.length})…`), click: openHistory },
      { type: 'separator' as const },
      ...(session.discarded && session.canRestore ? [{ label: de('Verworfenes zurückholen', 'Restore discarded'), click: () => session.restoreLast() }, { type: 'separator' as const }] : []),
      { label: de('Einstellungen…', 'Settings…'), click: openSettings },
      { label: de('Beenden', 'Quit'), click: () => app.quit() },
    ])
    tray.setContextMenu(menu)
  }
  tray.on('click', () => tray.popUpContextMenu())
  refreshTray()

  // History: everything kept, searchable; what opening satz again shows.
  let historyWindow: BrowserWindow | null = null
  function openHistory() {
    if (historyWindow && !historyWindow.isDestroyed()) { historyWindow.show(); historyWindow.focus(); return }
    historyWindow = new BrowserWindow({
      width: 580, height: 700, title: de('satz Verlauf', 'satz History'), autoHideMenuBar: true,
      icon: path.join(__dirname, '..', 'assets', 'icon.png'),
      backgroundColor: '#16303C',
      webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
    })
    historyWindow.loadFile(path.join(__dirname, 'history.html'))
  }
  /** The tray and an open history window show the change at once. */
  function historyChanged() {
    refreshTray()
    for (const window of [historyWindow, settings]) {
      if (window && !window.isDestroyed()) window.webContents.send('history:changed')
    }
  }
  ipcMain.handle('history:get', () => ({ entries: store.history, limit: store.prefs.historyLimit, language: store.prefs.language }))
  ipcMain.handle('history:remove', (_e, id: string) => { store.removeHistory(id); historyChanged() })
  ipcMain.handle('history:copy', (_e, text: string) => { clipboard.writeText(text) })
  ipcMain.handle('history:set-limit', (_e, limit: number) => { store.setHistoryLimit(limit); historyChanged() })
  ipcMain.handle('history:open-settings', () => openSettings())
  ipcMain.handle('history:open', () => openHistory())

  // Settings.
  let settings: BrowserWindow | null = null
  function openSettings() {
    if (settings && !settings.isDestroyed()) { settings.show(); settings.focus(); return }
    settings = new BrowserWindow({
      width: 560, height: 760, title: de('satz Einstellungen', 'satz Settings'), autoHideMenuBar: true,
      icon: path.join(__dirname, '..', 'assets', 'icon.png'),
      backgroundColor: '#16303C',
      webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
    })
    settings.loadFile(path.join(__dirname, 'settings.html'))
  }
  ipcMain.handle('settings:get', () => ({
    prefs: store.prefs,
    hasKey: store.hasKey(),
    keyboard: keyboard?.description,
    wayland: isWayland(),
    platform: process.platform,
    history: store.history,
    startAtLogin: startAtLogin.get(),
    spokenLanguage: store.spokenLanguage,
  }))
  ipcMain.handle('settings:update', (_e, change) => { store.update(change); refreshTray(); return store.prefs })
  ipcMain.handle('settings:store-key', (_e, key: string) => { store.storeKey(key); return store.hasKey() })
  ipcMain.handle('settings:clear-history', () => { store.clearHistory(); historyChanged() })
  ipcMain.handle('settings:start-at-login', (_e, on: boolean) => { startAtLogin.set(on); return startAtLogin.get() })
  ipcMain.handle('settings:open-log', () => shell.openPath(path.join(app.getPath('userData'), 'satz.log')))

  // Start at login, on from the first launch; switched off, it stays off.
  if (!testMode && !store.prefs.startAtLoginDefaulted) {
    startAtLogin.set(true)
    store.update({ startAtLoginDefaulted: true })
    log(`start at login: ${startAtLogin.get() ? 'on' : 'could not be switched on'}`)
  } else if (!testMode && startAtLogin.get()) {
    // Written again on every start, so it follows satz when it moves (from
    // an unpacked folder to the installed package, say).
    startAtLogin.set(true)
  }

  if (!store.hasKey() && !testMode) {
    openSettings()
    new Notification({ title: 'satz', body: de('Bitte einen API-Schlüssel hinterlegen.', 'Please add an API key.') }).show()
  }

  if (devPort) startDevControl(Number(devPort), session, card, delivered, store)
}

/** Windows: the registry's Run key through Electron. Linux: an autostart entry. */
const startAtLogin = {
  desktopFile: () => path.join(os.homedir(), '.config', 'autostart', 'satz.desktop'),
  get(): boolean {
    if (process.platform === 'linux') return fs.existsSync(this.desktopFile())
    return app.getLoginItemSettings().openAtLogin
  },
  set(on: boolean) {
    if (process.platform === 'linux') {
      const file = this.desktopFile()
      if (!on) { try { fs.rmSync(file) } catch { /* gone */ } return }
      // The start script, not satz-bin behind it: only the script starts satz
      // the way Linux needs (see build/after-pack.cjs).
      const exec = process.env.APPIMAGE ?? process.execPath.replace(/-bin$/, '')
      fs.mkdirSync(path.dirname(file), { recursive: true })
      fs.writeFileSync(file, `[Desktop Entry]\nType=Application\nName=satz\nExec="${exec}"\nX-GNOME-Autostart-enabled=true\n`)
      return
    }
    app.setLoginItemSettings({ openAtLogin: on })
  },
}

/**
 * Test mode: commands over HTTP on localhost, as the Mac app's distributed
 * notifications. Finished texts are recorded instead of pasted unless
 * --test-paste is given.
 */
function startDevControl(port: number, session: Session, card: CardWindow, delivered: string[], store: Store) {
  const server = http.createServer(async (request, response) => {
    const url = new URL(request.url ?? '/', 'http://localhost')
    const command = url.pathname.slice(1)
    log(`dev: ${command}${url.search}`)
    let body: unknown = { ok: true }
    switch (command) {
      case 'press': session.press(); break
      case 'release': session.release(); break
      case 'mic': session.toggleMicrophone(); break
      case 'discard': session.discard(); break
      case 'undo': session.undoDiscard(); break
      case 'restore': session.restoreLast(); break
      case 'retry': session.retry(); break
      case 'eye': store.update({ showsText: !store.prefs.showsText }); break
      case 'caret': session.userMovedCaret(Number(url.searchParams.get('at'))); break
      case 'picture': {
        const image = await card.window.webContents.capturePage()
        const target = url.searchParams.get('path') ?? path.join(os.tmpdir(), 'satz-card.png')
        fs.writeFileSync(target, image.toPNG())
        body = { path: target }
        break
      }
      case 'js':
        try { body = { result: await card.window.webContents.executeJavaScript(url.searchParams.get('code') ?? '') } } catch (error) { body = { error: String(error) } }
        break
      case 'quit': app.quit(); break
      case 'state':
      default:
        body = {
          phase: session.phase,
          text: session.plainText().trim(),
          raw: session.doc.text(),
          sending: session.inFlight,
          delivered,
          window: card.window.getBounds(),
          visible: card.window.isVisible(),
          discarded: session.discarded?.preview ?? null,
        }
    }
    response.setHeader('Content-Type', 'application/json')
    response.end(JSON.stringify(body))
  })
  server.listen(port, '127.0.0.1', () => log(`dev control on 127.0.0.1:${port}`))
}
