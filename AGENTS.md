# Meu Widget, a Droplet for Droppy

<!-- Written by `droppykit agent`. Add your own notes below; the file is only rewritten with --force. -->

This package is a **Droplet**: an extension that runs inside Droppy, the
Dynamic Island and shelf for Mac, written in SwiftUI against **DroppyKit**.
Droppy loads the built `.droplet` bundle into its own process and draws it on
the notch, the shelf, the lock screen and the menu bar.

- Droplet id: `meuwidget`. It is also `MeuwidgetDroplet.id` in Swift and `id` in `droplet.json`; the three must agree or the loader refuses the bundle.
- Swift product: `Meuwidget`, a dynamic library. The harness target is `MeuwidgetHarness`.
- SDK checkout: `/Users/mattrocha/droppykit` (DroppyKit 1.2.0). Docs online: https://getdroppy.app/docs/droppykit
- Host: Droppy 15.3 or later, or the free Droppy Playground (https://getdroppy.app/download/playground), which loads unsigned bundles.

## The loop

Every change goes through all of this, in order. A droplet can compile,
validate and then draw nothing, so a green build is not the end.

1. Edit `Sources/Meuwidget/`. The manifest is `droplet.json`.
2. `droppykit build` writes `.build/Meuwidget.droplet`, universal, linked against the
   framework Droppy ships. Never a bare `swift build` for the bundle: it folds a second
   copy of DroppyKit into the droplet, and that bundle loads in the harness and dies
   inside Droppy at dyld with "Symbol not found".
3. `droppykit validate` runs the exact checks the Store's intake runs.
4. `droppykit run -- --shots ./shots --report ./shots/report.json` renders every surface
   to a PNG without opening a window and writes a JSON verdict. Look at the pictures.
   Read `report.json`: `problems` must be empty and every surface you declared must be
   `provided`.
5. Put the bundle into Droppy Playground and confirm it loaded. Copy
   `.build/Meuwidget.droplet` to
   `~/Library/Application Support/Droppy Playground/Droplets/meuwidget/Meuwidget.droplet`,
   relaunch the Playground, and read its Store row: the subtitle is the loader's verdict.

With the DroppyKit MCP server connected, the same steps are the tools `droppykit_build`,
`droppykit_validate`, `droppykit_shots` and `droppykit_install`, and `droppykit_shots`
returns the images inline. This package carries the server in `.mcp.json` (Claude Code)
and `.cursor/mcp.json` (Cursor). Codex: `codex mcp add droppykit -- /Users/mattrocha/droppykit/Scripts/droppykit mcp`.
The other tools are `droppykit_manifest` (a static check, no build), `droppykit_docs`
(the guides and a search over the SDK sources), `droppykit_doctor`, `droppykit_new`,
`droppykit_open_harness` and `droppykit_submit`.

`droppykit run` with no arguments opens the harness window for a person: Droppy's own
Settings panel with a page per surface. You cannot see that window. The shots are your
eyes; take them after every visual change.

## Rules

- **Surfaces and conformances agree.** `surfaces` in `droplet.json` lists what the droplet
  provides; the droplet conforms to the matching protocol for each of them and to nothing it
  does not list. Disagreement is the most common reason a droplet validates and then does
  nothing.
- **Every shelf widget declares both widths.** `preferredSoloWidth` and
  `preferredPairedWidth` are required; Droppy refuses a descriptor that leaves either to a
  host fallback. Solo and paired are different compositions, not one view at two widths:
  branch on `context.isPaired`.
- **Everything `activate(host:)` starts, `deactivate()` stops.** Timers, observers, tasks,
  connections. Swift cannot unload code, so anything left running runs until Droppy
  relaunches.
- **Host calls are gated by `capabilities`.** A service call without its capability in
  `droplet.json` is refused: it returns `false` or `nil` and logs one line. Declare what you
  use and only that; the user sees the list.
- **The principal class does nothing.** `MeuwidgetPrincipal` is `@objc`, is named in the
  bundle's `NSPrincipalClass`, and only creates the droplet. It runs before the host is ready.
- **No `main.swift`.** The harness entry is `@main` in
  `Sources/MeuwidgetHarness/MeuwidgetHarness.swift`, and a file named `main.swift` cannot
  coexist with `@main`.
- **Look like Droppy, not like a guest.** Surfaces are dark. Foreground colours come from
  `AdaptiveColors`, spacing from `DroppySpacing`, radii from `DroppyRadius` with
  `style: .continuous`. No borders or outlines, no gradients, no ALL-CAPS labels, sentence
  case everywhere, and never paint your own background on a widget. Settings panes are built
  from `DropletSettingsCard`, `DropletControlRow`, `DropletToggleRow`, `DropletStackedRow`
  and `DropletSliderRow`.
- **`droplet.json` is the truth for the build.** `Info.plist` is generated from it.
  `version` is numeric `major.minor.patch`; `summary` is at most 60 characters;
  `minAppVersion` stays `15.3.0` unless the droplet needs something newer; `kit.minAPI` is
  the oldest DroppyKit API the droplet actually calls.
- **Do not edit anything under `/Users/mattrocha/droppykit`.** That is the SDK checkout; fixes there go
  upstream. This package is where the work is.

## Where the truth is

Read these before guessing at an API. They are on disk, in the SDK checkout.

- Guides, as Markdown: `/Users/mattrocha/droppykit/Sources/DroppyKit/Documentation.docc/`
  `CreateYourFirstDroplet.md`, `DropletSetup.md`, `DesignGuidelines.md`, `ShelfWidgets.md`,
  `LiveActivities.md`, `ExpandedSurfaces.md`, `SettingsPanes.md`, `Icons.md`, `Harness.md`,
  `HostSupport.md`, `Playground.md`, `Submitting.md`, and `BuildWithCodingAgents.md` for this
  workflow in full.
- The surface protocols, one file each: `/Users/mattrocha/droppykit/Sources/DroppyKit/Capabilities/`
- The host services a droplet calls: `/Users/mattrocha/droppykit/Sources/DroppyKit/Services/DropletServices.swift`
  and `/Users/mattrocha/droppykit/Sources/DroppyKit/Core/DropletHost.swift`
- The manifest type, with every field documented: `/Users/mattrocha/droppykit/Sources/DroppyKit/Bundle/DropletManifest.swift`
- Design tokens and the settings components: `/Users/mattrocha/droppykit/Sources/DroppyKit/DesignSystem/`
- A complete droplet that uses every surface: `/Users/mattrocha/droppykit/Examples/WorldClock/`
- The compatibility promise and the version ledger: `/Users/mattrocha/droppykit/COMPATIBILITY.md`

## Surfaces

| `surfaces` value in droplet.json | Conform to | Shot |
| --- | --- | --- |
| `shelf-widget` | `ShelfWidgetProviding` | `shelf-widget.png` |
| `live-activity` | `LiveActivityProviding` | `live-activity.png` |
| `expanded-surface` | `ExpandedSurfaceProviding` | `expanded-surface.png` |
| `settings-pane` | `SettingsPaneProviding` | `settings-pane.png` |
| `hud` | `HUDPresenting` | `hud.png` |
| `lock-screen-status` | `LockScreenStatusProviding` | `lock-screen.png` |
| `menu-bar-extra` | `MenuBarExtraProviding` | `menu-bar.png` |

`overview.png` shows the identity card with a verdict pill per surface, `capabilities.png`
the capability switches, `preferences.png` every stored value, and `activity.png` every host
call in order, refused ones marked.

## Done means

- `droppykit build` and `droppykit validate` both pass.
- The report's `problems` is empty and `activation.error` is null.
- You have looked at the shot of every surface you touched.
- The bundle loaded in Droppy Playground: `droppykit_install` says loaded, or the Store row
  shows it switched on.
- `droplet.json` still describes what the code does: surfaces, capabilities, summary.

## Package layout

```
Package.swift                     product Meuwidget (dynamic) and MeuwidgetHarness
droplet.json                      the manifest; Info.plist is generated from it
Sources/Meuwidget/              the droplet
Sources/MeuwidgetHarness/       the @main harness entry; never main.swift
Meuwidget.icon/                 Icon Composer document, required
Assets/Creator.png                square creator avatar, at least 256px, required
.build/Meuwidget.droplet        what droppykit build writes
AGENTS.md, CLAUDE.md, .cursor/    this brief and the agent wiring
.mcp.json, .cursor/mcp.json       the DroppyKit MCP server; absolute paths for this Mac
```

## Submitting

Droppy itself only loads droplets the Store review signed, which is why the Playground
exists. When the droplet is done: replace the placeholder icon and creator avatar, fill in
`creator` and `source` in `droplet.json`, push the repository, and run `droppykit submit`. It
opens getdroppy.app/submit-droplet with the repository, commit and id filled in.
