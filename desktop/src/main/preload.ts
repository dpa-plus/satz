import { contextBridge, ipcRenderer } from 'electron'

/** The few channels the card and settings windows may use. */
const send = new Set(['card:ready', 'card:button', 'card:caret', 'card:rect', 'card:pointer-inside', 'card:drag', 'rec:started', 'rec:chunk'])
const receive = new Set(['card:state', 'rec:start', 'rec:stop', 'history:changed', 'models:changed', 'window:page'])
const invoke = new Set(['settings:get', 'settings:update', 'settings:store-key', 'settings:clear-history', 'settings:start-at-login', 'settings:open-log',
  'history:get', 'history:remove', 'history:copy', 'history:set-limit', 'history:open-settings', 'history:open'])

contextBridge.exposeInMainWorld('satz', {
  send: (channel: string, ...args: unknown[]) => { if (send.has(channel)) ipcRenderer.send(channel, ...args) },
  on: (channel: string, listener: (value: any) => void) => {
    if (receive.has(channel)) ipcRenderer.on(channel, (_event, value) => listener(value))
  },
  invoke: (channel: string, ...args: unknown[]) => (invoke.has(channel) ? ipcRenderer.invoke(channel, ...args) : Promise.reject(new Error('not allowed'))),
})
