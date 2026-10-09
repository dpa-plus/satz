import { app, BrowserWindow, clipboard, globalShortcut, ipcMain, Menu, nativeImage, net, Notification, session as electronSession, shell, Tray } from 'electron'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { de, setLanguage } from '../core/language'
import { Session, type AudioSource } from '../core/session'
import { needsKey, providers, transcribe, TranscriptionFailure, type Provider } from '../core/transcriber'
import { localModelIds, offeredModels, toldLanguage } from '../core/localModels'
import { DoubleTap } from '../core/trigger'
import { decodeWAV, encodeWAV, resample } from '../core/wav'
import { CardWindow } from './card'
import { startKeyboard, type Keyboard } from './keyboard'
import { deliver, isWayland } from './paste'
import { FileSource, MicHub, MicRecorder } from './recorder'
import { Store } from './store'
import { MediaPause, systemPlayers } from './media'
import { ModelLists } from './modelLists'
import { LocalModels } from './local'
import { GermanErrors } from './localBenchmarks'
import { machineName } from './localFiles'
import { SpeedTests } from './speedTests'
import { foreground } from './foreground'

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
/** A provider's name, as the settings page sends it. */
const isProvider = (value: unknown): value is Provider => typeof value === 'string' && Object.hasOwn(providers, value)

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
  // The card records. Asked before its page was ready, the request went
  // nowhere and the microphone stayed "opening" until satz restarted.
  let cardReady = () => {}
  const cardIsReady = new Promise<void>(resolve => { cardReady = resolve })
  ipcMain.once('card:ready', () => cardReady())
  const hub = new MicHub({
    start: () => new Promise((resolve, reject) => {
      const id = ++recordingRequest
      // An answer that never comes fails the start instead of hanging it.
      const timer = setTimeout(() => { if (pending.delete(id)) reject(new Error(de('Das Mikrofon antwortet nicht.', 'The microphone does not answer.'))) }, 15_000)
      pending.set(id, { resolve: () => { clearTimeout(timer); resolve() }, reject: error => { clearTimeout(timer); reject(error) } })
      void cardIsReady.then(() => card.send('rec:start', id))
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
  // The window the text is for: noted when the dictation starts.
  const windows = foreground(log)
  let target: Promise<string | null> = Promise.resolve(null)

  // The models on this computer, for the provider "Lokal".
  // On Windows not in the roaming profile: a gigabyte synced at every sign-in.
  // A model already downloaded to the old place there is used where it is.
  // In test mode --models-dir puts them elsewhere: a test never downloads into the user's folder.
  const roaming = path.join(app.getPath('userData'), 'models', 'local')
  const modelsDir = (testMode && flag('--models-dir')) || (process.platform === 'win32' && process.env.LOCALAPPDATA && !fs.existsSync(roaming)
    ? path.join(process.env.LOCALAPPDATA, 'satz', 'models', 'local') : roaming)
  const local = new LocalModels(modelsDir, log, () => tellWindow('local:changed'), app.getVersion())
  const localModel = () => store.prefs.models.local || providers.local.defaultModel
  /** What this system can run: no sherpa-onnx models on Windows on ARM. */
  const offered = offeredModels(process.platform, process.arch)
  /** The ids Settings may download, measure or remove: the list's, and the one in use. */
  const isListed = (id: unknown): id is string => typeof id === 'string' && localModelIds(localModel(), offered).includes(id)
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
      ? local.transcribe(samples, localModel(), store.transcriberSettings().vocabulary, store.spokenLanguage, toldLanguage(localModel(), store.prefs.toldLanguage, store.spokenLanguage))
      // Electron's fetch: the system proxy and certificate store, which Node's ignores.
      : transcribe(store.transcriberSettings(), encodeWAV(samples), store.readKey() ?? '', net.fetch as never),
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
      // Back to the window the dictation started in, or onto the clipboard:
      // pasted into whatever was in front, the text went to the wrong app.
      const window = await target
      if (window && !(await windows.restore(window))) {
        await clipboard.writeText(text)
        log('paste: the window the dictation started in is gone or would not come back')
        store.addHistory(text, false)
        delivered.push(text)
        historyChanged()
        return { pasted: false, reason: de('Auf der Zwischenablage, das Fenster ist nicht mehr da.', 'On the clipboard, the window is gone.') }
      }
      const terminal = window ? await windows.isTerminal(window) : false
      const outcome = await deliver(text, () => keyboard?.paste(terminal), store.prefs.keepsOnClipboard, log)
      log(`paste: ${outcome.pasted ? 'sent Ctrl+V' : 'clipboard only'}, ${text.length} characters`)
      store.addHistory(text, outcome.pasted)
      delivered.push(text)
      historyChanged()
      return outcome
    },
  })

  // The speed of a local model, measured on this computer with a 10 s public
  // domain clip (assets/speedtest.txt): right after its download and when
  // asked, once no dictation is under way (speedTests.ts says why).
  const speedTests = new SpeedTests({
    phase: () => session.phase.kind,
    measure: id => {
      let clip: Float32Array
      try {
        const { samples, sampleRate } = decodeWAV(fs.readFileSync(path.join(__dirname, '..', 'assets', 'speedtest.wav')))
        clip = resample(samples, sampleRate)
      } catch (error) { log(`local: no speed test clip (${(error as Error).message})`); return Promise.resolve('failed' as const) }
      return local.measure(id, clip, store.transcriberSettings().vocabulary, store.spokenLanguage, toldLanguage(id, store.prefs.toldLanguage, store.spokenLanguage))
    },
    inUse: localModel,
    isReady: id => local.isReady(id),
    use: id => store.update({ models: { ...store.prefs.models, local: id } }),
    localChosen: () => store.prefs.provider === 'local',
    warmUp: id => local.warmUp(id),
    log,
  })
  local.onArrived = id => speedTests.arrived(id)

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
    speedTests.sessionChanged()
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
  session.onBegin = () => { target = windows.current() }
  windows.prepare()
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
    // Where Escape could not be taken as a shortcut (Wayland), and Escape
    // with right Ctrl held (hold mode), which the plain shortcut does not see.
    escape: withTrigger => { if ((!escapeTaken || withTrigger) && ['starting', 'listening'].includes(session.phase.kind)) session.discard() },
    log,
  })
  log(`shortcut: ${keyboard.description}`)

  // A second start ("satz --toggle", e.g. from a desktop shortcut) acts like
  // the shortcut. Opened from the app menu again, satz shows the history:
  // without it, starting a running tray app looked like nothing happened.
  app.on('second-instance', (_e, argv) => {
    if (argv.includes('--toggle')) session.toggle()
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
    // Its own pages only: a link or file dropped on the window was loaded
    // there, with satz's bridge.
    mainWindow.webContents.on('will-navigate', event => event.preventDefault())
    mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
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
  const modelLists = new ModelLists(app.getPath('userData'), provider => store.readKey(provider), log, () => tellWindow('models:changed'), net.fetch as never)
  const germanErrors = new GermanErrors(app.getPath('userData'), log, () => tellWindow('local:changed'), net.fetch as never)
  /**
   * `shown`: the provider the settings page shows, which may not be the one
   * in use (core/browse.ts). Its key and model list are what the page gets;
   * nothing here switches dictations to it.
   */
  ipcMain.handle('settings:get', (_e, asked: unknown) => {
    const shown = isProvider(asked) ? asked : store.prefs.provider
    modelLists.refresh(shown)
    if (shown === 'local') germanErrors.refresh()
    return {
      prefs: store.prefs,
      shown,
      hasKey: store.hasKey(shown),
      keyboard: keyboard?.description,
      wayland: isWayland(),
      platform: process.platform,
      history: store.history,
      startAtLogin: startAtLogin.get(),
      spokenLanguage: store.spokenLanguage,
      models: modelLists.get(shown),
      local: {
        inUse: localModel(),
        models: localModelIds(localModel(), offered).map(id => ({ id, state: local.state(id), measuring: local.isMeasuring(id) || speedTests.isWaiting(id), speed: local.speed(id) })),
        germanErrors: germanErrors.get(),
        machine: machineName(),
        version: app.getVersion(),
      },
    }
  })
  ipcMain.handle('local:download', (_e, id: unknown) => { if (isListed(id)) local.download(id) })
  ipcMain.handle('local:cancel', (_e, id: unknown) => { if (isListed(id)) local.cancel(id) })
  ipcMain.handle('local:measure', (_e, id: unknown) => { if (isListed(id)) speedTests.request(id) })
  ipcMain.handle('local:remove', (_e, id: unknown) => isListed(id) ? local.remove(id, folder => shell.trashItem(folder)) : undefined)
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
    keyboard?.stop()
    mediaPause.quitting().finally(() => app.quit())
  })
  // For the provider shown, which need not be the one in use.
  ipcMain.handle('settings:store-key', (_e, key: string, asked: unknown) => {
    const provider = asked === undefined ? store.prefs.provider : asked
    if (!isProvider(provider) || !needsKey(provider)) return false
    store.storeKey(key, provider)
    return store.hasKey(provider)
  })
  ipcMain.handle('settings:clear-history', () => { store.clearHistory(); historyChanged() })
  ipcMain.handle('settings:start-at-login', (_e, on: boolean) => { startAtLogin.set(on); store.update({ startsAtLogin: on }); return startAtLogin.get() })
  ipcMain.handle('settings:open-log', () => shell.openPath(path.join(app.getPath('userData'), 'satz.log')))

  // Start at login, on from the first launch; switched off, it stays off.
  if (!testMode && !store.prefs.startAtLoginDefaulted) {
    startAtLogin.set(true)
    store.update({ startAtLoginDefaulted: true, startsAtLogin: true })
    log(`start at login: ${startAtLogin.get() ? 'on' : 'could not be switched on'}`)
  } else if (!testMode && (store.prefs.startsAtLogin ?? startAtLogin.get())) {
    // Written again on every start, so it follows satz when it moves (an
    // unzipped update in a new folder). Asked of the system, a moved satz on
    // Windows looked switched off, and the old copy kept starting.
    startAtLogin.set(true)
  }

  if (store.prefs.provider === 'local') local.warmUp(localModel())
  if (missing() && !testMode) {
    openSettings()
    new Notification({ title: 'satz', body: needsKey(store.prefs.provider)
      ? de('Bitte einen API-Schlüssel hinterlegen.', 'Please add an API key.')
      : de('Bitte das Modell in den Einstellungen laden.', 'Please download the model in Settings.') }).show()
  }

  // Started cold by a desktop shortcut ("satz --toggle") or the app menu
  // ("satz --settings"): the same as when satz was already running.
  if (args.includes('--toggle')) void cardIsReady.then(() => session.toggle())
  if (args.includes('--settings')) openSettings()

  if (devPort) startDevControl(Number(devPort), session, card, delivered, store, {
    download: id => local.download(id ?? localModel()),
    cancel: id => local.cancel(id ?? localModel()),
    measure: id => speedTests.request(id ?? localModel()),
    state: id => ({ state: local.state(id ?? localModel()), measuring: local.isMeasuring(id ?? localModel()), waiting: speedTests.isWaiting(id ?? localModel()), speed: local.speed(id ?? localModel()), inUse: localModel(), modelsDir }),
  })
}

/** Windows: the registry's Run key through Electron. Linux: an autostart entry. */
const startAtLogin = {
  // Where the desktop session looks: XDG_CONFIG_HOME, else ~/.config.
  desktopFile: () => path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'autostart', 'satz.desktop'),
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
function startDevControl(port: number, session: Session, card: CardWindow, delivered: string[], store: Store,
  local: { download(id?: string): void; cancel(id?: string): void; measure(id?: string): void; state(id?: string): unknown }) {
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
      // What a model's buttons do, and the state they lead to (?id=…, else the model in use; start with "provider": "local" in the prefs).
      case 'local-download': local.download(url.searchParams.get('id') ?? undefined); break
      case 'local-cancel': local.cancel(url.searchParams.get('id') ?? undefined); break
      case 'local-measure': local.measure(url.searchParams.get('id') ?? undefined); break
      case 'local': body = local.state(url.searchParams.get('id') ?? undefined); break
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
