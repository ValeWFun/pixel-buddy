import type { EngineInterface, PermissionRequestDecision, Register } from 'claude-code'

// The figure itself is a PowerShell 7 / WinForms app in ../buddy; this module only
// starts it with every session and hands it the permission questions.
const runBuddyHook = ($: EngineInterface, mode: string, stdin?: string, timeoutMs = 30_000) =>
  $.process.run(
    ['pwsh.exe', '-NoProfile', '-NonInteractive', '-File', `${$.plugin.root}/buddy/hook.ps1`, '-Mode', mode],
    { stdin, timeoutMs },
  )

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    void runBuddyHook($, 'ensure').catch(() => {})
    return started
  })

  // Waits for a click on the figure's speech bubble (120 s, then the question goes to the chat).
  // No decision from the figure means the engine asks as usual.
  on('classic.PermissionRequest', async ($, e, next) => {
    const ran = await runBuddyHook($, 'permission', JSON.stringify(e), 150_000)
    const decision = ran.stdout.trim()
      ? (JSON.parse(ran.stdout).hookSpecificOutput?.decision as PermissionRequestDecision | undefined)
      : undefined
    return decision ? { decision } : next(e)
  }).catch(($, e, next) => next(e))

  on('classic.Stop', async ($, e, next) => {
    void runBuddyHook($, 'notify', JSON.stringify(e)).catch(() => {})
    return next(e)
  }).catch(($, e, next) => next(e))
}
