/**
 * `original`: the text as it was said, where cleanup changed it; `cleanup`:
 * "ok" or why it failed, only when cleanup was on. Older entries have neither.
 */
export interface HistoryEntry { id: string; text: string; date: string; pasted: boolean; original?: string; cleanup?: string }

/**
 * The history file as read. Apart from store.ts, which needs Electron, so a
 * test can read a file from an older satz through it: entries from before
 * 0.1.2 have no id yet, entries from before cleanup none of its fields.
 *
 * A list with something else in it (a null, a number, an entry without a
 * text: a file edited by hand, or cut short and repaired) lost every
 * dictation to the one entry that threw while the history was read. Such an
 * entry is skipped and the rest is kept; the limit counts what is kept.
 */
export function readHistory(json: unknown, limit: number, newId: () => string): HistoryEntry[] {
  return (Array.isArray(json) ? json : [])
    .filter((entry): entry is HistoryEntry => !!entry && typeof entry === 'object' && !Array.isArray(entry) && typeof (entry as { text?: unknown }).text === 'string')
    .map(entry => ({ ...entry, id: typeof entry.id === 'string' && entry.id !== '' ? entry.id : newId() }))
    .slice(0, limit)
}
