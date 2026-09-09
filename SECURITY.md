# Security Policy

Rocuronium is a menu-bar daemon that holds macOS Accessibility and Screen
Recording grants and accepts commands over a local Unix-domain socket. That
makes it a sensitive component of any system it runs on. Reports of weaknesses
in its trust boundaries are welcome.

## Reporting a vulnerability

Report privately — do **not** open a public issue for a security problem.

- Preferred: [GitHub private vulnerability reporting](https://github.com/kageroumado/rocuronium/security/advisories/new)
  ("Report a vulnerability" on the repository's Security tab).
- Alternative: email **mail@kagerou.glass**.

Include what you need to reproduce it: affected version or commit, macOS
version, and a minimal set of steps or a proof of concept. You'll get an
acknowledgement within a few days. Please allow time for a fix before any
public disclosure.

## Supported versions

This project is pre-1.0. Fixes land on `main` and in the most recent release;
older releases are not maintained.

## Threat model

The design assumes an attacker who can run code as the same macOS user but is
**not** the signed `Rocuronium.app`. The properties the code is written to hold:

- **Every action is attributed, and nothing runs with the app's grants
  unverified.** The control socket is owner-only and authenticates each peer by
  its audit token against a Developer ID requirement naming the embedded CLI and
  the app; every accepted request is logged with the caller's pid and path. The
  effective boundary is *same user*: the bundle ships a signed CLI that forwards
  any command, so a same-uid process reaches the same authority by running it —
  through the gates below, and on the record. What the daemon never does is
  hand its grants to code it has not checked: the one helper it spawns
  (Adrafinil's CLI, which inherits the app's TCC responsibility) is taken from
  its bundle path alone and signature-verified before every spawn, and model
  weights are pinned to a commit and verified file by file before install.
- **The cursor is never taken without opt-in.** Ghost delivery (accessibility
  writes, per-process posted events) is the default and moves nothing the human
  can see. Hardware input — the only path that moves the real cursor — requires
  an explicit per-call flag, is refused while the screen is locked or while
  another window occludes the target, and while a human is present it asks
  them on screen unless the caller asserts a prior approval with `confirm`,
  which the reply and the activity log then say.
- **The human is never locked out.** Ctrl+Option+Shift+Escape halts all
  activity within one cursor sample (~8 ms), and no socket command can clear
  the halt — resume is a menu-bar action only.
- **A lock is never bypassed.** The daemon works through a locked screen by
  reading accessibility trees that macOS already exposes; it never enters
  credentials, installs a SecurityAgent plugin, or touches the authorization
  database, and it refuses the login window, SecurityAgent, and the screen
  saver as targets by name or pid. Auto-unlock is a declared non-goal.

Reports that demonstrate a break in any of these — the daemon executing or
installing unverified code or weights, a socket peer accepted without passing
the signature requirement, ghost or hardware input delivered past the presence
and lock gates, an un-haltable action, or input reaching a credential surface —
are in scope and especially valued.

## Out of scope

- The calling agent or harness misusing verbs it is legitimately allowed to
  invoke. Rocuronium is an actuator; deciding *what* to do is the caller's
  responsibility, and a trusted caller can move the cursor or type by design.
- A same-uid process driving the socket through the embedded CLI. That is the
  documented boundary, not a bypass of it; such a caller is logged and subject
  to every gate above.
- Anything requiring the attacker to already control the signed app or the
  user's login session.
