# When the tree is empty: vision

About a sixth of popular macOS apps expose no usable accessibility tree. Rocuronium's answer has three tiers, tried only when the previous one fails.

1. **Accessibility** — everything in reference/targeting-and-observing.md and reference/acting.md. Free, exact, works behind a lock.
2. **Detector + OCR** — when `click --label` or `type --label` finds nothing in the tree, the engine captures the target's window and looks for the label as legible text; a hit becomes coordinates, delivered through the normal tentacles by hit-test, and the reply says `groundedBy: "detector"`. Needs Screen Recording. The **UI Detector** (a YOLOv11n trained on GroundCUA, a 5.4 MB CoreML model, ~8 ms per window, a download from the Settings window) proposes control boxes so icon-shaped controls resolve too; the box is labeled from the text inside it. It is single-class — a box means "a control is here", the role comes from that OCR text. Without it, this tier is OCR only. If the model is installed but fails to load, the engine says so ("UI Detector model is installed but failed to load … using OCR only") rather than silently reporting no controls.
3. **Local VLM** — when OCR cannot match (icon-only targets, loose phrasing), a local grounding model (Holo 3.1 4B via MLX) turns the instruction plus the window into a point, `groundedBy: "vlm"`. Loaded on first use, evicted after five idle minutes. The model is a download from the Settings window (⌘, in the popover), never bundled; without it the tier is skipped.

Vision-grounded coordinates are less certain than tree-resolved ones: the `groundedBy` field is your cue to verify with a `screenshot --since` or a `read --since`. When all three fail, the error names it: "'Send' (AX tree empty, vision grounding found nothing)".

For your own eyes there is `screenshot` (reference/targeting-and-observing.md), and for text the tree does not carry, `scroll --until-text` (reference/acting.md). To read an AX-dead window as rows rather than ground a single click, `read --ocr` and `find --ocr` return text — and, with the UI Detector installed, control boxes — with screen-point frames.
