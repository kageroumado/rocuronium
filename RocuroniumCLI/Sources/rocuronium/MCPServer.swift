import Foundation

// The MCP face of the control socket: `rocuronium mcp` speaks Model Context Protocol over
// stdio so agent harnesses get typed tools instead of shelling out to the CLI.
//
// Deliberately minimal. The server implements exactly the four requests a tools-only MCP
// server needs (initialize, ping, tools/list, tools/call) by hand — a dependency-free JSON-RPC
// loop is ~150 lines, and pulling in an SDK would mean a second build product to sign and
// notarize. Every tool call is translated to the same JSON the CLI sends and forwarded to
// Rocuronium.app through the authenticated socket; the reply comes back verbatim as text, so
// the agent sees the identical evidence a CLI user would.
@MainActor
enum MCPServer {
    private static let protocolVersion = "2024-11-05"

    /// Tool definitions mirror the socket commands one-to-one. The descriptions carry the
    /// safety semantics — an agent picks tools by reading these, so the cursor and evidence
    /// guarantees belong here, not only in documentation.
    static let tools: [[String: Any]] = [
        tool(
            "status",
            """
            Presence and capability report: whether a human is at the keyboard, whether the \
            display can be seen, whether the cursor may be taken, whether the engine is \
            halted (⌃⌥⇧⎋) and why (haltReason — the chord, or a plan that paused for the \
            human), and what holds the display awake. Every action reply also carries \
            the presence block. Cheap and safe to poll.
            """,
            properties: [:], required: [],
        ),
        tool(
            "diag",
            "What each permission check actually returns (Accessibility, Screen Recording) and what a real 16×16 capture attempt does. Run before guessing at permission state.",
            properties: [:], required: [],
        ),
        tool(
            "find",
            """
            List elements of a running app via accessibility: a page (20 by default, \
            `limit`/`offset` to page, `all` for every element with a frame) of rows of {role, \
            label, roleDescription, help, identifier, subrole, value, depth, frame, near}, \
            frames in screen points with a top-left origin. `label` is the element's OWN name \
            (title/description/placeholder) and is empty when it has none — an icon-only \
            control is `label:"", roleDescription:"button"`, often with `help` (its tooltip, \
            readable without hovering), `identifier` (SwiftUI's accessibilityIdentifier, \
            frequently the symbol name), and `near` ("right of 'Undo'"): match on those and \
            aim by frame. Give `label` to search by case-insensitive substring of the title, \
            description, or placeholder (element *values* are the fallback tier, so text \
            seen in `read` output is findable); give `role` alone to list every element of \
            that role; omit both to list editable fields. `truncated:true` means the walk \
            stopped, not that nothing else exists. When the tree yields nothing and Screen Recording is granted, `find` \
            falls back to OCR automatically; pass `ocr:true` to force it. Vision rows come back \
            as {role:'OCRText', label:<text>, frame, groundedBy:'ocr'} with `shown`/`total` \
            counts — text with screen-point frames for a window whose tree is empty or lying. \
            With the UI Detector model installed, control boxes also come back as \
            {role:'UIElement', label, frame, groundedBy:'detector', confidence} — each labeled \
            from the text inside it, so an icon-only control appears with an empty label and a \
            clickable frame.
            """,
            properties: [
                "app": ["type": "string", "description": "App name or bundle id, e.g. 'Discord'"],
                "label": ["type": "string", "description": "Substring of the element's label/placeholder"],
                "role": ["type": "string", "description": "Element role filter, e.g. 'button' or 'AXButton'"],
                "all": ["type": "boolean", "description": "List every element carrying a frame, not just editables ('show me everything'); role still narrows"],
                "limit": ["type": "number", "description": "Page size (default 20); reply carries shown/total/offset"],
                "offset": ["type": "number", "description": "Skip this many matches — page with limit"],
                "ocr": ["type": "boolean", "description": "Read the window's pixels instead of the tree — text rows groundedBy ocr, plus control boxes groundedBy detector when the UI Detector model is installed (needs Screen Recording)"],
            ], required: ["app"],
        ),
        tool(
            "read",
            """
            Read an app's text via accessibility — static text, field values, button titles, \
            checked states — with no pixels and no model. Orders of magnitude cheaper than a \
            screenshot for text-shaped questions, and it works while the screen is locked \
            (though not while the display sleeps; the reply refuses honestly then). Give \
            `label` to read one element's subtree; omit it for the whole main window. \
            Web page content that exposes no accessibility text is reported with a referral \
            naming the channel that can read the DOM — an empty dump there means 'hidden', \
            never 'blank page'. Every reply carries an observation `token`; pass it back as \
            `since` on the next read of the same scope to get ONLY what changed — elements \
            appeared/vanished and values old → new — instead of the whole window. A token \
            that cannot be diffed honestly (evicted, different window, truncated walk, \
            wholesale change) degrades to a full read with `diffNote` naming why. When the \
            whole-window walk finds no text and Screen Recording is granted, `read` falls \
            back to OCR automatically; pass `ocr:true` to force it. Vision rows come back as \
            {role:'OCRText', value:<text>, frame, groundedBy:'ocr'} in reading order, with no \
            token or delta — the answer for a window whose accessibility tree is empty. With \
            the UI Detector model installed, control boxes join as {role:'UIElement', value, \
            frame, groundedBy:'detector', confidence}, so an icon toolbar reads as addressable \
            controls rather than blank space.
            """,
            properties: [
                "app": ["type": "string"],
                "label": ["type": "string", "description": "Read just this element's subtree; the main window when omitted"],
                "role": ["type": "string", "description": "Narrow the label match by element role"],
                "since": ["type": "string", "description": "Observation token from a prior read of the same scope; reply becomes the structural delta"],
                "ocr": ["type": "boolean", "description": "Read the window's pixels instead of the tree — text rows groundedBy ocr, plus control boxes groundedBy detector when the UI Detector model is installed (needs Screen Recording)"],
            ], required: ["app"],
        ),
        tool(
            "apps",
            "List running apps (the set a human would see in the Dock): name, bundle id, pid, frontmost, hidden, launchedAt (ISO 8601) and bundlePath. The last two distinguish two running instances of one bundle id — pick the pid by start time or path, never blindly. Read-only.",
            properties: [:], required: [],
        ),
        tool(
            "windows",
            "List an app's windows: title, frame, minimized, main, which display each is on and whether that is the virtual one (rows on the virtual display that nobody parked are flagged 'stray'). Read-only. Use before aiming a click, park, or capture.",
            properties: [
                "app": ["type": "string"],
            ], required: ["app"],
        ),
        tool(
            "wait",
            """
            Block until a condition holds, polling accessibility. Give `label` (with optional \
            `gone`) to watch one element appear or disappear, or `expect` — the same guard \
            object a plan step uses — for the richer grammar: {type:'window-appears'|\
            'window-vanishes', title}, {type:'text-visible'|'text-vanishes', label}, \
            {type:'quiet', ms} (the window's tree holds still for ms — how "finished loading" \
            is detected), or {type:'token-changed', token} (anything differs from a prior \
            whole-window read token — "wait until something changes"). `timeout` caps at 25 \
            seconds because the control socket cancels requests at 30 — a timed-out reply sets \
            callAgain:true and is not an error to retry differently; just call again to keep \
            waiting. `ok` mirrors whether the condition was met.
            """,
            properties: [
                "app": ["type": "string"],
                "label": ["type": "string", "description": "Substring of the element's label to watch for (the sugar form)"],
                "role": ["type": "string", "description": "Narrow the label match by element role"],
                "gone": ["type": "boolean", "description": "Wait for the element to disappear instead"],
                "expect": ["type": "object", "description": "A guard object to poll until it passes; supersedes label/gone"],
                "timeout": ["type": "number", "description": "Seconds to block, 1–25 (default 10)"],
            ], required: ["app"],
        ),
        tool(
            "launch",
            "Launch an app without taking focus, and return only once its accessibility tree answers — ready:true means 'you can drive it now', not merely 'the process started'. Reports alreadyRunning when it was. Refused while the frontmost app is fullscreen unless `confirm` is true: the new app's first window switches Spaces and drops the human out of their game.",
            properties: [
                "app": ["type": "string", "description": "App name, bundle id, or full path"],
                "confirm": ["type": "boolean", "description": "Launch even though a fullscreen app would be interrupted"],
            ], required: ["app"],
        ),
        tool(
            "activate",
            """
            Bring an app to the foreground, taking focus — the one thing the ghost verbs \
            promise never to do, offered deliberately as a named, gated verb. Refused while a \
            human is present or recently active unless `confirm` is true, and refused while the \
            frontmost app is fullscreen (activating another app switches Spaces and drops the \
            human out of their game) unless `confirm` is true. Use when background delivery is \
            not dependable (AppKit apps never validate menus in the background) and bringing the \
            app forward is the honest option. Read-back confirms whether the target actually \
            came forward.
            """,
            properties: [
                "app": ["type": "string"],
                "confirm": ["type": "boolean", "description": "Take focus even though someone is at the Mac or a fullscreen app is up"],
            ], required: ["app"],
        ),
        tool(
            "type",
            """
            Put text into a field without taking the cursor or focus. Through accessibility \
            this SETS the field's value to `text`, replacing what was there, confirmed by \
            read-back; when that write is refused or ignored it falls through to keystrokes, \
            which insert at the caret — the reply's `tentacle` says which happened. Targets \
            the focused element unless `label` is given. Control characters are refused \
            unless `submit` is true, so a newline cannot send a message by accident. Pass \
            empty text explicitly to clear a field. Electron accepts unicode keystrokes and \
            ignores keycodes.
            """,
            properties: [
                "app": ["type": "string"],
                "text": ["type": "string", "description": "The text to put in the field (empty string clears it)"],
                "label": ["type": "string", "description": "Target field's label; the focused element when omitted"],
                "role": ["type": "string", "description": "Narrow the label match by element role"],
                "submit": ["type": "boolean", "description": "Allow Return/Tab in the text"],
                "allowHardwareInput": ["type": "boolean", "description": "Permit the cursor-taking tentacle as a last resort"],
            ], required: ["app", "text"],
        ),
        tool(
            "click",
            """
            Click an element by label or screen point (points, top-left origin), ghost-first: \
            an accessibility press, then a posted click only when the element exposes no press \
            action, then hardware only with `allowHardwareInput`. The verdict says what \
            observably happened; an accepted press that verifies `noEffect` does not escalate, \
            because pixels miss small consequences (a counter changing elsewhere in the \
            window measured as pixelDelta 0) — confirm with `read` + `since` instead of \
            retrying. Window-count and whole-window pixel evidence are added automatically, \
            as is the window's accessibility-tree diff: `treeChanges` counts what moved and \
            `treeDelta` renders it (a sibling label ticking 'clicks: 0' → 'clicks: 1' that \
            no pixel diff can see), and any tree change confirms the click on its own. \
            When a label matches several roles, pass `role`. A point on a plain group ascends \
            to the enclosing pressable control (SwiftUI wraps buttons this way). When the \
            accessibility tree has no match, vision grounding (OCR, then a local VLM if \
            installed) resolves the label to coordinates and the reply says `groundedBy`. \
            `button:'right'` opens a context menu (via AXShowMenu cursor-free where the \
            element exposes it, else a posted right-click — a menu appearing is the window it \
            watches for); `count:2` double-clicks; `modifiers` ("cmd,shift") are held during \
            the click. A non-plain click has no AXPress equivalent, so it is delivered as a \
            posted event and verified by pixels/tree/window-count rather than a press read-back. \
            A SwiftUI gesture-only view (an `.onTapGesture` inside a ScrollView) exposes no \
            accessibility action and swallows the posted click; with `allowHardwareInput` the \
            reach escalates to a real click, and without it the reply suggests that path. Set \
            `foreground` when the click must raise a system permission prompt (TCC, \
            notifications): a ghost press does not activate the app or move the cursor, so the \
            system withholds the prompt — foreground activates the app and clicks with the real \
            cursor so the gesture is genuine.
            """,
            properties: [
                "app": ["type": "string"],
                "label": ["type": "string", "description": "Substring of the element's label to click"],
                "role": ["type": "string", "description": "Narrow the label match by element role, e.g. 'button'"],
                "x": ["type": "number", "description": "Screen point, top-left origin (from find/windows frames or a screenshot rect)"],
                "y": ["type": "number", "description": "Screen y, paired with x"],
                "button": ["type": "string", "enum": ["left", "right"], "description": "right opens a context menu"],
                "count": ["type": "number", "description": "Clicks: 1 (default) or 2 for a double-click"],
                "modifiers": ["type": "string", "description": "Held modifiers, comma-separated: cmd,shift,option,control,fn"],
                "allowHardwareInput": ["type": "boolean", "description": "Permit the cursor-taking tentacle as a last resort"],
                "foreground": ["type": "boolean", "description": "Skip the ghost tentacles: activate the app and click with the real cursor so the press is a genuine gesture that can raise a system permission prompt (TCC, notifications). Implies allowHardwareInput; presence-gated like activate"],
                "observe": ["type": "boolean", "description": "Diff the AX tree even on a large window the channel would otherwise skip (adds one walk)"],
            ], required: ["app"],
        ),
        tool(
            "shortcut",
            """
            Deliver a keyboard shortcut (e.g. 'cmd+a') by pressing the menu item that carries it — \
            works on Chromium, which ignores synthetic keycodes. Dependable on the frontmost app, \
            best-effort in the background; trust the verdict, not the return.
            HAZARD: every app's menu bar includes the Apple menu, so session-wide items are reachable \
            from any target — cmd+shift+q resolves to Log Out. Items that end the session or destroy \
            data are refused unless `confirm` is true. Use `resolveOnly` to see which menu item a \
            shortcut maps to before pressing it. Window-count, selection, whole-window pixel, \
            and accessibility-tree-diff evidence (`treeChanges`/`treeDelta`) are added \
            automatically.
            """,
            properties: [
                "app": ["type": "string"],
                "keys": ["type": "string", "description": "cmd+a, cmd+shift+z, cmd+left, ..."],
                "resolveOnly": ["type": "boolean", "description": "Report the menu item without pressing it"],
                "confirm": ["type": "boolean", "description": "Permit a session- or data-destroying item"],
                "observe": ["type": "boolean", "description": "Diff the AX tree even on a large window the channel would otherwise skip (adds one walk)"],
            ], required: ["app", "keys"],
        ),
        tool(
            "scroll",
            """
            Reach off-screen content without touching the cursor. Prefer `label` + any `dy`: \
            the app is asked to bring that element into view (AXScrollToVisible — the one \
            cursor-free scroll mechanism that works, measured), confirmed by the element's \
            frame moving. `to` (0=top … 1=bottom) writes the vertical scroll bar where one \
            exists — some AppKit views expose one; Chromium/Electron never do. Bare `dy`/`dx` \
            falls back to posted wheel events, which every toolkit measured so far ignores — \
            an honest noEffect there means "use label instead", not "retry harder". \
            `untilText` scrolls deterministically to a string the AX tree may not even \
            contain: each step captures the window and OCRs it locally, stopping the moment \
            the text is legible; the reply's foundAt rectangle is ready for a coordinate \
            click, and callAgain:true means the step budget ran out with document left.
            """,
            properties: [
                "app": ["type": "string"],
                "label": ["type": "string", "description": "Element to bring into view (the mechanism that actually works)"],
                "role": ["type": "string", "description": "Narrow the label match by element role"],
                "dy": ["type": "number", "description": "Vertical pixel delta; positive reveals content below (with untilText: just the direction sign)"],
                "dx": ["type": "number", "description": "Horizontal pixel delta"],
                "to": ["type": "number", "description": "Absolute vertical position, 0 (top) to 1 (bottom)"],
                "untilText": ["type": "string", "description": "Scroll until this string is legible in the frame (local OCR per step; needs Screen Recording)"],
            ], required: ["app"],
        ),
        tool(
            "statusitem",
            """
            List an app's menu bar status items, or press one (press:true) to open its menu \
            or popover — cursor-free. Status items live in a separate extras menu bar that \
            no window walk or find reaches, so this is the only ghost path to a MenuBarExtra. \
            With several items, `label` picks one. Evidence: the target's window count — a \
            popover or status menu opening is a window appearing.
            """,
            properties: [
                "app": ["type": "string"],
                "label": ["type": "string", "description": "Pick one item by label when the app installs several"],
                "press": ["type": "boolean", "description": "Press the item (default: just list)"],
            ], required: ["app"],
        ),
        tool(
            "menu",
            """
            Press a menu item by title path, e.g. path "File > Export" ("▸" works too; \
            matching is case-insensitive and a trailing "…" is optional). Reaches every \
            command that has no keyboard shortcut. Same rails as `shortcut`: dependable on \
            the frontmost app, best-effort in the background (trust the verdict, not the \
            return); session- or data-destroying items are refused unless `confirm` is true; \
            `resolveOnly` reports the resolved item without pressing. A path that names a \
            submenu is refused with its items listed — go one level deeper. Window-count, \
            selection, whole-window pixel, and accessibility-tree-diff evidence \
            (`treeChanges`/`treeDelta`) are added automatically.
            """,
            properties: [
                "app": ["type": "string"],
                "path": ["type": "string", "description": "Menu title path, levels separated by '>' or '▸'"],
                "resolveOnly": ["type": "boolean", "description": "Report the resolved item without pressing it"],
                "confirm": ["type": "boolean", "description": "Permit a session- or data-destroying item"],
                "observe": ["type": "boolean", "description": "Diff the AX tree even on a large window the channel would otherwise skip (adds one walk)"],
            ], required: ["app", "path"],
        ),
        tool(
            "key",
            """
            Post a bare named key — escape, return, enter, tab, space, delete, forwarddelete, \
            left/right/up/down, home, end, pageup, pagedown — with optional modifiers \
            ('shift+tab', 'cmd+down'). The gap the other input verbs leave: `type` sends text \
            only and `shortcut` reaches only keys a menu item carries. Delivered per-pid \
            without touching cursor or focus. Measured reach: lands in the app's focused \
            text control (`return` in an address bar commits navigation) — but sheet \
            key-equivalents do NOT actuate on the per-pid channel: escape will not cancel \
            a save sheet. Press the sheet's button instead (click label 'Cancel' role \
            'button'), or pass allowHardwareInput for a session-level keystroke on the \
            console pipeline — gated like all hardware input (a present human refuses it \
            without confirm; locked screen always refuses) and only when the target is \
            frontmost, since it lands in global focus. Electron/Chromium ignore posted \
            keycodes entirely. For printable characters use `type`; for letter shortcuts \
            use `shortcut`.
            """,
            properties: [
                "app": ["type": "string"],
                "keys": ["type": "string", "description": "escape, shift+tab, cmd+down, ..."],
                "allowHardwareInput": ["type": "boolean", "description": "Deliver session-level on the console pipeline (reaches key-equivalent dispatch; target must be frontmost)"],
                "confirm": ["type": "boolean", "description": "With allowHardwareInput: proceed although a human is present"],
            ], required: ["app", "keys"],
        ),
        tool(
            "move",
            """
            Glide the REAL cursor along a path and leave it on the destination — the verb for \
            hover menus, tooltips, hover-intent flows, and anything that tracks pointer \
            motion. There is no ghost variant: per-pid posted motion is dropped by the window \
            server (measured), so this takes the physical cursor and is refused while a human \
            is present, or while the frontmost app is fullscreen (the cursor over the game \
            switches Spaces), unless `confirm` is true. Destination is `end` ("x,y" in screen \
            points) or an element by `label` (+`app`); `via` waypoints bend the path into a \
            smooth curve through them (glide from a nav tab down into its flyout). Starts \
            from the current cursor position unless `start` is given. Evidence: the cursor's \
            actual end position is read back, and with `app` the target's window count \
            before/after is reported — a flyout appearing is a window appearing. Caveats \
            measured: hover lands on whatever window is TOPMOST at the point (occlusion is \
            refused when `app` is given); WebKit/WKWebView pages ignore motion while their \
            app is not frontmost — `activate` first for web hover. With `app` given and the \
            target not frontmost, the verb activates it first (a focus change, reported). \
            What the hover revealed IS read back with `app`: the window's tree is diffed \
            across the gesture and reported as `treeChanges`/`treeDelta` (the tooltip or \
            flyout that appeared). Use `dwell` to hold longer for a slow tooltip (AppKit \
            shows them after ~1 s); leave `restore` off, since a restored cursor leaves \
            before the read and the reveal collapses.
            """,
            properties: [
                "end": ["type": "string", "description": "Destination \"x,y\" in screen points (top-left origin)"],
                "app": ["type": "string", "description": "Target app — enables label aiming, occlusion refusal, window-count and tree-diff evidence"],
                "label": ["type": "string", "description": "Aim at this element's center instead of end"],
                "role": ["type": "string", "description": "Narrow the label match by element role"],
                "start": ["type": "string", "description": "Path start \"x,y\"; current cursor position when omitted"],
                "via": ["type": "string", "description": "Waypoints the curve passes through: \"x,y x,y …\""],
                "duration": ["type": "number", "description": "Gesture seconds, 0.05–10; distance-based default"],
                "dwell": ["type": "number", "description": "Milliseconds to hold at the destination before reading the reveal (for slow tooltips)"],
                "easing": ["type": "string", "enum": ["linear", "ease-in", "ease-out", "ease-in-out"]],
                "restore": ["type": "boolean", "description": "Put the cursor back afterwards (defeats hover and its reveal — default off)"],
                "confirm": ["type": "boolean", "description": "Take the cursor even though someone is at the Mac"],
            ], required: [],
        ),
        tool(
            "drag",
            """
            Drag along a path with a mouse button held: down at `start`, real motion through \
            any `via` waypoints, up at `end`. Moves content, sliders, selection ranges, and \
            windows (title-bar drags work even on background windows, measured). Same \
            hardware-tentacle rules as `move`: takes the physical cursor, presence- and \
            fullscreen-gated behind `confirm`, occlusion at the start point refused when `app` \
            is given. An aborted \
            drag (lock/cancel mid-path) releases the button where it stopped — never left \
            held. Note: apps reading drag *deltas* get exact double-precision values; apps \
            reading positions get the same path — both measured working.
            """,
            properties: [
                "start": ["type": "string", "description": "Where the button goes down: \"x,y\""],
                "end": ["type": "string", "description": "Where it is released: \"x,y\""],
                "app": ["type": "string", "description": "Target app — enables occlusion refusal and window-count evidence"],
                "via": ["type": "string", "description": "Waypoints the drag curves through: \"x,y x,y …\""],
                "button": ["type": "string", "enum": ["left", "right"]],
                "duration": ["type": "number", "description": "Gesture seconds, 0.05–10; distance-based default"],
                "dwell": ["type": "number", "description": "Milliseconds to hold at the end before reading what changed"],
                "easing": ["type": "string", "enum": ["linear", "ease-in", "ease-out", "ease-in-out"]],
                "restore": ["type": "boolean", "description": "Put the cursor back after releasing"],
                "confirm": ["type": "boolean", "description": "Take the cursor even though someone is at the Mac"],
            ], required: ["start", "end"],
        ),
        tool(
            "busy",
            "Hold the presence overlay up while you work. Call `busy` with action 'on' (and an optional note) when you START a chain of steps, and again with 'off' when you FINISH — the jellyfish then stays visible through the thinking and waiting between commands, and vanishing means 'nothing more is coming', so the person can stop guarding their mouse. Renewable: any acting command renews the hold, and it self-releases after ~90 s if you go silent. Visual only, and only when the person has 'show overlay for every action' on — it never changes what the engine does.",
            properties: [
                "action": ["type": "string", "enum": ["on", "off"], "description": "'on' (default) raises the hold; 'off' releases it"],
                "note": ["type": "string", "description": "One line shown under the mark while held, e.g. 'moving the Finder window'"],
            ], required: [],
        ),
        tool(
            "display",
            "Manage the headless virtual display: action 'acquire' leases it (returns a lease id), 'release' gives one lease back (with --lease) or every lease at once (without) and sweeps parked windows home, 'status' reports leases (with seconds until each auto-expires), parked windows, and strays (windows on the display nobody parked). Windows parked there are invisible to the person at the Mac.",
            properties: [
                "action": ["type": "string", "enum": ["acquire", "release", "status"]],
                "reason": ["type": "string", "description": "Recorded on the lease — who/why"],
                "minutes": ["type": "number", "description": "Lease duration; 30 by default"],
                "lease": ["type": "string", "description": "Lease id, for release"],
            ], required: ["action"],
        ),
        tool(
            "park",
            "Move an app's primary window onto the virtual display (or to explicit x/y — the reply carries the previous position, which is the undo). Landing is read back as evidence. With no lease in force this takes an auto-lease (id in the reply) that releases itself — and sweeps its windows home — when the last parked window is returned or closes. Attaching the display is visually silent on the real screen (measured); the lease and the menu bar make it traceable.",
            properties: [
                "app": ["type": "string"],
                "x": ["type": "number", "description": "Destination screen x (with y) — omit both to park onto the virtual display"],
                "y": ["type": "number", "description": "Destination screen y, paired with x"],
            ], required: ["app"],
        ),
        tool(
            "resize",
            """
            Set a window's size (and, with x/y, its position) through accessibility — a ghost \
            AX write to kAXSizeAttribute/kAXPositionAttribute, no cursor and no focus change. \
            The answer for apps whose posted clicks read noEffect and whose AX name forces \
            --pid (a Wine window will not accept a synthetic drag on its resize corner but will \
            accept a size written directly). Width/height are in points. The resulting frame is \
            read back as evidence: verdict 'confirmed' when the frame landed within 2 pt, \
            'unverifiable' when it changed but was clamped (a fixed- or bounded-size window), \
            'noEffect' when nothing moved — never a lie. Presence-gated like activate, since it \
            visibly moves a window a person may be watching; refused while someone is present \
            unless confirm is true. Pass both x and y to reposition as well, or neither.
            """,
            properties: [
                "app": ["type": "string"],
                "w": ["type": "number", "description": "New width in points (at least 1)"],
                "h": ["type": "number", "description": "New height in points (at least 1)"],
                "x": ["type": "number", "description": "Reposition to this screen x as well (with y); omit both to resize in place"],
                "y": ["type": "number", "description": "Reposition to this screen y, paired with x"],
                "confirm": ["type": "boolean", "description": "Resize even though someone is at the Mac"],
            ], required: ["app", "w", "h"],
        ),
        tool(
            "plan",
            """
            Execute a sequence of commands with postcondition guards and failure policies. \
            Each step is an existing verb (click, type, scroll, etc.) with an optional \
            'expect' guard (verdict, readback-contains, window-appears, window-vanishes, \
            text-visible, text-vanishes, quiet, token-changed) and 'onFail' policy (abort, continue, \
            pause-for-human, or {\"fallback\": {step}}). A step's 'refs' map feeds a field from \
            an earlier step's reply — {\"refs\": {\"x\": \"$2.foundAt.cx\", \"y\": \
            \"$2.foundAt.cy\"}} clicks the center of the rectangle step 2 found (cx/cy are \
            derived from a {x,y,w,h} block). Profile 'ghost' (default) stays \
            invisible; 'visible' shows bezel narration per step with human pacing. The \
            reply is one transcript with per-step verdicts. ���⌥⇧⎋ aborts mid-plan.
            """,
            properties: [
                "profile": [
                    "type": "string", "enum": ["ghost", "visible"],
                    "description": "ghost (invisible, default) or visible (bezel narration per step)",
                ],
                "steps": [
                    "type": "array",
                    "description": "Array of command steps. Each step has 'command' plus the same fields as that command's tool, plus optional 'expect' (guard) and 'onFail' (policy).",
                    "items": ["type": "object"],
                ],
            ], required: ["steps"],
        ),
        tool(
            "activity",
            """
            The session's recent agent actions with their evidence verdicts (last 50, \
            newest last) — the same record the human sees in the menu bar. Read-only. Also \
            reports `halted`: true means the human pressed ⌃⌥⇧⎋ and every acting/perceiving \
            verb is refused until they resume from the Rocuronium menu bar — do not retry, \
            and do not attempt to work around it.
            """,
            properties: [:], required: [],
        ),
        tool(
            "demo",
            """
            Open Rocuronium's deterministic demo stage — a fixed practice window at \
            (720, 200), 560×720, with instrumented targets for every verb: a click counter, \
            a text field with an echo, a switch, a slider, a hover pad, and a 120-row \
            scroll list whose needle is 'Row 87 · the needle'. Drive it with app \
            'Rocuronium'; every consequence is readable back. Action 'reset' (default) \
            zeroes the counters, 'show' keeps state, 'hide' closes it.
            """,
            properties: [
                "action": ["type": "string", "enum": ["show", "reset", "hide"]],
            ], required: [],
        ),
        tool(
            "screenshot",
            """
            Capture pixels for the calling model to look at: an app's window \
            (occlusion-proof, works while parked), an explicit region, or the main display. \
            Returns the PNG path, pixel width/height, and `rect` in screen points. Every \
            reply carries an observation `token`; pass it back \
            as `since` on the next capture of the same target to get only the CHANGED \
            regions as small crops (count, screen rects, and paths) instead of the frame — \
            read a 300x200 popover crop, not the window. Large vertical translation is \
            reported as "content scrolled ~N" with an edge-strip crop of the newly revealed \
            content. A token that cannot be diffed (evicted, resized, different target, \
            wholesale change) degrades to a full capture with `diffNote` naming why. \
            `since` is incompatible with `path`.
            """,
            properties: [
                "app": ["type": "string"],
                "x": ["type": "number", "description": "Region origin x (top-left), with y/w/h — omit all four for the whole display"],
                "y": ["type": "number", "description": "Region origin y, paired with x"],
                "w": ["type": "number", "description": "Region width in points"],
                "h": ["type": "number", "description": "Region height in points"],
                "path": ["type": "string", "description": "Where to write the PNG. Must end in .png, must not already exist, and must be under Desktop, Downloads, Pictures, /tmp, or the app's captures folder. Omit for a default path."],
                "since": ["type": "string", "description": "Observation token from a prior capture of the same target; reply becomes changed-region crops or a scroll report"],
            ], required: [],
        ),
    ]

    /// The verbs that accept `--window` to scope to one of an app's windows. Added to their
    /// schemas centrally so the argument filter accepts it without repeating the property in
    /// each definition.
    private static let windowScopedTools: Set<String> = [
        "find", "read", "click", "type", "wait", "screenshot", "move", "drag", "park", "resize",
    ]

    private static func tool(
        _ name: String, _ description: String,
        properties: [String: Any], required: [String]
    ) -> [String: Any] {
        // Every tool that targets an app also accepts a pid, uniformly: it overrides `app`
        // and is the only unambiguous address when two instances share a bundle id.
        var properties = properties
        if var app = properties["app"] as? [String: Any], app["description"] == nil {
            // The one uniform meaning across every app-targeting tool — filled centrally so no
            // tool has to repeat it, and so the docs-consistency test's "every property has a
            // description" rule holds without noise.
            app["description"] = "App name or bundle id to target"
            properties["app"] = app
        }
        if properties["app"] != nil, properties["pid"] == nil {
            properties["pid"] = [
                "type": "number",
                "description": "Target this process id directly (overrides 'app') — for when two running instances share a name or bundle id",
            ]
        }
        if windowScopedTools.contains(name), properties["window"] == nil {
            properties["window"] = [
                "type": "string",
                "description": "Scope to the app window whose title contains this substring; ambiguity is refused with each candidate's 0-based index and frame",
            ]
            properties["windowIndex"] = [
                "type": "number",
                "description": "Disambiguate same-titled windows by 0-based position in the window list (the order 'windows' prints and the ambiguity error enumerates)",
            ]
            properties["windowAt"] = [
                "type": "string",
                "description": "Disambiguate by location: pick the window whose frame contains this \"x,y\" screen point",
            ]
        }
        return [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
            ] as [String: Any],
        ]
    }

    // MARK: - The loop

    /// Reads newline-delimited JSON-RPC from stdin until EOF. `forward` is the existing
    /// socket transport; each tool call becomes one socket round-trip.
    static func run(forward: ([String: Any]) -> [String: Any]?) -> Never {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                // A line that is not a JSON object carries no id we can echo, so the error id is
                // null per JSON-RPC — without it a conforming client waits forever for a reply.
                replyError(NSNull(), code: -32700, message: "parse error: line is not a JSON object")
                continue
            }
            let id = message["id"]
            guard let method = message["method"] as? String else {
                // A request (it has an id) with no method is invalid; a notification (no id) with
                // no method is a stray we can drop without leaving anyone waiting.
                if let id { replyError(id, code: -32600, message: "invalid request: no 'method'") }
                continue
            }

            switch method {
            case "initialize":
                reply(id, result: [
                    "protocolVersion": protocolVersion,
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "rocuronium", "version": "1.0"],
                ])
            case "ping":
                reply(id, result: [String: Any]())
            case "tools/list":
                reply(id, result: ["tools": tools])
            case "tools/call":
                guard let id else { break }  // a call needs an id to answer
                let parameters = message["params"] as? [String: Any] ?? [:]
                reply(id, result: call(parameters, forward: forward))
            default:
                // Notifications (no id) are fine to ignore; unknown *requests* get the
                // standard method-not-found so the client is not left waiting.
                if let id {
                    replyError(id, code: -32601, message: "method '\(method)' not supported")
                }
            }
        }
        exit(0)
    }

    private static func call(
        _ parameters: [String: Any],
        forward: ([String: Any]) -> [String: Any]?
    ) -> [String: Any] {
        guard let name = parameters["name"] as? String,
              tools.contains(where: { $0["name"] as? String == name })
        else {
            return errorContent("unknown tool '\(parameters["name"] ?? "?")'")
        }
        // Forward only the keys this tool declares. A schema is documentation, not a filter:
        // copying `arguments` wholesale would honor properties the tool never advertised —
        // `allowHardwareInput` smuggled into a tool whose schema has no such field, for
        // instance, escalating past the tentacles the description promised. `command` is assigned
        // after the copy so it can never be overridden by an argument.
        let declared = Set(schemaProperties(of: name))
        let arguments = (parameters["arguments"] as? [String: Any]) ?? [:]
        var payload = arguments.filter { declared.contains($0.key) }
        let rejected = arguments.keys.filter { !declared.contains($0) }.sorted()
        guard rejected.isEmpty else {
            return errorContent(
                "'\(name)' does not accept \(rejected.map { "'\($0)'" }.joined(separator: ", "))"
                    + " — accepted: \(declared.sorted().joined(separator: ", "))",
            )
        }
        payload["command"] = name
        guard let socketReply = forward(payload) else {
            return errorContent("could not reach Rocuronium.app — is it running?")
        }
        let text = (try? JSONSerialization.data(withJSONObject: socketReply, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return [
            "content": [["type": "text", "text": text]],
            "isError": socketReply["ok"] as? Bool != true,
        ]
    }

    static func schemaProperties(of tool: String) -> [String] {
        guard let definition = tools.first(where: { $0["name"] as? String == tool }),
              let schema = definition["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any]
        else { return [] }
        return Array(properties.keys)
    }

    private static func errorContent(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    // MARK: - Transport out

    private static func reply(_ id: Any?, result: [String: Any]) {
        guard let id else { return }
        emit(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func replyError(_ id: Any, code: Int, message: String) {
        emit(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func emit(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
