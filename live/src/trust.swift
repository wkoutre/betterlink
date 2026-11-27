// trust: asks macOS for Accessibility for the app this runs from (the terminal), WITH the system prompt, once.
// Prints "accessibility=true|false". Used only by warmup.sh, which a person runs and approves; no other script prompts.
import ApplicationServices
let ok = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
print("accessibility=\(ok)")
exit(ok ? 0 : 1)
