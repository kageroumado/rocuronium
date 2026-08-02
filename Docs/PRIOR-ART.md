# Prior art — what OpenAI's Codex does, and what it teaches

*Cross-check performed 2026-08-02 against `openai/codex` @ `2b5bdcf` (2026-08-02), checked out
at `~/Developer/clones/codex`. Line references are to that commit.*

## The headline: there is nothing to copy for GUI control

Codex's open-source repo contains **no macOS GUI automation whatsoever** — verified by absence,
not by a failed search. No `AXUIElement`, no `CGEventPost`, no ScreenCaptureKit, no
`cliclick`/`robotjs`, no TCC handling, and no coordinate code at all (`CGPoint`,
`backingScaleFactor`, `devicePixelRatio` return zero hits). The only Apple-framework dependency
in the workspace is `core-foundation`, used by the sleep inhibitor and the config loader.

What exists is policy scaffolding for a feature implemented elsewhere: `Feature::ComputerUse`
(`codex-rs/features/src/lib.rs:209-212`) is declared, defaulted on, and **never consumed** —
its only reference is its own declaration. The implementation ships as the closed-source
bundled plugin `computer-use@openai-bundled` (`codex-rs/core-plugins/src/discoverable.rs:46-47`),
which the terminal CLI explicitly hides (`codex-rs/tui/src/app/background_requests.rs:994-1000`).
Sibling flags name the consumer: `BrowserUse` is "in desktop apps", with "full Chrome DevTools
Protocol access".

**So there is no prior art for the hard parts** — coordinates, verification, permissions. We are
not behind on these; nobody has published a solution to copy.

## What we adopted

**Trust preflight before acting** (`GhostLadder`). Their strongest applicable warning: an
ungranted `CGEventPost` returns no error and silently does nothing. Without a preflight that
surfaces as an ordinary "no effect" verdict, sending the caller to hunt for a bug in the app it
is driving. Codex has no TCC story at all (zero `kTCCService` references), so this was ours to
get right.

**Power assertions over `caffeinate`** (`DisplayWake.Hold`), matching
`codex-rs/utils/sleep-inhibitor/src/lib.rs:1-8`: a child process leaks on crash, can be killed
independently, and clutters the process list; an assertion released in `deinit` cannot outlive
us. Their idempotent-acquire plus RAII-release shape is worth copying verbatim.

**With the opposite assertion type — but see the correction below.** The open-source inhibitor
holds `PreventUserIdleSystemSleep` (`macos.rs:26`), which keeps the machine running while
letting the panel sleep: precisely the state we measured as collapsing every accessibility tree.
That is the right choice for a headless coding turn and the wrong one for anything that looks at
the screen. The same gap is live in Adrafinil today, which is why it needs a display-class hold.

> **Correction (same day, from disassembly).** It was wrong to call this OpenAI's mistake. Their
> *GUI* component — `SkyComputerUseService`, the binary that actually drives the screen — holds
> `PreventUserIdleDisplaySleep` and calls `IOPMAssertionDeclareUserActivity` to wake the panel,
> which is exactly what `DisplayWake.Hold` does. `PreventUserIdleSystemSleep` appears only in
> the headless CLI inhibitor, where it is correct. So this is not a divergence from Codex; their
> shipped GUI binary independently made the same choice we did. See
> `~/Developer/Research/codex-computer-use-internals.md`.

**The `CFSTR` constant trap.** `macos.rs:24-25` documents that Apple exposes assertion types as
`CFSTR(...)` macros which cannot be bound as constants — hence raw string literals. The same
applies in Swift, so `DisplayWake.Hold` uses `"PreventUserIdleDisplaySleep"` with that reason
recorded.

## Their one enterprise knob is about the locked screen

`ComputerUseRequirementsToml` (`codex-rs/config/src/config_requirements.rs:745-748`) has exactly
one field: `allow_locked_computer_use`. Of everything OpenAI could have made admin-controllable
about an agent driving a Mac, they shipped this. Semantics are undocumented — no description in
the JSON schema, nothing in the Markdown — so the exact meaning is inferred, but the design
signal is unambiguous: **whether the agent may work against a locked screen is a first-class
policy axis, not an emergent property of whether the API happens to still work.**

That independently validates making presence and lock state explicit rather than incidental,
which `UserPresence` does. Worth adding: an admin-pinnable policy separate from user config,
mirroring their two-tier gating (a "requirements-only" gate that user config cannot override).

## Traps worth remembering if we ever sandbox

Their seatbelt profile makes GUI automation structurally impossible by omission: `(deny default)`
with no `com.apple.windowserver.active`, no `tccd`, nothing for CoreGraphics. **A deny-default
sandbox and screen control are mutually exclusive** — any GUI helper must live in a separate
trust domain, decided up front rather than discovered when input silently no-ops.

Smaller ones, all from their comments (the highest-value content in the repo):

- `(deny file-write* (subpath X))` still permits *creating* `X` — deny the literal path too
  (`seatbelt.rs:381-383`).
- Denying reads without denying unlink leaks existence through error codes (`seatbelt.rs:445-448`).
- Resources handed across a sandbox boundary carry no sandbox extension and fail non-obviously —
  their case is a pre-sandbox PTY making `isatty()` false and shells silently non-interactive
  (`seatbelt_base_policy.sbpl:112-114`).
- Firmlinks: `stat` on an ordinary path silently traverses `/System/Volumes/Data`, so rules
  written against the visible path fail (`restricted_read_only_platform_defaults.sbpl:59-61`).
- Pin helper binaries by absolute path; a PATH-injected `sandbox-exec` is the whole game
  (`seatbelt.rs:26-30`).

## `osascript` is arbitrary code execution

Codex bans it by prefix alongside `bash -c` and `python -c` (`codex-rs/core/src/exec_policy.rs:95`)
and, notably, **retroactively strips** any such rule a user previously approved
(`codex-rs/core/src/session/mod.rs:584`). Relevant to us because AppleScript is the tempting
shortcut for window and app control, and one "always allow" hands over the machine with the
user's own TCC grants. If we ever add a permission store, it needs a revocation path — they
considered an already-granted rule dangerous enough to take back on upgrade.
