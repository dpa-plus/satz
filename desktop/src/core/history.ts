/**
 * `original`: the text as it was said, where cleanup changed it; `cleanup`:
 * "ok" or why it failed, only when cleanup was on. Older entries have neither.
 */
export interface HistoryEntry { id: string; text: string; date: string; pasted: boolean; original?: string; cleanup?: string }

/**
 * The history file as read. Apart from store.ts, which needs Electron, so a
 * test can read a file from an older satz through it: entries from before
 * 0.1.2 have no id yet, entries from before cleanup none of its fields.
 */
export function readHistory(json: unknown, limit: number, newId: () => string): HistoryEntry[] {
  return (Array.isArray(json) ? json as HistoryEntry[] : [])
    .map(entry => ({ ...entry, id: entry.id ?? newId() }))
    .slice(0, limit)
}
