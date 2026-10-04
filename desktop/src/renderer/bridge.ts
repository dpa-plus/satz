export interface Bridge {
  send(channel: string, ...args: unknown[]): void
  on(channel: string, listener: (value: any) => void): void
  invoke(channel: string, ...args: unknown[]): Promise<any>
}
export const satz = (window as unknown as { satz: Bridge }).satz
