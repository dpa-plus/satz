import { app, BrowserWindow, clipboard, globalShortcut, ipcMain, Menu, nativeImage, Notification, session as electronSession, shell, Tray } from 'electron'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { de, setLanguage } from '../core/language'
import { Session, type AudioSource } from '../core/session'
import { needsKey, providers, transcribe, TranscriptionFailure } from '../core/transcriber'
import { downloadSize } from '../core/models'
import { DoubleTap } from '../core/trigger'
import { encodeWAV } from '../core/wav'
import { CardWindow } from './card'
import { startKeyboard, type Keyboard } from './keyboard'
import { deliver, isWayland } from './paste'
import { FileSource, MicHub, MicRecorder } from './recorder'
import { Store } from './store'
import { MediaPause, systemPlayers } from './media'
import { ModelLists } from './modelLists'
import { LocalModels } from './local'

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

  // Whisper on this computer, for the provider "Lokal".
  // On Windows not in the roaming profile: a gigabyte synced at every sign-in.
  const modelsDir = process.platform === 'win32' && process.env.LOCALAPPDATA ? path.join(process.env.LOCALAPPDATA, 'satz') : app.getPath('userData')
  const local = new LocalModels(path.join(modelsDir, 'models', 'local'), log, () => tellWindow('local:changed'))
  const localModel = () => store.prefs.models.local || providers.local.defaultModel
  /** What keeps the provider from working, in two or three words; null when it is ready. */
  function missing(): string | null {
    if (needsKey(store.prefs.provider)) return store.hasKey() ? null : new TranscriptionFailure('noKey').short
    const state = local.state(localModel()).kind
    if (state === 'ready') return null
    return state === 'downloading' || state === 'preparing' ? de('Modell lädt noch', 'Model still loading') : de('Modell fehlt', 'Model missing')
  }
  let keyboard: Keyboard | null = null

  const session = new Session({
    // In test mode silence once the files run out: a test never records the room.
    makeSource: (): AudioSource => (testMode && flag('--test-audio') !== undefined ? new FileSource(testAudio.shift() ?? null) : new MicRecorder(hub)),
    transcribe: samples => store.prefs.provider === 'local'
      ? local.transcribe(samples, localModel(), store.transcriberSettings().vocabulary, store.spokenLanguage)
      : transcribe(store.transcriberSettings(), encodeWAV(samples), store.readKey() ?? ''),
    replacements: () => store.activeReplacements,
    missing,
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
  // The tray follows the phase too: "Restore discarded" appears right after
  // a discard and goes after Undo, not only when the card closes.
  let lastPhase = session.phase.kind
  session.onChange = () => {
    pushState()
    if (session.phase.kind !== lastPhase) {
      lastPhase = session.phase.kind
      refreshTray()
      takeEscape(['starting', 'listening'].includes(lastPhase))
    }
  }
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
  // Escape discards while recording. The keyboard hook only listens, so the
  // key also reached the app the user was typing in. While satz records it
  // is taken as a global shortcut instead, which keeps it from that app.
  // Not under Wayland, where such a shortcut never fires for native apps.
  let escapeTaken = false
  function takeEscape(take: boolean) {
    if (isWayland() || take === escapeTaken) return
    if (take) escapeTaken = globalShortcut.register('Escape', () => session.discard())
    else { globalShortcut.unregister('Escape'); escapeTaken = false }
  }
  const doubleTap = new DoubleTap(() => session.press(), () => session.release())
  keyboard = await startKeyboard({
    trigger: (down: boolean) => (down ? doubleTap.keyDown(true) : doubleTap.keyUp(true)),
    other: () => doubleTap.keyDown(false),
    // Only where Escape could not be taken as a shortcut (Wayland).
    escape: () => { if (!escapeTaken && ['starting', 'listening'].includes(session.phase.kind)) session.discard() },
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

  // One window, two pages: History (what opening satz again shows) and
  // Settings. Two windows for them meant a second one beside the first.
  let mainWindow: BrowserWindow | null = null
  function openWindow(page: 'history' | 'settings') {
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.webContents.send('window:page', page)
      mainWindow.show(); mainWindow.focus()
      return
    }
    mainWindow = new BrowserWindow({
      width: 580, height: 780, title: 'satz', autoHideMenuBar: true,
      icon: path.join(__dirname, '..', 'assets', 'icon.png'),
      backgroundColor: '#16303C',
      webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
    })
    mainWindow.loadFile(path.join(__dirname, 'window.html'), { query: { page } })
  }
  // Declared as functions, so the tray built above can name them before this
  // line runs; as constants they stopped satz's start halfway.
  function openHistory() { openWindow('history') }
  function openSettings() { openWindow('settings') }
  function tellWindow(channel: string) {
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send(channel)
  }
  /** The tray and an open window show the change at once. */
  function historyChanged() {
    refreshTray()
    tellWindow('history:changed')
  }
  ipcMain.handle('history:get', () => ({ entries: store.history, limit: store.prefs.historyLimit, language: store.prefs.language }))
  ipcMain.handle('history:remove', (_e, id: string) => { store.removeHistory(id); historyChanged() })
  ipcMain.handle('history:copy', (_e, text: string) => { clipboard.writeText(text) })
  ipcMain.handle('history:set-limit', (_e, limit: number) => { store.setHistoryLimit(limit); historyChanged() })
  ipcMain.handle('history:open-settings', () => openSettings())
  ipcMain.handle('history:open', () => openHistory())

  // The model menu: the provider's live list, the shipped one until it arrives.
  const modelLists = new ModelLists(app.getPath('userData'), provider => store.readKey(provider), log, () => tellWindow('models:changed'))
  ipcMain.handle('settings:get', () => {
    modelLists.refresh(store.prefs.provider)
    return {
      prefs: store.prefs,
      hasKey: store.hasKey(),
      keyboard: keyboard?.description,
      wayland: isWayland(),
      platform: process.platform,
      history: store.history,
      startAtLogin: startAtLogin.get(),
      spokenLanguage: store.spokenLanguage,
      models: modelLists.get(store.prefs.provider),
      local: { state: local.state(localModel()), size: downloadSize[localModel()] ?? null },
    }
  })
  ipcMain.handle('local:download', () => local.download(localModel()))
  ipcMain.handle('local:remove', () => local.remove(localModel(), folder => shell.trashItem(folder)))
  ipcMain.handle('settings:update', (_e, change) => {
    store.update(change)
    // A loaded model is a gigabyte of memory: there only while "Lokal" is chosen.
    if ('provider' in change || 'models' in change) {
      if (store.prefs.provider === 'local') local.warmUp(localModel())
      else void local.unload()
    }
    if (change.pausesMedia) mediaPause.prepare()
    refreshTray()
    return store.prefs
  })
  // Quitting in the middle of a dictation plays the paused music again.
  let quitting = false
  app.on('before-quit', event => {
    if (quitting) return
    quitting = true
    event.preventDefault()
    mediaPause.quitting().finally(() => app.quit())
  })
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

  if (store.prefs.provider === 'local') local.warmUp(localModel())
  if (missing() && !testMode) {
    openSettings()
    new Notification({ title: 'satz', body: needsKey(store.prefs.provider)
      ? de('Bitte einen API-Schlüssel hinterlegen.', 'Please add an API key.')
      : de('Bitte das Modell in den Einstellungen laden.', 'Please download the model in Settings.') }).show()
  }

  if (devPort) startDevControl(Number(devPort), session, card, delivered, store, () => local.download(localModel()), () => local.state(localModel()))
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
function startDevControl(port: number, session: Session, card: CardWindow, delivered: string[], store: Store, downloadLocal: () => void, localState: () => unknown) {
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
      // What the Download button does, and the state it leads to (start with --provider local in the prefs).
      case 'local-download': downloadLocal(); break
      case 'local': body = localState(); break
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
