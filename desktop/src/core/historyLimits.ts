/**
 * How many dictations the history keeps, in one place for the app that
 * enforces it (store.ts), the history page and the Settings menu that offers
 * the choices.
 */

/** "All": no limit anyone would reach. */
export const KEEP_ALL = 100_000

/** The choices in the settings, 0 being "keep none". */
export const HISTORY_LIMITS = [0, 10, 50, 200, KEEP_ALL]
