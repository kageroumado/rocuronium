# Sequence plans

`plan` executes a list of steps as one daemon-side operation, no round-trips between steps, so the world cannot change between them. Each step is an existing verb with its arguments plus an optional `expect` guard, an `onFail` policy, and a `refs` map that feeds a field from an earlier step's reply.

    rocuronium plan --file steps.json      (or pipe JSON to stdin)
    { "profile": "ghost", "steps": [
      { "command": "click", "app": "TextEdit", "label": "Save",
        "expect": { "type": "window-vanishes", "title": "Save" }, "onFail": "abort" },
      { "command": "type", "app": "TextEdit", "text": "done",
        "expect": { "type": "readback-contains", "text": "done" } } ] }

A step's **`refs`** map sets one of its fields from an earlier step's reply, resolved just before the step runs — how a `scroll --until-text` feeds the click that follows:

    { "steps": [
      { "command": "scroll", "app": "Books", "untilText": "Chapter 7" },
      { "command": "click", "app": "Books",
        "refs": { "x": "$1.foundAt.cx", "y": "$1.foundAt.cy" } } ] }

`$<step>` is the 1-based step number; the rest is a dotted path into that reply, with `cx`/`cy` derived as the center of a `{x,y,w,h}` block (`foundAt`, `frame`). One level, no expressions; an unresolved reference fails the step with a named error rather than acting on the wrong target.

| guard `type` | passes when |
|---|---|
| `verdict` | the step's verdict equals `verdict` |
| `readback-contains` | the step's read-back contains `text` |
| `window-appears` / `window-vanishes` | a window matching `title` exists / is gone |
| `text-visible` / `text-vanishes` | an element matching `label` is in / gone from the tree |
| `quiet` | the window's tree holds still for `ms` (default 600) — the view settled |
| `token-changed` | the window's tree differs from the walk observation `token` recorded |

`onFail`: `abort` (default; returns the transcript so far), `continue`, `pause-for-human` (halts as if ⌃⌥⇧⎢ were pressed and waits for the popover's resume), or `{"fallback": {step}}` (one alternative step, one level deep). Profiles: `ghost` (default) forces hardware input off per step, no overlay, no pacing; `visible` narrates each step in the bezel with 500 ms between steps. The reply is one transcript: per-step `verdict`, `guardPassed`, `guardReason`, `policy`, fallback outcome. ⌃⌥⇧⎢ aborts mid-plan.
