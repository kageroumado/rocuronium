# Delete candidates

Looks dead; scope or origin unverified. Kiri confirms → it goes.

## `Rocuronium/Vision/FoundationModelsBackend.swift` — the whole backend
- **What**: the `FoundationModelsBackend` type — `locate` returns `[]`, `judge` is a `TODO` stub returning `happened: false`; it conforms to `GroundingBackend` but does nothing.
- **Looks dead because**: the type name appears in no other file — it is instantiated and selected nowhere.
- **Not deleted because**: it may be intentional scaffolding for the planned vision-grounding tier (Foundation Models path), not leftover — can't tell whether roadmap work depends on it landing.
- **To confirm**: `rg 'FoundationModelsBackend' ~/Developer/rocuronium`, or ask Kiri whether the FM grounding tier is still planned.
- **Found**: 2026-09-07

## `RocuroniumTests/RocuroniumTests.swift:8-12` — `example()`
- **What**: the `example()` test and its stock-template body comments.
- **Looks dead because**: it is the unedited Xcode Swift Testing template stub — it asserts nothing (`#expect` never called) and carries only placeholder comments.
- **Not deleted because**: it is the file's only test; removing the whole test (or file) is a call for Kiri, though it provides zero coverage as written.
- **To confirm**: ask Kiri, or delete once real tests live elsewhere.
- **Found**: 2026-09-07
