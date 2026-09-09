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

- **Socket access is restricted to the app itself.** The control socket
  authenticates each peer by its audit token against a Developer ID team
  anchor: a caller must be same-uid *and* signed by the project's identity. A
  same-uid process that is not the signed app is rejected.
- **The cursor is never taken without opt-in.** Ghost delivery (accessibility
  writes, per-process posted events) is the default and moves nothing the human
  can see. Hardware input — the only path that moves the real cursor — requires
  an explicit per-call flag and is refused while a human is present, while the
  screen is locked, or while another window occludes the target.
- **The human is never locked out.** Ctrl+Option+Shift+Escape halts all
  activity within one cursor sample (~8 ms), and no socket command can clear
  the halt — resume is a menu-bar action only.
- **A lock is never bypassed.** The daemon works through a locked screen by
  reading accessibility trees that macOS already exposes; it never enters
  credentials, installs a SecurityAgent plugin, or touches the authorization
  database. Auto-unlock is a declared non-goal.

Reports that demonstrate a break in any of these — a non-app process driving
the socket, ghost or hardware input delivered past the presence and lock gates,
an un-haltable action, or credential entry — are in scope and especially
valued.

## Out of scope

- The calling agent or harness misusing verbs it is legitimately allowed to
  invoke. Rocuronium is an actuator; deciding *what* to do is the caller's
  responsibility, and a trusted caller can move the cursor or type by design.
- Anything requiring the attacker to already control the signed app or the
  user's login session.
