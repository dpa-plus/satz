/**
 * The few channels the card and settings windows may use. Every channel the
 * pages use has to be listed here, or the call is refused: the Local model's
 * Download button did nothing because its channel was missing
 * (test/channels.test.ts checks the pages against these lists, and these
 * lists against the channels main.ts and card.ts handle, listen to and send;
 * names only, it does not run a handler).
 */
export const send = new Set(['card:ready', 'card:button', 'card:caret', 'card:rect', 'card:pointer-inside', 'card:drag', 'rec:started', 'rec:chunk'])
export const receive = new Set(['card:state', 'rec:start', 'rec:stop', 'history:changed', 'models:changed', 'local:changed', 'window:page'])
export const invoke = new Set(['settings:get', 'settings:update', 'settings:store-key', 'settings:clear-history', 'settings:start-at-login', 'settings:open-log',
  'history:get', 'history:remove', 'history:copy', 'history:set-limit', 'history:open-settings', 'history:open', 'local:download', 'local:cancel', 'local:measure', 'local:remove'])

