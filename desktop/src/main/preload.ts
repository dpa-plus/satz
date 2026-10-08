import { contextBridge, ipcRenderer } from 'electron'

import { invoke, receive, send } from './channels'

contextBridge.exposeInMainWorld('satz', {
  send: (channel: string, ...args: unknown[]) => { if (send.has(channel)) ipcRenderer.send(channel, ...args) },
  on: (channel: string, listener: (value: any) => void) => {
    if (receive.has(channel)) ipcRenderer.on(channel, (_event, value) => listener(value))
  },
  invoke: (channel: string, ...args: unknown[]) => (invoke.has(channel) ? ipcRenderer.invoke(channel, ...args) : Promise.reject(new Error('not allowed'))),
})
