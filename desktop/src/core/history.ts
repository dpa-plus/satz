/**
 * `original`: the text as it was said, where cleanup changed it; `cleanup`:
 * "ok" or why it failed, only when cleanup was on. Older entries have neither.
 */
export interface HistoryEntry { id: string; text: string; date: string; pasted: boolean; original?: string; cleanup?: string }

export type HistoryPersistenceIssue = 'saveFailed' | 'clearFailed' | 'protected' | 'limitFailed'
export type HistoryPersistenceResult = { status: 'saved' | 'off' } | { status: 'failed'; issue: HistoryPersistenceIssue }

/** A completed insertion stays completed; this warning is about keeping its history across restarts. */
export function historyIssueText(issue: HistoryPersistenceIssue, language: 'de' | 'en') {
  const t = (de: string, en: string) => language === 'de' ? de : en
  if (issue === 'limitFailed') return {
    title: t('Einstellung nicht gespeichert', 'Setting not saved'),
    detail: t('Die Verlaufseinstellung konnte nicht gespeichert werden. Die bisherige Einstellung gilt weiterhin.', 'The history setting could not be saved. The previous setting still applies.'),
  }
  if (issue === 'clearFailed') return {
    title: t('Verlauf nicht gelöscht', 'History not cleared'),
    detail: t('Gespeicherte Texte konnten hier nicht gelöscht werden. Sie können beim nächsten Start wieder erscheinen.', 'Saved text could not be deleted here. It may appear again when satz next starts.'),
  }
  return {
    title: t('Verlauf nicht gespeichert', 'History not saved'),
    detail: issue === 'protected'
      ? t('Die bisherige Verlaufsdatei bleibt unverändert. Neue Texte bleiben nur bis zum Beenden in satz. Kopiere wichtige Texte vorher.', 'The previous history file is left unchanged. New text is kept in satz only until you quit. Copy important text first.')
      : t('Neue Texte und Änderungen bleiben nur bis zum Beenden in satz. Kopiere wichtige Texte vorher.', 'New text and changes are kept in satz only until you quit. Copy important text first.'),
  }
}

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
