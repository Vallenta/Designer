# VallentaDesigner — Architecture

VallentaDesigner is a standalone Windows executable that opens form files
(`.dfm`) in designer windows, supports selecting, moving, resizing, reordering
and deleting the components they hold, and writes each file back in the text
format the RAD Studio IDE produces. A file is streamed into a stub root, so the
class the file declares does not have to be compiled into the program; that is
what allows an external editor to open arbitrary project forms.

**Correctness requirement: a byte-identical round trip.** Loading an untouched
file and saving it again reproduces the input byte for byte, event handler names
included. Every stage of the save pipeline exists to hold that property, and the
test suite measures it over the whole fixture set.

**One process, several documents.** The program runs as a resident core: a
hidden controller form holding the state that is set up once per process — the
loaded design packages, the hosted design-time layer, the streaming class
registry, the session log, the window registry, the named-pipe server and the
recovery journal — plus a notification-area icon. Document windows are created
and destroyed beneath it; closing the last one does not end the process. A
second invocation of the executable does not start a second designer: a named
mutex reports that one is already running, so the second process sends its file
down the pipe and exits.

**The designer reads and writes the `.dfm` file only.** Source edits — declaring
a field for a newly placed component, creating an event handler, renaming a
component — are sent as requests to the VS Code extension over the same pipe,
and the extension performs them in the `.pas` file. No code path in this program
writes a `.pas` file. A document opened while no session is attached designs
normally: the outstanding field and handler requests are held and re-sent when a
session attaches.

## Technology Stack

| Component | Technology |
|---|---|
| Language | Delphi (Object Pascal) |
| UI framework | VCL, Win32 target |
| Releases | Delphi 11.3 (`22.0`), 12 (`23.0`) and 13 (`37.0`) from one source tree — see Release Selection |
| Subsystem | GUI application. A start that reports a refusal writes to the caller's console when one was inherited; see Command Line |
| Build | IDE or MSBuild on `VallentaDesigner.dproj`, built with **runtime packages** (`rtl;vcl;designide`), so the IDE's `bin` directory must be on `PATH` at run time |
| Tests | DUnitX, `tests/VallentaDesignerTests.dproj` — a console program that exits with the number of failures. It links the same units and needs the same `PATH`; `rsvars.bat` puts the compiler and that release's runtime packages on `PATH` together |

Building and running the suite is one command. `rsvars.bat` must be invoked with
`call`, or the batch file does not return to the rest of the line:

```
cmd /c 'call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat" && cd /d "<repo>" && msbuild tests\VallentaDesignerTests.dproj /t:Build /p:Config=Debug /p:Platform=Win32 && tests\bin\Win32\Debug\37.0\VallentaDesignerTests.exe'
```

The release `rsvars.bat` selects decides the path of the test executable, which
ends in `$(ProductVersion)`: `37.0` above, `22.0` and `23.0` for the other two.
Running the binary of one release after building another runs whatever was built
previously and reports a suite that was never rebuilt.

The runner's own summary is truncated when its output is redirected; the exit
code is the result, and counting `Success.` lines is the cross-check. Two
`[warn]` lines reporting `TOleServer` as already known are the expected
duplicate-class report, and so is the line reporting that `basic_form.dfm` and
`crossversion_newer_property.dfm` both declare `TForm1`.

**The suite does not link the whole program.** `Shell.Core`, `Shell.MainWindow`,
`Shell.RecoveryDialog`, `Palette.Frame` and `Palette.Buttons` are compiled only
by the product build. A passing suite reports nothing about those five units;
they are covered by running the program.

## Release Selection

One source tree builds against Delphi 11.3, 12 and 13. The release a build
belongs to is never named by hand: it follows from the IDE that runs the build
and reaches the code as `CompilerVersion`.

`VallentaDesigner.Common.props` is imported as the **first** element of both
project files, because MSBuild evaluates in document order and the output paths
below it depend on what it sets. It carries the release as `$(ProductVersion)` —
`22.0`, `23.0`, `37.0` — rather than a variable of this project's own: the IDE
expands the path it launches for Run and Debug through its own
environment-variable list, and a name that is not on that list expands to
`%Name%` and fails the launch although the build succeeded. `$(ProductVersion)`
is on that list. The IDE supplies it, `rsvars.bat` does not, and the IDE's own
targets define it after the output paths are evaluated, so the props file seeds
it from `$(BDS)`.

Output lands under `bin\<Platform>\<Config>\<ProductVersion>\`, so three
releases' binaries stand side by side without a rebuild between them. Each build
binds its own `rtl<suffix>.bpl` and can load only that release's design
packages.

`Core.Settings` is the code half. Everything release-dependent is one constant
there, selected from `CompilerVersion`:

| Constant | Holds |
|---|---|
| `IdeVersion` | The version segment of the IDE's registry key and of its shared documents directory, for example `'23.0'` |
| `PackageSuffix` | The `LIBSUFFIX` this release gives its packages — `'290'` in `rtl290.bpl`. Not derivable from `IdeVersion` |
| `DesignerStyle` | The VCL style applied at startup, which must name the style inside the `.vsf` file the project links |
| `SettingsRoot` | `Software\VallentaStudio\Designer\<IdeVersion>` below `HKEY_CURRENT_USER`, so the three releases keep their settings separate |

An unrecognized `CompilerVersion` produces a `{$MESSAGE FATAL}` naming what to
add, rather than a default that builds against the wrong package suffix.

The style family differs by release: `Windows Modern` ships only with Delphi 13,
11 and 12 carry `Windows10`. Naming a style the release does not have fails the
resource step before the compiler runs, which is why the props file selects both
the style name and the `.vsf` file, and `Core.Settings` repeats the name for the
runtime call that applies it.

## Directory Structure

| Directory | Contents |
|---|---|
| `src/<Category>/` | The units, one folder per category (see Unit Layout), one level deep |
| `tests/` | The DUnitX suite: its project and its units, flat in one directory |
| `fixtures/` | The files the round-trip matrix runs over, each with a documented expectation. Some carry a companion `.pas` that exists only so the root classifier can read the ancestor out of it |
| `resources/` | The application icon (`VSForm.ico`, `Icons/`) and the splash artwork (`Splash/`) |
| `scripts/` | `build-all.ps1`, which builds every release and platform in turn |
| `docs/` | This document |
| `form-samples/` | Demo forms, not referenced by any test |
| `bin/`, `dcu/` | Build output and compiler intermediates under `<Platform>\<Config>\<ProductVersion>\`, for the designer and the suite alike. Not versioned |

## What the Repository Carries

The repository holds the designer's source, its tests, its fixtures, its
resources, its build scripts, its project files and its documents. `.gitignore`
is a deny list: it excludes what a build or an IDE session produces and leaves
everything else tracked.

| Excluded | Rules |
|---|---|
| Build output | `bin/`, `dcu/` |
| Compiler and linker products | `*.dcu`, `*.dcp`, `*.bpl`, `*.res`, `*.exe`, `*.dll`, `*.o`, `*.obj`, `*.drc`, `*.map`, `*.rsm`, `*.tds`, `*.otares` |
| IDE state, per machine and per session | `__history/`, `__recovery/`, `*.~*~`, `*.dsk`, `*.local`, `*.identcache`, `*.stat`, `*.tvsconfig` |
| Editor and agent files | `.vscode/`, `.idea/`, `.claude/`, `CLAUDE.md` |
| Runtime artifacts the designer writes | `*.log`, `*.ini` |

A new file is therefore tracked by virtue of being in the tree, and `.gitignore`
needs no change for a new unit, a new category folder or a new directory. The
`src/<Category>/` layout being one level deep, and `tests/` being flat, are
conventions of this tree rather than limits the ignore file imposes.

**`VallentaDesigner.res` is excluded and is not needed by a clone.** MSBuild's
`BuildVersionResource` target regenerates it on every build, from the version
information in the project file and from `Icon_MainIcon`, which names the tracked
`resources\VSForm.ico`. `VallentaDesigner.dpr` binds the result with `{$R *.res}`.

Line endings are normalized on the way in, so a working copy with LF commits the
same content as one with CRLF. Fixture files must still be CRLF on disk: that is
the writer's output format, not a version-control question.

Every `.pas` and `.dpr` opens with the five-line license header — program name,
product, copyright line, SPDX identifier, and the pointer to `LICENSE`. It covers
`src/`, `tests/` and the root, and deliberately not `fixtures/`: those are test
data, and a header would change the bytes the round-trip test compares. A new
unit takes the header from an existing one, unchanged.

## Unit Layout

Every unit carries the `Vallenta.FormEditor` prefix and the name of the folder it
sits in, so a unit's full name is `Vallenta.FormEditor.<Folder>.<Leaf>` and its
file is that name plus `.pas`. The prefix is required rather than decorative:
this program links `designide`, so its units share one global namespace with the
IDE's design-time units, and a flat `PropertyGrid` or `DesignSurface` is a name
one of those is likely to hold. This document and the code comments name a unit
by folder and leaf — `Streaming.Loader`.

The prefix is deliberately not in `DCC_Namespace`. With unit-scope shortening
on, `Core.ComponentRegistry` would be reachable as plain `Registry` and would
then collide with `System.Win.Registry` silently, because a unit's own namespace
is implicitly in scope. Every `uses` clause therefore names units in full.

### `Core` — units everything else may depend on

| Unit | Contents |
|---|---|
| `Core.Log` | `TLogSeverity` and `TDesignLog`. A listener list rather than a single event, because the session log is displayed in every window at once, and a `Limit`: the session log belongs to a process that may run for days, so it drops its oldest entries and reports drops on a separate listener channel |
| `Core.Console` | Console output for a GUI process. Resolves the target once — the inherited stdout handle when one exists, otherwise the parent process's console |
| `Core.Settings` | The release identity of this build and everything derived from it, selected from `CompilerVersion`: IDE version segment, package `LIBSUFFIX`, VCL style name, and the registry root user state is stored under. Reads and writes nothing itself |
| `Core.ArgumentFile` | Arguments read from the file `--config-file` names, for arguments a command line cannot hold: Windows caps one at 32767 characters, which a project search path can reach on its own. One argument per line, UTF-8 with or without a byte order mark |
| `Core.SearchPath` | Directories searched for form files beyond the document's own, needed when an ancestor form or frame class lives elsewhere in a project. One process-wide default plus an optional per-document override, both lock-serialized. Paths must arrive already macro-expanded |
| `Core.LoadedClasses` | Resolves a class name against the classes present in this process, design packages included, and reports what such a class descends from through `ClassParent`. Lookup order: the streaming registry, the qualified name built from a unit hint, then a one-time RTTI walk behind a lock |
| `Core.ComponentRegistry` | The built-in component classes and their palette groups in one declarative table, gated by `BuiltInClassesActive` and currently off while the design packages register those classes themselves, plus the entries loaded packages contributed. It sits in `Core` because the loader and the package host read it as well as the palette |
| `Core.SingleInstance` | The single-instance claim and the core's IPC: the named mutex, the pipe served beside it, the handover encode and decode, the session envelope, the command/event/field constant block that is the wire's single source of truth, the session server with its outbound queue, one thread per connection, and the client that routes a file into a running core |
| `Core.Sessions` | `TSessionRegistry` and `TDesignSession`: which clients are attached, which session a document's events belong to (opener first, else closest workspace, latest attach between equals), the requests this core sent and still awaits, and `EvaluateOrphan`, the rule an unused core ends itself by |
| `Core.Coupling` | `ICodeCoupling` and `TDocumentCoupling`: the per-document source coupling. Field emission at a settle point, the ledger resume that re-sends fields and the history's handlers at each reattach, `listMethods`, `ensureEventHandler`, `gotoHandler` and `renameComponent`, the event signature read from RTTI, the foreground grant, and `TRenameRegister` |
| `Core.FieldLedger` | The diff between the fields a document designs and the fields its unit has been told about. Entries move only on acknowledgement, so an unconfirmed change is reported again |
| `Core.Recovery` | The recovery journal: one folder per designer process, a lock file held open for its lifetime, a copy and a note per document, and the discovery that distinguishes an ended session from a running one |

### `Streaming` — the `.dfm` format and the load and save pipelines

| Unit | Contents |
|---|---|
| `Streaming.TextSpans` | The span scanner over the text form: blocks, property lines, and the splice that puts pieces back. `TDfmFragment` reads the other shape the same scanner sees, a list of top-level blocks with no root above them |
| `Streaming.RootClassifier` | What a form file's root block declares — keyword, class and object name — the three-stage decision of which kind of root it is, and `TDfmClassIndex`, which indexes a directory set's form files by root class and object name |
| `Streaming.EventNames` | Event-name preservation: `TEventNameMap`, `TEventAnchor`, `TDesignReader`, the interning of a handler wired in the inspector, and the rename that moves an interned name |
| `Streaming.Preserved` | Text a load could not turn into components, the placeholder controls that display it, and the names it reserves |
| `Streaming.Frames` | Which classes are frames, the file each is declared in, the live instances, and the untouched instance each class is measured against |
| `Streaming.Ancestors` | Which form files a document is built on, and the order they have to be read in |
| `Streaming.Loader` | File to stub root: format detection, root-kind check and classification, class registry, load policy, stub factory, load-state capture, embedding. Also which other form files a load read and why (`TSourceKind`), and `PrepareRecovered`, which reads a form file out of the recovery folder while it continues to belong to the path it came from |
| `Streaming.Saver` | The save pipeline and `RoundTripDfm`. `WriteTextAtomically` is exported because the journal replaces its notes the way a form file is replaced |
| `Streaming.Clipboard` | Component fragments: `WriteComponentFragment` writes a selection as consecutive blocks, `TFragmentReader` streams one back into a live document and carries the rename through the reader's name and reference callbacks. No clipboard access and no surface, so the suite drives it directly |

### `Packages` — loading component packages and what they register

| Unit | Contents |
|---|---|
| `Packages.PeImage` | The PE image format: machine type and imported module names from a file, the export table from a module mapped in this process |
| `Packages.Stacks` | Names code addresses for a package failure diagnosed from a log rather than a debugger: the RTL stack-info hooks, and each address reported as its module, the offset into it and the exported symbol below it. Win32 only, and not thread-safe |
| `Packages.Discovery` | The IDE's own package lists, its path variables resolved, and the default allow and exclusion lists |
| `Packages.Preflight` | The checks that reject a package before it is loaded: missing, wrong architecture, another release, already in the process |
| `Packages.Dependencies` | What a package imports, resolved and loaded deepest first and released in reverse. A module already mapped is reported as part of the chain but neither loaded nor unloaded |
| `Packages.Icons` | Component bitmaps read out of package files, exposed as an icon provider layered over the drawn-glyph one |
| `Packages.Host` | Reading both package lists, deciding about each candidate, the registration hooks, loading, finding and calling `Register`, the verdict recorded for every package, and the ordered unload |
| `Packages.ManagerDialog` | The Tools, Packages dialog: the list with its verdicts and the settings it writes |

### `DesignTime` — what the hosted design-time layer talks to

| Unit | Contents |
|---|---|
| `DesignTime.Designer` | `TVallentaDesigner`, the `IDesigner` implementation hosted editors are served from; the standard property-editor registrations that only the IDE would otherwise perform; and the exception-guarded wrappers around every editor call |
| `DesignTime.IdeServices` | The `BorlandIDEServices` stub that lets design packages load and register outside the IDE. Most services are inert; the installation directories and the IDE menu, action list, image list and toolbars are answered for real, as are the VCL dialogs on Delphi 12 and later. Every refused service is reported once per package load |
| `DesignTime.Environment` | The `IDesignEnvironment` implementation the design-time layer requires before it will build a component designer. 32 methods, of which `GetMainWindowSize` is the one with a real answer; the rest report themselves once each |

### `Surface` — the designer and what is drawn on and around a document

| Unit | Contents |
|---|---|
| `Surface.FormDesigner` | `TFormDesigner`: selection, input state machine, background painting, placement, dirty tracking, notifications, the save and close flow, z-order restacking, the read-only guard, the hosted designer the document holds, and the settled image. `WriteTo` writes the document to any path, which is what the journal writes through |
| `Surface.Handles` | `THandleSet` and `TDragFrame`: grab handles, the drag frame, and the outlines of a multiple selection. All are child windows with a nil `Owner`, and all are moved to the end of the tab list before the document is streamed |
| `Surface.Tiles` | The tiles that stand in for components without a window, and the dotted background they sit on. One set of routines paints both surfaces that show them |
| `Surface.TileLayer` | `TTileLayer`, the window the tiles of a form or frame are drawn in, raised above the designed controls so that a control repainting itself cannot erase one |
| `Surface.IconCanvas` | `TIconSurface`, the design surface for a data module |
| `Surface.Undo` | `TDocumentSnapshot` and `TUndoStack`: the document history, its coalescing rule, the saved-state bookkeeping, `PushImage` for a state captured earlier, and the created-handler marks a step carries |

### `Palette` and `Inspector` — the two panes with a model of their own

| Unit | Contents |
|---|---|
| `Palette.Model` | `TPaletteItem`, `TPaletteGroup`, `TPaletteModel`, `TPaletteFilter`, `IPaletteIconProvider` and the drawn-glyph provider |
| `Palette.Favourites` | The favourite pages and component classes, stored as registry value names under two subkeys of the settings root. Read once at construction and held in memory; a toggle changes memory first and then writes or deletes the single value |
| `Palette.Buttons` | The category button control, which draws a favourite star on every component row and page header. It stores no favourite state: the star state is queried while painting, and a press raises a toggle event |
| `Palette.Frame` + `.dfm` | The palette pane: categories, the search box and its filter, the favourites tab, creation-mode arming, double-click placement |
| `Inspector.PropertyModel` | The row model behind the property grid, with two sources — runtime type information, and the property editors of the loaded packages — typed apply, expansion, and per-row degradation |
| `Inspector.Grid` | The two-column grid with overlay editors, and the ellipsis button that opens a property's own dialog |
| `Inspector.Frame` + `.dfm` | Component tree, Properties and Events grids, two-way selection sync |

### `Shell` — the core and the windows it creates

| Unit | Contents |
|---|---|
| `Shell.Core` | `TDesignerCore`, the hidden controller form: the packages, the design-time layer, the session log, the session registry, the window registry, the tray icon and its menu, the pipe server, the journal timer, the recovery offer, and the shutdown sweep. `OpenDocument` is the single entry point, for the command line, the pipe and a recovery alike. It also serves the sessions: the request handlers, the four document events (with `opened` replayed at attach for documents opened while nothing was listening), the per-document coupling refresh, and the orphan check |
| `Shell.MainWindow` + `.dfm` | `TMainDesignerForm`, the window of one open document: zones, splitters, menu, actions, close flow, document lifetime, kind-aware presentation, the undo history and its restores, the read-only banner, and the document's coupling — history callbacks, the rename register, the settle point, and the handler roster a resume replays |
| `Shell.MessagesFrame` + `.dfm` | The severity-colored message list over two logs: the session log first and marked as such, then this document's, so a window opened later still shows what the packages reported at startup |
| `Shell.RecoveryDialog` | The documents an earlier session left unsaved, offered one row at a time. Built in code, and the one dialog here that is not OK/Cancel |
| `Shell.AlignDialogs` | The align, same-size, tab-order and creation-order dialogs, built in code rather than from form resources |
| `Shell.Layout` | `TLayoutStore` and `TDialogLayoutStore`: pane sizes, window size and resizable dialog geometry, as registry values under one key of this release. Sizes record the DPI they were measured at and are rescaled to the DPI they are read for |
| `Shell.SplashWindow` + `.dfm` | `TSplashForm`, the start-up window: backdrop and mark as pictures the form resource carries, status line and progress bar as controls over them. Shown only by a start that becomes the core, driven from the `.dpr` and from the package load's progress, and closed before the message loop |

### `tests` — the DUnitX suite, flat in one directory

| Unit | Covers |
|---|---|
| `Tests.Environment` | The fixture directory, the single package situation a run gets (`BeginDesignerSession` / `EndDesignerSession`), the package report, and the byte comparison every case measures with |
| `Tests.RoundTrip` | The fixture matrix, case for case |
| `Tests.SingleInstance` | The claim taken and released, a route that finds nothing, a file routed in, a file already open answered as focused, a refusal in the core's own wording, a non-ASCII path, and seven malformed requests each asserting its own reason |
| `Tests.Protocol` | The session protocol over a real pipe: envelope, sessions beside the handover, event routing by opener and workspace, the coupling's settle and resume emission, the created-handler marks through undo and redo, and the rename requests with their answers |
| `Tests.Coupling` | The rename rules against a real document with a stub editor at the far end: refusals before sending, the register, the answers and their application |
| `Tests.FieldDiff` | The field ledger: baseline, adds and removes, acknowledgement, resume |
| `Tests.Rename` | The designer's half of a rename end to end, including the class name that follows a root rename on the editor's answer |
| `Tests.Orphan` | `EvaluateOrphan`: both clauses, arming, disarming, the deadline |
| `Tests.Recovery` | Journal, discovery, recover, discard, and that a recovered document saves the bytes the ended session would have |
| `Tests.SettledImage` | A change reported without warning becoming one step, ten becoming ten, the frame drag counting as a gesture, and the designer chrome staying out of what is written |
| `Tests.SourceFiles` | Which other form files a document is built from, and why each was read |
| `Tests.Log` | The session log's ring buffer and the order a drop is reported in |
| `Tests.Layout` | The layout store: what a next start reads back, the rescale across a DPI change, and what a damaged value or DPI is refused with |
| `Tests.Clipboard` | Copy, cut and paste: the fragment a selection writes, the names a paste counts up, the references that follow a rename and the ones that do not, the handler rule and its refusal on an uncoupled document, and a block split over collections, strings and binary data |
| `Tests.ArgumentFile` | `ExpandConfigFileArgument`: one argument per non-empty line, file arguments appended after those already present, the option and any nested one removed, and how an unreadable file is reported |
| `Tests.SearchPath` | `SplitSearchPath`, `TakeSearchPathArgument`, the per-document override, an ancestor chain resolved through it, and `DfmFileRootHeader` on a binary resource `.dfm` and on ANSI text bytes |
| `Tests.LoadedClasses` | Ancestor names resolved from the classes in the process: `LoadedClass`, `LoadedAncestorClass`, and `TAncestorChain` over form files with no companion unit |
| `Tests.LinkedModules` | A reference into another module: resolved through the class index over the document's directory and the search path, written back qualified, and left unchanged when no form file declares the module |
| `Tests.ZOrder` | `RestackSelection` and `CanRestackSelection`: to front, to back, a group step, a step that moves nothing, a guarded document, the root, and undo and redo. Z-order is an index among siblings that no property records, so every case reads a saved file |
| `Tests.Tiles` | `IsNonVisual` and `TileAt`: which components of a root are drawn as tiles, and which tile a point hits |
| `Tests.DesignHitTest` | Which messages `IsDesignMsg` consumes and which are left to the control, which component a click resolves to, the parent of the selection chrome, the load-time `Modified` report, and the read-only guard. Moves the system cursor, so an interactive desktop session is required |
| `Tests.InspectorRows` | Which editing control a row offers: the pick list `paValueList` fills, and the ellipsis `paDialog` — or `paCustomDropDown` without `paValueList` — shows |
| `Tests.DesignerDiscovery` | How a package reaches the designer from a component it holds: `FindRootDesigner` up the owner chain, the `IDesignerNotify` query, and the nil a component outside `csDesigning` produces |
| `Tests.IdeServices` | The `BorlandIDEServices` stub as a design package queries it during unit initialization and `Register`: the menu, action list, image list and toolbars, and the about-box calls |
| `Tests.Diagnostics` | The stack capture and address naming in `Packages.Stacks`, and the export table `Packages.PeImage` reads. Win32 with runtime packages only |
| `Tests.Palette` | The palette content model, the search filter and the favourites store. The ordering cases assert that each neighbouring pair is in order rather than compare against a fixed list, because the packages a run loaded decide the content; the favourites cases write under a `Tests` subkey of the settings root, never the key the product reads |

`VallentaDesigner.dpr` sits above all of it: the argument file is expanded and
the search path taken out of the arguments first — both before any option is
read, since `--serve`, `--search-path` and the file name may all arrive from the
file — then the single-instance claim, and then either handing the file over and
exiting or becoming the core. Its `uses` clause is also the unit initialization
order, which is why it is written in dependency order rather than
alphabetically.

The program is a GUI application; its own windows are ordinary form and frame
resources. Only the *designed* root goes through the streaming machinery.

## Application Shape

| Zone | Pane |
|---|---|
| Left | Component palette |
| Centre | Scroll box hosting the document |
| Right | Object inspector |
| Bottom | Messages |

Panes are frames created at runtime and parented into their zone, so the layout
lives in one form resource and each pane stays self-contained. Pane and window
sizes are persisted by `Shell.Layout` under one registry key of this release:
every window reads it as it opens and writes it as it closes, so the next start
gets the layout of the window closed last.

**A window belongs to one document, and there are N of them.** State set up once
per process belongs to the core above them; state belonging to one file belongs
to the window — its own log, undo stack, document, designer, coupling, and its
entry in the recovery journal. Two VCL details follow from a main form that is
never shown and are not optional:

- A document window takes its own taskbar button through `ShowInTaskBar`, not
  through a hand-written `CreateParams`.
- The design-time layer's `GetMainWindowSize` is answered from the *active
  document window* through a provider the core installs, because
  `Application.MainForm` is a window with no meaningful size.

**A refusal reaches a terminal when there is one.** `Core.Console` writes to the
inherited standard output when one exists, which covers both a console and
redirection into a file or pipe, and attaches to the parent process's console
only when no handle was inherited. A GUI program started from the shell has
neither, and the same message is then shown in a dialog.

## Command Line

| Invocation | Behaviour |
|---|---|
| `VallentaDesigner.exe <file.dfm>` | Opens the file: in a window of the core that is already running, or in a core this invocation becomes. A file already open is raised rather than opened twice |
| `VallentaDesigner.exe --serve` | Becomes the core with no document: claims the pipe, loads the packages and waits for connections. This is how the extension starts a designer ahead of the first form |
| `--search-path <dirs>` | Semicolon-separated directories that form files are searched for beyond the document's own. Sets the process-wide default; may stand anywhere, including ahead of the file name |
| `--config-file <file>` | Reads arguments out of that file and appends them to those already given |
| no arguments | Opens a file-selection dialog; cancelling ends the process |

Exit codes: `0` success; `1` the running core refused the file, the document
failed to open, or an exception ended the start; `2` no form file was chosen or
the `--config-file` file could not be read.

**Why a file of arguments exists.** Windows caps a command line at 32767
characters, and a project search path can reach that on its own. The file is
UTF-8 with or without a byte order mark, one argument per line — an option and
its value on two lines, as they would stand on the command line — trimmed, with
empty lines skipped. A nested `--config-file` inside such a file is removed
rather than followed.

**The file is expanded before any option is read**, because `--serve`,
`--search-path` and the file name may all arrive from it. A file that cannot be
read ends the start with exit code 2 and reports the reason through the console
when one was inherited and through a `MessageBox` otherwise — the plain Win32
call, because this runs before `Application.Initialize`.

**Configuration is not on the command line.** Which packages load, whether the
IDE's installed ones are offered, whether their editors back the inspector's
rows, and how often unsaved work is copied are all values below
`HKEY_CURRENT_USER` under this release's own key. `Packages.Host.LoadPackagesFrom`
takes that key as an argument and is called before anything has read it;
`LoadConfiguredPackages` is the call that names this release's key, and the test
suite calls the same entry point with a key of its own. A caller that can name a
key can be a test; a switch could only ever be a command line.

## Registry Layout

All user state lives below `HKEY_CURRENT_USER\Software\VallentaStudio\Designer\<IdeVersion>`.
Nothing here writes the IDE's own keys.

| Subkey | Holds |
|---|---|
| `Packages` | `Configured` and `Disabled` subkeys naming package paths, and the `Discovery`, `AllowList`, `Exclude` and `HostedEditors` values |
| `Palette` | `FavouriteGroups` and `FavouriteItems` subkeys, one value name per favourite page or class |
| `Layout` | Pane widths and heights, window size and maximized state, and the `PPI` they were measured at |
| `PackagesDialog` | Size and column widths of the package manager dialog |
| `Recovery` | `IntervalSeconds` — seconds between recovery copies. 30 when unset, 0 disables the journal, any other value is raised to at least 5 |

## The Resident Core (`Shell.Core`)

`TDesignerCore` is a form that is never shown: `Application.ShowMainForm` is set
to `False` before `Application.Run`, and the form has no border and no taskbar
presence. It is `Application.MainForm` because the application requires one and
because the tray icon needs an owner that outlives every document window.

**What it holds**, all of it set up once per process: `InstallStandardEditors`,
the packages, the hosted designer package with its environment and service
stand-ins, the class-group claim, the notification fan-out, the streaming class
registry, the session log, the session registry, the window registry, the pipe
server, the recovery journal, and the tray icon.

**A core can start without a document.** `--serve` claims the pipe, loads the
packages and enters the message loop with no window, which is how the extension
starts a designer ahead of the first form. `ServeStarted` records that the core
came up that way, because a core with no window is the normal state for a
`--serve` start and the orphan rule has to distinguish the two.

**The tray icon** carries the status in its hint — *3 forms open, 1 unsaved* —
and its menu is that line, one entry per open document marked while unsaved, a
separator, and **Exit**. Clicking an entry raises that window; double-clicking
the icon raises the most recently active one. There is deliberately no Open
item: a running core with no windows is the intended idle state, and something
else asks it to open documents.

**Two paths end the message loop**: the tray Exit item, and the orphan watch
that ends a core no session is attached to any more (`EvaluateOrphan` in
`Core.Sessions`, evaluated on every tenth journal beat). Both run the same
sweep.

**The shutdown order is required, not incidental**: confirm-close sweep → close
every window, each releasing its document and designer → every palette model has
been freed with its window, so nothing names a package class any more →
`DropDynamicClasses`, then `UnloadAll`, editor groups before modules → journal
folder, mutex, tray icon. Exit runs each window's own `ConfirmClose` in turn and
a cancel anywhere aborts the whole sweep; the Windows session-end message runs
the same sweep. `Shutdown` is idempotent and is called from the destructor as
well, because `WM_ENDSESSION` reaches `Halt` without unwinding the program's
`try..finally` blocks.

**The tray menu is reachable while a modal dialog is open.** The tray's own
window is never shown, and a modal loop disables only windows that are shown, so
Exit could otherwise free documents whose dialogs were still on the stack. The
menu offers nothing actionable while any document window is disabled, and the
test is *"is any document window disabled"* rather than `Application.ModalLevel`:
`ModalLevel` counts only forms shown with `ShowModal`, and a `TColorDialog` or
`TFontDialog` — which is what a property row opens — disables windows without
raising it.

## Single Instance and the Handover (`Core.SingleInstance`)

The claim is a named mutex, `Local\VallentaDesigner.<key>`, and the pipe served
beside it carries the same key. The key is the first 16 characters of a SHA-2
digest over the lowercased full path of the executable and the logon session id:
`Local\` and the session id because a core belongs to one logged-on session, the
path because a debug build and an installed build are different products. The
derivation is part of the protocol contract — the VS Code extension computes the
same name from the same two inputs.

The claim is taken **before the packages**, so a start whose only task is handing
a file over opens a connection instead of building a design-time layer.

| Mutex state | Behaviour |
|---|---|
| Held | Connect to the pipe of the same name, write one line, read one back, exit 0 |
| Not held | Become the core |
| Held but not answering within a short timeout | Start anyway as a *solo core*: full designer, no pipe server, one warning line |

A mutex held by an unresponsive process must not leave the user unable to open a
form, and two servers under one pipe name must not leave routing ambiguous.

The handover is newline-delimited UTF-8 JSON, one object per line:

```
→ {"v":0,"cmd":"open","file":"C:\\Work\\Unit1.dfm"}
← {"v":0,"ok":true,"focused":true,"pid":12345}
```

`focused` distinguishes "opened a new window" from "that file was already open
and its window was raised". An unknown `cmd` is answered rather than left
unanswered, so a newer extension against an older core receives something it can
read. An `open` request may also carry the search path the document is to be
resolved against.

**`ProtocolVersion` is `0` and stays there.** The session scope added no message
to the handover and changed none of its shapes; it added a second scope beside
it on connections that ask for one, correlated by message id. `SessionProtocol`
is the version of the session scope and is at `2`.

**Threading.** One thread accepts, each connection is served on a thread of its
own, and every request is marshalled to the main thread before anything touches
the VCL or the log. `Core.Log` is single-threaded by contract, so nothing logs
from a pipe thread; what a connection has to report travels with the queued call
rather than through a field of the listener, because two connections writing one
string field produce a torn string and a double free rather than a lost message.

**Focus.** A background process may not raise its own window, so the *routing*
process calls `AllowSetForegroundWindow` before it writes. That is why the
response carries the core's process id, and why the raising happens while the
request is being served rather than after the answer.

**Two deadlocks were found in the answering path and are guarded against.** A
refusal is written on the connection the request arrived on, and the serving end
waits for it to be read before disconnecting, so an answer written while the
caller is still writing cannot be delivered. It appeared once as a request
longer than any this program sends — the reader stopped consuming at the limit,
and now keeps reading the bytes it discards — and once as the flush itself. The
related arithmetic constraint: `ReadyTimeout` is *derived* from the caller's
timeout rather than set beside it, so the "still starting up" refusal cannot be
written after the caller has given up.

## Sessions and the Source Coupling

A connection whose first line is an `attach` becomes a session: many lines each
way, correlated by message id, on the same pipe the handover uses. A session is
how the VS Code extension drives the designer and how the designer requests
source edits.

| Direction | Messages |
|---|---|
| Client to core | `attach`, `open`, `focus`, `close`, `reloadFromDisk` |
| Core to client | `addFormField`, `removeFormField`, `ensureEventHandler`, `removeEventHandler`, `gotoHandler`, `renameComponent`, `listMethods` |
| Core events | `opened`, `dirtyChanged`, `saved`, `closed` |

`Core.SingleInstance` holds the command, event and field name constants; that
block is the wire's single source of truth and the extension mirrors it.

**Which session a document's events go to** is decided by `Core.Sessions`: the
session that opened the document first, else the session whose workspace is
closest to the document's path, and the latest attach between equals. `opened`
is replayed at attach for documents that were opened while nothing was
listening.

**The coupling is per document** (`Core.Coupling`). It sends the unit-side
requests for one document and applies the answers; the unit is never edited
here. A pending request holds an interface reference to the coupling, so the
coupling outlives the window that created it; `Close` stops further requests and
suppresses the callbacks and log writes of late answers, while a late field
answer still moves the ledger.

**The field ledger makes the coupling self-healing** (`Core.FieldLedger`). It
holds the acknowledged field set of one document and diffs it against the
components the document holds now. Entries are added and removed only on
acknowledgement, never by the diff, so an unconfirmed change is reported again
at the next settle point. `Diff` before `Baseline` reports every field as an
add, so callers gate on `HasBaseline`.

**A resume re-sends fields and handlers at each reattach.** The applied undo
history carries created-handler marks: undoing a marked step requests that the
method be removed, redo requests it again, a resume replays the marks of the
applied history, and a rename moves them.

## Recovery (`Core.Recovery`, `Shell.RecoveryDialog`)

**What is written** is a complete, valid, openable `.dfm`, produced by the real
save pipeline directed at another path (`TFormDesigner.WriteTo`) — not the undo
snapshot, which is deliberately incomplete and would drop exactly the preserved
subtrees this exists to protect.

**Where:** `%LOCALAPPDATA%\Vallenta\VallentaDesigner\recovery\<core id>\`, the
core id being process id plus start time. Per document there is a copy named for
a hash of the source path, and beside it a note naming that path, the root kind,
the declared class and the time. **Copy first, note second** — the note is what
discovery reads, so it is written last and describes a file that is already
complete. A `core.lock` file is held open for the process's lifetime, so a later
core distinguishes an ended session (lock openable) from a running one without
inspecting process ids.

**When:** on a timer, `Recovery\IntervalSeconds`, writing only documents that
are dirty *and* changed since their own last copy. The window keeps that change
count, because the dirty flag is one bit and is already set by the time the
second edit arrives. Never mid-gesture.

**Entries are released** when a document is saved, and when it closes with its
changes answered for — a window's own close, or the tray sweep once every window
has agreed. Not for a window taken away without being asked. What remains is
exactly what an end that never asked left behind, and that is what the next core
is meant to find. An entry this designer cannot read is neither offered nor
deleted: it belongs to whatever wrote it.

**The offer runs on a timer beat**, not from the start-up path and not from a
queued call: a dialog held open through start-up would leave the file this
invocation was given unopened behind it, and a queued call is delivered by the
very message pump a modal loop is turning. Each entry gets its own row and its
own **Recover** or **Discard** button, each of which ends the dialog and is then
carried out. There is no OK and nothing to cancel.

**Nothing may replace a document from inside a foreign modal loop.** The window
that loop disabled is the one being rebuilt, with a dialog painted over it. The
dialog answers and closes; the core acts afterwards.

**A window already holding that file is where the copy goes**, and at start-up
that is the rule rather than the exception, since the invocation that found the
entry was given the same form the ended session was working in. Only a window
worked in since is left alone. A reused window is never passed to `Adopt`:
`Adopt` frees a window holding nothing, which is what a failed recovery load
leaves behind, and a window the user is working in is not the recovery's to
take away.

## Root Kinds

A `.dfm` file does not state what kind of root it holds, and the stub has to
exist before the file can be streamed, so the kind is decided first, in three
stages (`Streaming.RootClassifier`):

1. **The companion unit.** `<name>.pas` beside the file is searched for the root
   class and the ancestor it names. Only the base classes of the three kinds
   decide; a class of the user's own falls through to stage 2.
2. **The root's own properties.** Read out of the root's property block: a root
   carrying a tab order is a frame, a root with a size but no client area is a
   data module, a root with a client area is a form.
3. **Form, with a warning.** Nothing was decisive.

Which stage decided is logged, so a misclassification is diagnosable from the log
alone, and the kind appears in the window title. A wrong classification degrades
to unknown-property warnings rather than data loss; the round trip still holds.

| Kind | Stub | Presentation |
|---|---|---|
| Form | `TForm` | Embedded in the design surface as it is |
| Frame | `TFrame` on a host form | Host embedded, frame inside it |
| Data module | `TDataModule` | `TIconSurface` sized from the module's design size |

**The hook host and the designed root are two different objects.** A form is
both at once. A frame must sit on a *form* for the designer to be reachable from
it, so it is given a borderless host form carrying the hook while `GetRoot`
answers with the frame; the host is chrome and is never streamed. A data module
has no window at all: its host is `nil`, no hook is installed, and input arrives
from `TIconSurface` instead of from `IsDesignMsg`.

## Embedding

**The designed form** is a child of the scroll box. Two consequences drive the
code:

- **Its stored position is not its physical position.** Once a design-mode form
  has a parent, `Left` and `Top` address the stored design position, so the
  loader captures the streamed values while the form is still parentless and
  restores them after parenting. Assigning them also forces `Position`, so the
  streamed value of that property is saved and restored around the assignment —
  in the embedding step and again in the property grid's write path.
- **Keyboard input reaches a designer only through a design-mode control.**
  Clicking the surface moves focus onto the hook host; without that, arrows, Del
  and Esc would go to the shell. The save chord is different: the designer
  consumes it and raises `OnSaveRequest`, so the shell's save action runs
  regardless of where focus was.

The form root keeps its native window frame so it can be resized by its edges,
which is a genuine edit of `ClientWidth` and `ClientHeight`, while the parts of
the frame that would move, close, minimise or maximise a window are consumed.
Editing `BorderIcons` to remove those buttons would change a stored property.

**A designed frame keeps the position it streamed with.** Its `Left` and `Top`
are ordinary stored properties, so moving it to the corner of its host would be
an edit; the host is sized *around* it instead, with room at the right and
bottom for the handles a selected frame root displays. Nothing about designing a
frame writes to its position, and the save side therefore restores nothing.

**A frame has to be parented even when nothing is shown**, the round trip
included: a control without a parent reports no tab order, and the property would
be dropped from the saved file as a default.

## Load Pipeline (`Streaming.Loader`)

Loading is two steps, because the stub cannot be built before the file has been
read.

**`Prepare`**

1. Read the file and detect text or binary. Text is converted to the binary form
   in memory, so both paths share one reader.
2. Inspect the binary header directly, without consuming the stream, for the
   root kind and the declared class and object names. An `inline` root — a file
   holding nothing but a frame instance — is refused with a message naming it.
3. For an `inherited` root, resolve the forms it is built on (see Forms Built On
   Other Forms); the kind comes from the class that chain ends at. Otherwise
   resolve which classes the file uses frames of and find the file each lives in
   (see Frames Used Inside a Form), then classify the root and log which stage
   decided.

The caller then builds the document the kind requires (`CreateDesignDocument` →
`TDesignDocument`, released through `FreeDesignDocument`) and installs the
designer on it.

**`StreamInto`**

4. Put the root into design mode **before** streaming, so components never go
   live while loading and so the designer is queried for the design PPI while
   properties are read.
5. Name the stub from the header: a root already in design mode keeps its own
   name while streaming, so without this the saved file would lose it.
6. Stream the forms the document is built on, base-most first, then the document
   itself, then build the ancestor stub a save measures against — with
   `TDesignReader` for event markers, an unknown-class recorder, a frame builder
   and an error handler, all inside **one loading pass**, so that nothing is told
   it has finished loading until every file involved has been read.
7. Capture `TLoadedFormState`.

**`PrepareFromSnapshot`** replaces `Prepare` when the input is an undo entry
rather than a file. The image is the document's own text: it names the stub's own
class and states no root kind, so both are carried over from the state the
original load captured, while the frames it names are resolved against the
document's directory exactly as a load from that file would. Everything after it
is the ordinary `StreamInto`. That pass writes no log entries apart from warnings
and errors.

**The install order is required:** classify → create the stub → install the
designer → enter design mode → stream → present. The designer must exist before
streaming because scaling queries it.

**Load policy.** Only registered classes stream. A class the registry does not
hold does not stop the load: the reader frees what it built, consumes the rest of
that block and continues, and the block is kept verbatim instead (see Preserving
What Cannot Be Loaded). Resolution goes through the runtime's own
registered-class table, so `RegisterClasses` is the only way in and there is no
name-to-class map of this program's own. Entries come from two origins:
`DesignerClasses` in `Core.ComponentRegistry`, and whatever the configured
packages declare (see Component Packages).

**`TLoadedFormState`** carries what the saver cannot recover from the live root:

| Field | Purpose |
|---|---|
| `RootClassName` | The stub streams back under its own class name, never the declared one; the saver patches it into the header and the tree displays it |
| `RootKind` | Decides the presentation and the window title |
| `Left`, `Top` | The streamed design position of a form, captured while it is still parentless |
| `ActiveControlName` | Checked at save time — input is consumed, so focus must not have moved. Held by name: the control it refers to can be deleted while designing, and a raw reference would dangle |

Nothing else is captured. The designer shadows no stored property of the root,
so there is nothing to restore before writing.

## Designer Surface (`Surface.FormDesigner`)

`TFormDesigner` implements the designer interface with non-reference-counted
lifetime — its `_AddRef` and `_Release` return -1 — and the creating window frees
it. It is installed **before** streaming. Closing is the shell's decision: the
main window asks the designer to confirm, and an embedded root's own close button
is consumed like the rest of its frame.

| Member | Behaviour |
|---|---|
| `Form` / `Root` | The hook host and what is being designed; equal for a form, split for a frame, `Form` is `nil` for a data module |
| `IsDesignMsg` | Selection, drag, resize and the keyboard map. Returns True for every message it handled |
| `PaintGrid` | Fills a design surface with its colour, dots it at the grid pitch and draws the icon tiles |
| `SurfaceControl` | What to repaint when the tile layer changes: the root's own window, or the icon canvas of a data module |
| `DesignPPI` | Fixed at 96; see DPI Policy |
| `UniqueName` | `BaseName` plus the lowest free index over the root's components |
| `Modified` | Sets the dirty flag and refreshes the title |
| `RestackSelection` / `CanRestackSelection` | Brings the selection to the front or sends it to the back among its siblings, as one undo step for the group |
| `GuardReadOnly` / `LiftGuard` | Refuses every edit while a load left references it could not resolve; lifting the guard is a user decision and is logged as one |
| `BeginEditing` | Called once the document is on screen: starts geometry tracking and attaches the selection's handles |
| `PaintMenu`, `UpdateCaption`, `UpdateDesigner`, `ValidateRename`, `Notification`, `CanInsertComponent` | Not implemented; each returns a fixed value |

**Input is consumed wholesale.** Every mouse and keyboard message the designer
sees returns True, so a designed control never runs its own handlers. This is
required rather than cosmetic: event properties hold name markers, and letting a
control fire one would call a marker index as an object reference. The hover
notifications the framework synthesizes on enter, leave and capture changes are
consumed with the rest — they are not input a user sent, but a control acts on
them all the same, and a control that resets a stored property on mouse-leave
would silently discard an inspector edit.

### Selection and Handles

The selection is an ordered list with a **primary**, the component clicked last.
The primary displays the grab handles, is what a resize applies to, and is what the
align and size commands measure everything else against; the rest wear a thin
outline built from the same strips as the drag frame. Shift+click adds and
removes, a drag on the background draws a marquee and takes what it touches
(icon tiles included), and clicking a member of a group keeps the group and makes
that member primary, so the whole group can be dragged as one.

**The root is never part of a group.** It contains everything else, so a
selection holding both it and its children would have no meaning; selecting it
replaces the selection. There is no "nothing selected" state.

Moving, nudging and deleting apply to everything selected — one undo entry for
the whole set, the same already-snapped distance for each. Resizing does not: it
stays on the primary. A placeholder inside a group is skipped rather than
failing the gesture, with a line in the messages pane reporting how many were
left alone.

A selection is a list of `TComponent` rather than of controls: the root is
selected by selecting itself, and components without a window belong in a
selection as much as controls do. The control under the mouse arrives as the
message sender, non-windowed controls included, so hit-testing is not
re-implemented — except for icon tiles, which are painted rather than windowed
and are therefore looked up by position, and for a disabled control, which does
not receive the message and is resolved by geometry.

Handles attach to a selection that has bounds and is not a form root: a form root
is resized by its own window frame, a frame root has no frame of its own and gets
handles, and a component without a window displays the tile adorner instead.
`THandleSet` refuses anything that is not a control, so that policy is decided in
one place.

`THandleSet` holds eight 5×5 windows. Two properties matter:

- Their `Owner` is `nil`, so they are not part of the streamed component tree and
  can never reach the saved file.
- A resize gesture runs on the handle window's **own** mouse capture and is
  forwarded to the designer as begin/move/end, while a move gesture runs on a
  capture the designer sets on the hook host. Confusing the two is how a drag
  stops receiving mouse moves.

The chrome windows are parented to the window `Chrome` names — normally the
document's host window, not the designed container the target is a child of.
A parent that arranges its children treats an inserted window as one of them, so
handles parented into a toolbar would be laid out as toolbar items. Bounds are
passed in the target parent's client coordinates and mapped into the host's.

A save does not detach the handles; `SinkChrome` moves them to the end of the
tab list and leaves them attached. `THandleSet.Detach` runs only from `Attach`
itself, when the new target is not a control or has no parent. Re-selecting what
is already selected re-attaches the set, which is what displays the handles when
a document opens.

### Geometry Editing

| Input | Action |
|---|---|
| Click | Select what is under the mouse; the root's background selects the root |
| Drag | Move, snapped to the grid, with a frame showing the result |
| Drag a handle | Resize, snapped, minimum 1×1 |
| Alt while dragging | Suspends snapping for that gesture |
| Arrow | Move by one grid step |
| Ctrl+Arrow | Move by 1 px |
| Shift+Arrow | Resize by 1 px |
| Esc | Select the parent; during a drag, cancel it |
| Del | Delete the selection |
| Ctrl+X / Ctrl+C / Ctrl+V | Cut, copy, paste |
| Ctrl+Z / Ctrl+Y | Undo, redo |
| Ctrl+S | Save |

The root's position on the surface is presentation, so arrows do not move it.
Only its size is an edit, and only a frame root takes that from the keyboard.

**Z-order is an edit with no property to write.** A control's z-order is its
index among its parent's children, which is the order the form file lists them
in and which no property records — so bringing a control to the front or sending
it to the back changes the file without changing a property line, and the only
way to measure it is to save and read the result. `RestackSelection` takes
`zsToFront` or `zsToBack` and moves everything selected in one step, in document
order, so a group keeps its internal order. A step that would move nothing leaves
no undo entry, the root is not a control to restack, and a guarded document
refuses it like any other edit.

Constants sit at the top of the units: grid `8`, drag threshold `3`, handle size
`5`, frame thickness `2`, tile glyph `24`. Moving or resizing the designer window
edits a form root's own bounds; the tracker compares the real window rectangle
and marks the document dirty only when it actually changed, and only when the
root *is* the window. Every applied edit goes through `ApplyBounds`, or
`MoveTile` for a component without a window, which clamps, repositions the
handles, keeps a frame's host in step and marks the document dirty.

**Drag geometry is computed once, in the selection's parent coordinates, and
already snapped**, so the frame shows the exact rectangle the drop applies and
the commit needs no second snapping pass. Snapping is suspended while Alt is
held, which is how a component is placed between two grid lines without turning
snapping off permanently.

**The drag frame must not be drawn onto the screen device context.**
Direct-to-screen drawing — the classic XOR rubber band — is discarded by the
desktop compositor and produces nothing at all, measured at pixel level both
from inside the designer and from an independent process on Windows 11. The
frame is therefore built from four thin child windows, like the handles.

Keyboard input arrives as a pre-dispatch notification before it becomes a regular
key message; the designer marks it handled, so it is consumed once and not
twice.

### Painting a Frame

A form hands the designer a canvas to paint its background on. A frame does not,
because it is not a form, and painting through a device context of the designer's
own would ignore the update region and fill over graphic controls that a partial
repaint will not redraw. The designer therefore takes the frame's repaint over
through its `WindowProc`: it begins the paint itself, draws the background, the
grid and the tiles onto the context the repaint actually uses, and lets the frame
paint its own children over them. The hook is removed when the designer is
destroyed.

The host reaches `PaintGrid` as well, both on its own behalf and while a themed
frame has its background drawn by its parent. Only the first of those is the host
painting itself, and the two are distinguished by the window the canvas in flight
belongs to; filling the host's colour over the other would erase the frame.

## Group Commands and Their Dialogs (`Shell.AlignDialogs`)

Align, same size, tab order and creation order are requested in a dialog and
carried out by the designer; a dialog never modifies a designed component, it
only reports the selected values. All four are built in code rather than from
form resources.

- **Align** takes a choice per axis, with the primary selection as the reference.
  *Space equally* distributes the gaps between the outermost two over everything
  in between and leaves those two in place, so the result does not depend on the
  order components were selected in.
- **Same size** takes width, height or both from the primary.
- **Tab order** lists the windowed children of the container the selection sits
  in, in the order they tab rather than the order they were parented, and assigns
  positions front to back. Each write shifts the ones after it, so working
  forwards produces exactly the list as given.
- **Creation order** lists the components without a window and writes
  `ComponentIndex`. A form writes its child controls from its control list and
  only then its parentless components, in component order, so this reorders the
  block of components without a window and reaches nothing else.

**Tab order is refused where a placeholder shares the container.** Assigning
positions in turn produces the list as given only while that list is every
windowed child there is, and the stand-in for a preserved component is one of
them; it holds the slot its own text names, and that text is not the designer's
to rewrite.

The batch commands write bounds directly rather than through `ApplyBounds`, and
mark the document dirty and refresh the handles once at the end: one gesture, one
undo entry, one notification.

## Icon Tiles (`Surface.Tiles`, `Surface.TileLayer`)

A component without a window is displayed as a 24×24 glyph with its name beneath
it and, when selected, a dotted adorner. Its position is the whole of what the
designer stores about it: `Left` and `Top` are pseudo-properties over
`TComponent.DesignInfo` and round-trip by themselves, so setting `DesignInfo` is
the entire edit. Both halves are unsigned, hence the clamp — a tile dragged past
an edge would otherwise reappear on the far side.

Only the glyph is clickable, not the caption, so two tiles side by side stay
distinguishable.

**On a form or frame the tiles are drawn in a window of their own**
(`TTileLayer`), a child of the document's host raised above the designed
controls. Painting them into the root's background placed them under the
controls, where a control repainting itself erased whatever tile it overlapped.
The layer derives its window region from the non-key pixels of the tile drawing,
which is why the caption font is set to `fqNonAntialiased`: antialiased edges
blend towards the key colour and drop out of the region. Three properties follow
from the layer being a window — its `Owner` is `nil`, so streaming the host
cannot write it; it holds a place in the host's tab list and is therefore moved
to the end with the rest of the chrome before the document is streamed; and it
takes no mouse input, so a click over a tile is resolved from the cursor position
by the designer rather than delivered by the layer.

One renderer serves both surfaces that display tiles: the tile layer of a form or
frame, and the canvas of a data module. Neither routine holds the canvas it draws
on, so both restore every pen, brush and font they touched.

## Data Module Canvas (`Surface.IconCanvas`)

`TIconSurface` is a control this program implements in full, so it needs none of
the designer hook machinery: it paints the tiles itself and drives the designer
from its own mouse and keyboard handlers — select, drag with snap, nudge, Del,
palette placement, save. Its size comes from the module's design size, which is a
defined property and therefore never reaches the property grid; the designer does
not write it back. A dragged tile follows the mouse without the document turning
dirty — the drop is the edit — and Esc during a drag restores the start position.

The active VCL style is kept off the canvas: a design surface is not part of the
application's appearance.

## Event Name Preservation (`Streaming.EventNames`)

The designer links no user code, so an event assignment exists only as a name,
and a method reference whose code address is nil is dropped while streaming.
Preservation therefore needs a non-nil marker.

- `TEventNameMap` interns names. A marker's data pointer is the **1-based index**
  into the name list, so the same handler on two components yields the same
  marker.
- A marker's code address is a thunk emitted for the event's own method type. A
  design-mode component may call its events, and under the Win32 register
  calling convention the callee pops the stack parameters, so a thunk of the
  wrong shape unbalances the caller's stack. This is CPUX86 only; compilation for
  any other target fails deliberately.
- `TDesignReader` overrides method resolution to hand out markers and logs each
  one.
- On save the writer's method-name callback maps the marker back to the interned
  name. It is consulted before any other name lookup and also decides that the
  property is worth writing at all.
- Names are interned case-sensitively: two spellings must not collapse into one
  marker, or saving would rename a handler.
- Deleting a component orphans its markers, which is harmless — markers are
  resolved only from live properties at write time.
- An undo restore builds a **new** map along with the new document. Every marker
  a live property held was written into the image as its name, so re-interning
  reproduces the set; the old map is freed with the document it belonged to.

## Save Pipeline (`Streaming.Saver`)

```
SaveDesignedForm(Root, EventMap, State, Frames, Preserved, Ancestor, FileName)
  1. Focus check        the control focused at load must still be focused
  2. Stream             TWriter over a memory stream, method-name callback wired to
                        the map, ancestor callback wired to the frames, and the
                        whole root written against the ancestor stub when there
                        is one
  3. Root identity      rewrite the root class name in the binary header, keeping
                        the filer flag that makes the block read 'inherited'
  4. Text               convert the binary buffer to text
  5. Frame identity     write each frame's declared class over the stub's name
  6. Splice             put back what the load kept verbatim
  7. Atomic replace     write '<name>.dfm.tmp', then move it over the original
```

Steps 5 and 6 are skipped entirely when there is nothing to put back; the filer's
own bytes are then written as they stand. Any root kind streams through the same
path — `Root` is a `TComponent`.

**Root identity.** The stub streams back under its own class name, so the header
is rewritten: signature, an optional flags byte, a length-prefixed class name,
the object name, then properties. A root written against an ancestor carries that
flags byte, which is what makes the block read `inherited`, and it is copied
across untouched.

**The root is written exactly as it stands.** Step 1 restores nothing; it only
checks, and only a form can fail it. Input is consumed while designing, so the
focused control must be the one that was focused at load. A control deleted
meanwhile is a legitimate edit, detected by looking the stored name up on the
live form rather than by dereferencing the deleted control. A genuine failure
raises rather than repairing: if focus really moved, input reached the form and
that is a defect to fix at its source.

**Putting content back is steps 5 and 6.** A document with nothing preserved and
no frames is written exactly as the filer produced it. Only a document with
something to put back is taken apart, rewritten as text and written out again. A
preserved piece whose block is missing from the output raises rather than being
dropped silently, and so does a live frame instance the written form does not
hold.

## Preserving What Cannot Be Loaded (`Streaming.TextSpans`, `Streaming.Preserved`)

A designer that refuses every file holding a class it does not know is of no use
on real forms. What cannot be loaded is kept: the block of an unknown class and
the line of a property that could not be read are cut out of the file's own text
and put back on save, unchanged.

**The scanner reports where, never what.** `TDfmScanner` tokenizes the text
form far enough to find the boundaries of blocks and property lines — strings
with their character codes and `+` continuations, `{}` binary, `<>` collections
with their items, `[]` sets, `()` lists — and records offsets. It carries no
value model, which is why it can read the parts of a file the designer itself
cannot. Text it cannot follow raises rather than guessing, which turns unreadable
input into a refused load instead of a silently mangled save. An error that names
no property at all is the one case that cannot be kept; it is reported in the log
rather than passing unnoticed.

**Both sides are the same text.** The input is normalized through
`ObjectBinaryToText` at load and the output is produced by it at save, so a span
cut from the one drops into the other with its indentation intact. That text is
pure ASCII — everything else is written as character codes — so cutting and
splicing cannot disturb an encoding.

**Capture.** An unknown class is recorded when `OnFindComponentClass` returns
nil, and the error that follows is answered with `Handled := True`. An unread
property is named by the reader's own `PropName`, a protected member
`TDesignReader` exposes, rather than by parsing a localized message, and it
belongs to the component named last — properties precede nested blocks in every
block, so that is always the right one. After the load the scanner runs over the
source text and cuts out what those two sets point at.

**Keyed by name, positioned by index.** A piece records the component whose block
holds it and the position it had among that block's blocks or property lines.
Names are unique in a form file, which makes them the shortest key back; the
index places the piece between the right neighbours, counted down by the other
pieces going back into the same place, since the written text holds none of them.

**Placeholders.** A preserved block is displayed as a hatched stand-in carrying
its name and class. Nothing the streaming walks owns it, so it can never be
written, and it is in design mode all the same, which is what routes a click on
it to the designer. It supports selection and deletion only; deleting drops the
text it stands for and asks first, because that text is the only copy. The
inspector shows the preserved lines instead of properties.

**A stand-in for a windowed control has to be a window.** `TabOrder` is a
control's index in its parent's tab list, so a skipped windowed control would
leave a gap and every sibling after it would be written one lower than the file
has it. A block that carried a `TabOrder` therefore gets a windowed stand-in
placed at that slot; everything else gets a graphic one, which stays out of that
list, since a preserved component without a window must not take a slot it never
had.

**Reserved names.** Every name inside a preserved block is reserved: it is still
in the file after the round trip, so `UniqueName` skips it and a new component
cannot collide with one.

**Deleting takes the pieces with it.** A container being deleted frees its child
controls, placeholders included, and the pieces they stand for have nowhere left
to be written, so both are released before the component is.

## References Into Another Module, and the Read-Only Guard

A form may reference a component that is not in it: a data source on a shared
data module, a popup menu on another form. The file writes such a reference
qualified — `XModData.PopupMenuShared` — and the reader can resolve it only if
the other module is loaded too.

**So it is loaded.** A dotted name is split at the dot and the part before it is
searched for through the same class index the frames and ancestors use, over the
document's own directory and the search path. The file found is streamed into a
document of its own (`TLinkedModule`) and kept **for its components only**: never
shown, never designed, never saved, and freed with the load. Its event map
interns the handler names those components hold markers for and therefore has to
outlive them. A module reference that runs in a circle, or deeper than the
ancestor depth limit, is refused and kept as written rather than followed.

**What still does not resolve is kept, exactly like an unread property.** After
the load the reader is asked which references it never fixed up
(`GetFixupReferenceNames`, `GetFixupInstanceNames`), and every property line
whose value is one of them is added to the preserved set, so the line is written
back character for character and the file survives the round trip. A reference
sitting in a block that carries no name is the one case that cannot be kept,
because there is no key to put it back under; it is reported instead.

**A document holding one opens read-only.** Writing a reference back verbatim is
sound only while nothing has moved: the components the line names are not in the
document, so the designer cannot determine whether an edit invalidated it.
`TFormDesigner.GuardReadOnly` refuses every edit, and the window shows an amber
banner naming the modules that are missing, with an **Edit anyway** button.
Lifting the guard is a user decision and is logged as one. The guard is applied
before the inspector attaches, so its grids come up read-only rather than being
switched afterwards, and `FGuardLifted` survives an undo rebuild — a restore
reloads the document and would otherwise reinstate the guard after it had been
lifted. The banner's colours are held out of the VCL style
(`StyleElements := []`).

## Frames Used Inside a Form (`Streaming.Frames`)

A frame used inside a form is not written out in full. The host's file holds only
what that instance **differs in** from the frame's own file — the block reads
`inline` and each changed child reads `inherited` — so both files are needed to
make sense of either.

**Which classes are frames is read off the text, not guessed.** The scanner
reports which blocks carry the `inline` keyword, and only the classes named there
are searched for. Anything else stays what it was: a class the designer does not
know, kept verbatim. The file a class lives in is found by reading the root
declaration of every form file beside the document and along the search path —
only the header of each, so a directory of hundreds is inexpensive to index.

**Reading.** The reader queries before it builds, which is where the instance
comes from: the frame's own file is streamed into a frame stub first, and the
host's lines are then applied on top of it. Two things about that instance are
this program's to do, because the reader performs them only on the path where it
builds one itself — it has to be given the owner (`Reader.Owner`, or it is
written by nobody) and it has to be marked as an inline instance. That mark is
the whole of what makes the writer emit it as a frame later. Once it is marked,
the reader resolves the `inherited` children inside the block against the
instance rather than against the host, which it does by itself.

**The diff base.** A second instance of the same file is built per frame class —
never edited, never shown, never parented — and handed to the writer as the
ancestor of every live instance of that class. That is what turns the block into
a set of differences. It is built at the same moment the first live instance is,
so a frame file that cannot be streamed fails while the document is still
loading, where the block can still be kept verbatim instead. It reflects the disk
as it was when the document opened; editing a frame in another window does not
reach it until the document is reopened.

**A stub cannot report the class it stands for.** Every frame class streams into
a plain frame stub, so the writer names that stub — the same problem the root has,
one level down, and answered the same way: the declared class is carried beside
the instance and written back over the stub's name in the text. The root is
patched in the binary header because its name sits at a known offset; a nested
block is patched in the text, where the scanner can report exactly which
characters the class name occupies.

**What may be edited.** Properties of a frame's children may be overridden — that
is what a diff is. Structure may not: the drop-target walk goes *past* a frame
instance to whatever contains it, and Del leaves anything inside one alone with a
line in the messages pane. Both would otherwise be edits to a file this document
does not write. The instance itself is an ordinary component of the document and
moves, sizes and deletes like any other.

**A frame that cannot be built degrades rather than refusing.** Whatever the
reason — no file declaring the class, or a file that will not stream — the class
ends up unregistered, which leaves it an unknown class, and an unknown class is
kept verbatim and displayed as a placeholder.

**A frame that uses frames of its own is one of those refusals.** Not because it
is hard to read, but because of what such an instance would have to be measured
against: the inner frame as its *enclosing* file provides it, that file's own
overrides included, rather than the plain instance of its class kept here.
Measuring against the wrong one writes the enclosing frame's overrides into the
host's file, which is a quietly wrong file rather than a loud failure. The whole
block is kept as it stands instead. The same restriction is why a frame class
named inside another frame's file is left unresolved there: an instance within an
instance is the same problem from the other side.

**What a frame's own file holds stays in that file.** This save never writes it,
so an unknown class or an unreadable property inside one is reported and skipped
rather than entering the document's preserved list, which is keyed to the
document's text and has no line to put it back into.

## Forms Built On Other Forms (`Streaming.Ancestors`)

A form file whose root reads `inherited` holds only what that form changed about
the one it descends from. Everything else is in the ancestor's file, and that one
may be a descendant in turn.

**Which files, in which order.** The class a root descends from is declared in
the companion unit beside it, and the file that class lives in is found through
the same class index the frames use, so the walk is: read the unit, take the
ancestor class, find its file, repeat, and stop at the class a stub is built for
(`TForm`, `TFrame`, `TDataModule`). The result is the ancestors' files with the
base-most first. Cycles are refused, and so is a chain longer than
`AncestorDepthLimit`, which is 8.

**A form file with no companion unit is not a dead end.** `Core.LoadedClasses`
queries the classes present in this process — the design packages loaded this
session among them — for the one the root declares, and reads what it descends
from out of `ClassParent`. A form file names its own class and never its
ancestor's, so this is the only way to follow the chain when there is no unit to
read: a base form a package supplies is answered by the package. Lookup order is
the streaming registry, then the qualified name built from the file's own name as
a unit hint, then a one-time RTTI walk over the process behind a lock. Packages
load before the first document and none afterwards, so one walk covers the
session.

A link that cannot be followed either way — no companion unit, no loaded class,
no file declaring the ancestor — is a **refusal naming what is missing**, not a
degradation: a document with no ancestor to build on is not something this
designer can stand in for.

**The kind is known rather than guessed.** The chain ends at a class whose kind
is known outright, so a descendant never goes through the property sniff, which
would be reading a block that holds only differences and may name no kind at all.

**Reading is one pass per file into the same stub**, base-most first: each pass
finds the components the previous one created and changes them rather than
creating its own, which is what an `inherited` block means. The document's own
file is the last pass. Event handler names accumulate across the passes in the
one map, so a handler the descendant does not override is not a difference and is
not written.

**Writing measures against a second stub** built from the ancestors alone — never
edited, never shown, rebuilt whenever the document is. What the descendant did
not change is then not written at all, what it changed comes out as `inherited`,
and what it added comes out as a plain `object` block. The root carries the
filer's inherited flag, and the root class patch copies that byte across.

**What may be edited.** Properties of inherited components, freely — that is what
a difference is. They cannot be **deleted**: a descendant's file has no way of
expressing that a component is gone, so it would return on the next load. The
check is by name against the ancestor stub, both documents being streamed from
the same files. Components the document adds itself delete normally.

**Ancestors and frames are not combined.** A frame instance a document
*inherits* would have to be measured against the one its ancestor holds,
overrides and all, rather than against the plain instance of its class, and
nothing in a component records which of the two it came from. Writing the wrong
one puts the ancestor's overrides into the descendant's file, so a document that
is both built on another form and uses frames is refused outright rather than
written wrongly.

**Staleness is reported rather than resolved.** The ancestor stub reflects the
files as they were when the document opened; editing an ancestor in another
window does not reach it until the document is reopened. One process can hold a
form and the form it is built on, or a frame and a form that instantiates it.
Those documents stay independent, and both say so: a load records every other
form file it read and why (`TSourceKind`, through the single funnel
`StreamOtherFile`), the window keeps that list, and the core compares it against
the documents already open as it adopts a window. Both messages panes receive one
line, worded from their own end. Reloading a document when its ancestor is saved
is not implemented.

## Undo and Redo (`Surface.Undo`)

An entry is the **whole document** as the text a save writes it in, produced by
`StreamDesignedForm` — the save pipeline without the root header, the preserved
splice and the file itself — so an undo entry is by construction what a save
would have produced. It is text rather than the filer's bytes for one reason: a
frame instance's declared class exists only in the text, and a step that could
not name the frames it holds could not resolve them again on the way back. Beside
it the entry holds the selection by name, a tag, and a copy of the preserved
pieces: those components were never loaded, so the image holds nothing of them
and a step that did not carry them would lose them.

**Restoring is a reload, not a patch.** The image is streamed into a new stub
through the same `BuildDocument` the open path uses, and the old document is
freed — frames included: they are resolved and built from disk again rather than
carried across, which keeps one path for both ways in. This is the only approach
that works: a form file holds no property that still has its default value, so
re-streaming an image over the live root could never take a property *back* to a
default, since the image does not mention it. A stub starts at the class
defaults, so it can.

**Pushed before the step, never after.** Every mutating entry point records the
state to return to first: a drag or resize drop, a keyboard nudge, a placement, a
paste, Del, a property write in the inspector, a tile drop on the icon canvas,
and the modal sizing loop of the root's own window frame. Three of those need
care:

- **The icon canvas moves the tile while dragging**, so the drop restores the
  start position, records the step, and only then applies the new position.
- **The window frame resizes the form outside the designer's control**, so
  `WM_ENTERSIZEMOVE` records the step and `WM_EXITSIZEMOVE` discards it when the
  size never changed.
- **A step that did not happen is discarded**: a failed placement, a rejected
  property value and a gesture that ended on the rectangle it started from leave
  no entry behind.

**The designer chrome is moved to the end of the tab list around a capture**,
exactly as it is around a save, and for the same reason: a grab handle is a
window in its parent's tab list while it is attached, and `TabOrder` is the index
in that list, so a control put into the document while the chrome is up would be
written with a number that counts it. Moved, not detached — taking a window out
of its parent destroys it, which repaints the control underneath through the gap
and releases the mouse capture a resize arrives on. Moving a window inside the
tab list touches no window at all. All four kinds move: the handles, the drag
frame, the outline drawn around every non-primary member of a group, and the tile layer.

**A change made inside a hosted design window is a step too** — one per change,
which is the granularity the IDE has. Those editors report nothing before they
act, so there is no moment at which a before-state could be recorded for one; the
document keeps a **settled image** of itself as of the last step that finished,
and such a change is measured against that.

**Coalescing** is by tag — the operation plus the selected component's name — and
applies to nudges only, so holding an arrow key down produces one step while two
separate drags produce two. Any other operation, a different selection, and every
undo or redo break the run.

**The restore is posted, not performed on the spot.** The chord usually arrives
inside the designed form's own window procedure, and the restore destroys that
form; the shell posts itself a message and rebuilds once that procedure has
returned. The Edit menu and the surface chord both go through
`TFormDesigner.RequestUndo`, which refuses while a gesture is in flight — one
place, because the refusal has to hold whichever way the request arrived. The
icon canvas drags on its own state machine rather than the designer's, so it
reports its gesture through `ExternalGesture` instead of guarding its own key
handler.

**Dirty is a distance, not a flag.** The stack records how deep it was when the
file was last written; the document is clean exactly at that depth, so undoing
past a save shows the `*` again and redoing back to it clears it. Discarding a
redo branch that held the saved state puts it out of reach and the document stays
dirty. `UndoStackLimit` is 100 entries, and the stack is cleared when a file is
opened.

## The Settled Image (`Surface.FormDesigner`)

Every step the designer runs itself records the state to return to *before* it
applies anything. A hosted design window — a collection editor, for example —
runs its own step and reports it only once it is done, so there is no moment at
which a before-state could be taken for one. The document therefore keeps a
**settled image**: the streamed document, the preserved clone and the selection
name as of the last step that finished. A change reported from outside is
measured against that, because by construction it is where that change started.

**One entry per report**, which matches the IDE, where collection-editor edits
undo one at a time.

**The image is captured on a timer beat**, and that is not an optimisation:

- `Modified` is the one funnel every completed change goes through, its own and
  the hosted ones alike, so it is the only place that arms the beat. A step that
  reports several changes arms it once — a multiple-selection move raises
  `Modified` per control.
- **A restore requires the deferral.** `BuildDocument` calls `BeginEditing`, and
  only then does the restore hand back the step's own preserved text and its
  selection. An image captured inside `BeginEditing` would be of a document that
  is not yet complete.
- **A save leaves the image valid** and is not a settle point: a save reads the
  live root and writes elsewhere. Nothing in it changes a byte in the document.

**Two guards keep one change out of the history twice**, and they are not the
same guard. The **grid-edit bracket** (`FOwnGridEdits`) means a report from
inside a row's own write never reaches the queue at all; that is the primary
guard. A **settling still owed** means the image is a step behind, and pushing it
would take the previous step back along with this change, so nothing is pushed:
no entry rather than a wrong one. A capture that fails discards the image for the
same reason.

**A gesture is deferred to, not polled around.** Re-arming on the next beat would
poll as fast as the message pump turns for as long as the mouse is held, so the
beat stops instead and **the gesture arms it when it ends** — at the four points
one does: a drag committed or cancelled, a placement finished, and the frame drag
leaving its loop. `GestureInFlight` is the single question all of it goes
through, and it accounts for the root's own frame drag, which is the only way a
form root is resized and which sets no drag state of the designer's.

## Copy, Cut and Paste (`Streaming.Clipboard`)

The clipboard carries the text form of the copied components as `CF_UNICODETEXT`
— consecutive `object` blocks with no root above them, which is the format the
IDE uses, so components move between both designers. No private clipboard format
is registered.

**A copy writes one block per outermost selected component**, in document order.
A member whose container is also selected is dropped, by the rule delete already
applies. The writer's `Root` is set to the document, which sets its `LookupRoot`
and is what makes every component reference write as a plain name — the ones
inside the copied set and the ones outside it alike. The designer chrome is moved
to the end of the tab list around the write, exactly as around a save and an undo
capture.

**Four things are refused**, each with a line in the messages pane: the root,
which is the document rather than something in it; a placeholder, whose text is a
span of the file it was read from and which nothing in the component tree stands
for; a frame instance, whose block reads `inline` against the frame's own file;
and a component held by a frame instance. An inherited component is copyable — no
ancestor is passed to the writer, so its full property set is written and the
copy is an ordinary component.

**A paste is one reader pass over the whole fragment.** The blocks are split by
the span scanner (`TDfmFragment`) rather than by counting `end` lines, converted
one at a time — `ObjectTextToBinary` converts a single object per call — and
concatenated with the one terminator byte `TReader.ReadComponents` stops at. One
pass and not one per block, because a reference between two pasted components
would otherwise be resolved against whatever the document already held under that
name.

**Renaming uses the reader's own two callbacks.** `OnSetName` gives a colliding
name the next free one counted up from its stem, so a pasted `Button1` becomes
the next free `Button` rather than `Button11`, and records old against new.
`OnReferenceName` maps a recorded name and leaves every other one alone:
`TReader.DoFixupReferences` calls it on each pending reference before resolving
it, so a reference to a component that was not copied resolves against the
document and keeps pointing where it did. Names are taken while the component
carries `csLoading`, which keeps the rename out of the validation and the
coupling a user-driven rename goes through.

**A renamed component carries its pattern-named handlers along.** A handler whose
name is the default one built from the old component name becomes the default one
built from the new name, and the unit half is requested through
`ensureEventHandler` exactly as an event row requests one. A hand-named handler,
and one named for another component, are left pointing at the method the unit
already declares. The mapping runs in `TDesignReader.FindMethodInstance`, which is
where both the component and the event property are known.

**A paste that would rename a handler is refused on an uncoupled document.** The
unit cannot gain the method there, and `TReader.FindMethod` raises for a method
the form class does not declare, so the form file would name one that is not
there.

**Positions are kept, and the group is offset only when it lands on something.** A
pasted control keeps the `Left` and `Top` it was copied with; if a control that
was not pasted already stands at exactly those bounds, the whole pasted group
moves one grid step in both axes until it does not, so the relative positions
inside the group never change. A component without a window carries its tile
position the same way, through the `Left` and `Top` the filer defines over
`DesignInfo`.

**Every refusal creates nothing.** The components read before it are freed by
rescanning the root — freeing a container destroys the controls it holds, so a
list built once would name components that are already gone — and the undo entry
is discarded. One entry per paste, pushed before anything is created. Cut is a
copy followed by a delete, and the delete's own entry is the single step it
leaves; a copy that could not be written does not delete.

Fields need no work here: `DesignedFields` walks the live root, so the next settle
point sends an `addFormField` for each pasted component.

## Object Inspector

`TPropertyModel` builds one row per published property of the selected instance,
sorted by name, from runtime type information. It is type-agnostic, so a
component without a window needs nothing special. Rows carry a kind that decides
both the displayed text and the editor: text, integer, float, char, enum, set,
set element, colour, component reference, sub-object, or read-only. Sets expand
into one row per element; sub-objects such as a font expand recursively; the
event tab is built from the same model over method properties, resolved through
the event-name map.

**Rows come from one of two sources.** The above is the source that is always
available and can describe any object. The other is the property editors the
loaded packages registered — the same ones the IDE uses — reached through
`DesignTime.Designer`. That is the source in use: hosting is on and stays on, and
`HostedEditors=0` is a diagnostic aid for asking which source produced a row
rather than a mode the program ships in. `Tests.InspectorRows` is where the two
sources are compared.

The degradation that matters is per row and needs no setting: an editor-backed
row is a descendant of the RTTI row, built over the same property, so it is its
own fallback. An editor call that raises sets a flag and the inherited answer
takes over from there, degrading that row and nothing else. A whole grid
degrading is reported in the messages pane once per class; the source in use is
reported once at startup. Over several components the selection is handed to the
editors as one list, so the intersection and what counts as equal are theirs to
decide — but such a row also carries the other instances, because a row that
degrades has to reach them itself or write half a selection.

What may be edited is the editor's own answer: `paReadOnly` and
`paDisplayReadOnly` are honoured, and `paReadOnly` with `paValueEditable` means a
list or a dialog may set the value while free text may not.

**Two rows are not the editor's to answer for**, because both reach the `.pas`
file: the name, which is a rename, and an event, which is a handler. Neither is
refused outright — the name row goes through the rename register and the event
row through `ensureEventHandler`, and both are refused only where there is no
session to carry the request.

A row with `paDialog` or `paCustomDropDown` gets an ellipsis button beside its
text or list. The undo entry for it is made before the dialog runs and discarded
when the dialog reports no change, which is read from the designer's count of
reported changes rather than from the row's text: a font dialog modifies the very
object it was handed, and the text never differs. A dialog that did change
something is followed by a full re-scan of the document, because such a dialog
may have created components without reporting them.

The tree nests controls by parent and lists the components without a window flat
under the root.

A property with no setter is shown read-only rather than hidden, so the grid
stays a faithful view of the object. Writes go through typed setters and are
validated first: a rejected value leaves the property untouched and is reported
to the log rather than raising a dialog. A refusal that came from a hosted editor
is reported in the editor's own words, since it validates the value more
accurately than this side could.

A data module's size and offset are defined properties rather than published
ones, so runtime type information cannot see them and the grid cannot show them.
The canvas displays them instead.

The grid keeps the editor as an overlay control positioned over the value cell:
an edit box for free text, a drop-down when the row offers choices. Enter
applies, Escape reverts, and moving focus away applies. The editing row is
released before the write, so that a focus change caused by the write cannot
re-enter the apply path.

## Palette and Component Creation

**One registry, two consumers.** `Core.ComponentRegistry` holds the supported
classes and their groups in a single table. The loader registers exactly that
table for streaming and the palette builds exactly that table into categories, so
the palette cannot offer a class the loader would refuse to read back. Whether an
entry is placed as a control or as a tile is not in the table; it is read off the
class itself.

`Palette.Model` is independent of where its content came from, which is what lets
a loaded package's pages stand beside the built-in groups without the palette
control distinguishing them: they are appended after them, named as the package
named them, and marked as dynamic only so they can be dropped again before that
package is unloaded. Glyphs come through `IPaletteIconProvider` for the same
reason: component classes carry their real icons in the resources of the packages
they ship in, so replacing the drawn glyphs with those means replacing the
provider and nothing else. The provider draws directly onto the button canvas
through the palette control's icon hook, and the frame saves and restores the
canvas around that call, because the caption is drawn afterwards with whatever
pen, brush and font it finds.

**The palette is narrowed to the document's root kind.** `Attach` is where a
document arrives, so the buttons are rebuilt there rather than hidden: a data
module holds components and no controls, so a control is not offered on one at
all, and a page left with nothing to show is dropped instead of rendered empty.
The model keeps every item throughout — this is the palette control's view of it,
and the next `Attach` restores the full set. The rule is the one the placement
path already computes (`IsNonVisual`), applied one step earlier; nothing about
which kinds accept a class is in `Core.ComponentRegistry`. The refusal underneath
it remains, because placement is also reached from the icon canvas and from a
double click, so the check that cannot be bypassed is the one that decides.

**Favourites are marks on the model, not a page of their own.** A star on a
component row or a page header is toggled in the palette and stored as a registry
value name under two subkeys of the settings root, one for pages and one for
classes. `Palette.Favourites` reads both once at construction and holds them in
memory; a toggle changes memory first and then writes or deletes the single
value, so nothing is rewritten wholesale. The names are matched as plain text and
are never resolved against the component registry, which is what lets a mark
survive a session in which the package declaring the class was not loaded. A page
mark applies to every item under that caption, including items added to the page
later, which is why `Palette.Buttons` queries `OnItemKind` and `OnGroupFavourite`
while painting rather than being handed a list.

**The search box filters the model, not the buttons.** `TPaletteFilter` answers
what a term matches; the frame debounces the box by 200 ms and records which
categories were expanded before the search so they can be restored when it is
cleared.

**Arming.** Clicking a palette item puts the designer into creation mode and
leaves the button pressed. The palette control reports one click per press, so a
double click arrives as click, double click, click: the placement is taken on the
double click, where it is still distinguishable, and the trailing click is
consumed. `OnCreationFinished` is raised for every way a placement can end, so
the pressed button is released in exactly one place. Arming leaves focus on the
palette, which is why Esc is answered there as well as on the surface.

**Placement.** While armed, `IsDesignMsg` reroutes the mouse: a click creates at
the class's constructor size, a drag creates inside the dragged rectangle,
minimum 8×8. The rectangle is computed in the target parent's coordinates and
already snapped, and it is displayed with the same drag frame the move and resize
gestures use; the gesture in flight decides which container the frame is parented
into.

**The parent is not the control under the pointer.** `csAcceptsControls` is
advisory: nothing in the parenting path consults it, so assigning a button as a
parent would succeed and produce nonsense. The designer walks up from the control
the message names until it finds a windowed control carrying the flag; the root
ends every walk. That walk is the only hit-test, since the control under the
pointer arrives as the message sender.

**A component without a window is placed differently.** It is given an owner and
no parent, and its position is in the *root's* coordinates whatever it was
dropped on. There is nothing to size, so a drag means the same as a click. This
works on a form, on a frame, and on the icon canvas of a data module, which has
no other way in since no designer hook exists there. Offering a control on a data
module is refused with a message rather than parented to nothing.

**Creation order is required.** The component is named before it is parented: a
control whose caption was never touched copies its new name into it, which is
where `Button1` gets its caption without a separate assignment. `TabOrder`
assigns itself when the parent is set.

**A created component reaches the `.pas` through the coupling, not through this
path.** Placement writes the `.dfm` and nothing else; the field is emitted at the
next settle point as an `addFormField` request to the attached session, and a
delete produces the matching `removeFormField`. The two halves are kept in step
by the field ledger rather than by the placement code, so a document opened
without a session designs normally. Such forms run either way, because loading
skips fields a form does not declare.

## Component Packages (`Packages.Host`)

The program is built **against runtime packages**, and that is the mechanism
rather than a packaging preference. A component class created inside a `.bpl` has
to be the *same* class this program streams, and that holds only while both share
one runtime. It brings a launch dependency with it: the executable resolves
`rtl<suffix>.bpl` and `vcl<suffix>.bpl` at process start, so the IDE's `bin`
directory must be on `PATH`. When it is not, the program does not start and the
message comes from the Windows loader; nothing in this code can catch it.

**Two lists, with different authority.** The settings key holds a `Configured`
subkey whose value names are package paths and whose data orders the loading; a
relative path is resolved against the executable's directory. A path already
named is not loaded twice, matched case-insensitively. Beside it stands what the
IDE has installed, read out of the IDE's own registry keys (`Packages.Discovery`),
which is an *offer*: governed by `Discovery` and narrowed by `AllowList` and
`Exclude`. The configured list is never narrowed by those filters. Both lists
honour the `Disabled` subkey. The manager dialog writes `Configured` and
`Disabled` and nothing else; the IDE's own keys are read-only input throughout.

`DefaultAllowList` returns `*`, so discovery loads everything the IDE has
installed unless the value is set. `AllowList` remains available as an optional
narrowing for bounding a session while investigating one package.
`DefaultExclusions` excludes the `madExcept*` family, whose initialization hook
turns an exception during a load into a modal dialog.

**`Discovery`, `AllowList` and `Exclude` have no dialog control.** None of them
can display what it did: a change takes effect at the next start, and
`SurveyPackages` never reconsiders a row that already loaded, so every IDE row
continues to report `loaded` whatever the setting is. They are registry values
beside the other instruments for bounding a session.

**Which key** is `LoadPackagesFrom`'s argument, set before anything reads it;
`LoadConfiguredPackages` is the call that names this release's own.

The IDE's lists are **inputs**. Which packages exist and which of them it has
switched off is the IDE's state; nothing here writes those keys. Their paths are
written through the IDE's own variables (`$(BDSBIN)` and others), so a path out of
them is not a path until `ExpandPackagePath` has resolved it; one that cannot be
resolved is left as it stands and fails as a missing file rather than as a
silently different one.

**Nothing is loaded before it has been inspected** (`Packages.Preflight`).
Loading is the point of no return, because a package's unit initialization runs
inside this process the moment the loader is through with it, so what can be
decided from the file is decided first: it exists, it is 32-bit (a 64-bit sibling
of the same package is expected and is skipped with a line rather than an error),
it is built against the same runtime release as this program, and it is not
already in the process. Every verdict is a skip: the others still load, and a
form using the skipped one degrades as it always does.

**A package's own dependencies come first** (`Packages.Dependencies`). What it
imports is read out of its import table and loaded deepest first, searched for
beside it, then with the IDE, then along the search path. What is already in the
process is left alone, because loading a package a second time would run its unit
initialization a second time. One that cannot be found stops the candidate before
it is loaded and unloads whatever was loaded for it, so there are no half-loaded
chains. Dependencies are unloaded after the packages that needed them, in reverse
order. Recursion stops without an error past `MaxDependencyDepth`, which is 16.

**One framework at a time, and the runtime records which.** The class registry is
partitioned into a group per framework, which is how the same name means one
thing here and another under a different framework, and why the same families —
actions, action lists, image lists — are deliberately registered on both sides. A
name is resolved only in the groups currently active, and **a framework makes its
own group active as it registers its classes**, which no package announces and
none reverses. The active group is therefore a claim to be renewed rather than a
setting: this program claims VCL forms once before anything loads and again after
every load, in the same place the registration hooks are reinstated. Left alone,
the last framework to register would decide what `TPanel` means, for the palette
and for reading a form file back.

Which framework a class belongs to is the registry's own answer (`ClassGroupOf`),
so nothing here needs to know what other frameworks exist. Two groups are kept:
this program's own, and the **root group** every framework's group descends from.
A class belonging to no framework lands in the root group, which is where suites
meant to work under either framework register themselves on purpose — the
network, database and REST components among them. Keeping only the first group
would discard those along with the foreign ones. Supporting another framework
later is a question of which group is claimed, not of new machinery.

**A package already in the process is not loaded again, but it is still asked
what it registers.** A dependency is loaded and never registered from, so a
package that arrives as another package's dependency and only later comes up as a
candidate in its own right was previously skipped as a duplicate, and its palette
page was lost. Which of the two happens is decided by load order alone, and once
discovery is not narrowed that order is the IDE's registry order, which does not
reflect who requires whom. Such a candidate is therefore taken up where it
stands: the module already in the process is used, everything after the load runs
as it would have, and only the load itself is skipped. What was taken up this way
is not unloaded here either, because the dependency loader unloads what it
loaded. Only packages **this program loaded itself** are taken up; one that was in
the process for other reasons — the ones this program is built with — is still
skipped.

**Icons come out of the file, not out of the module** (`Packages.Icons`). A
package is mapped a second time as plain data, with `LOAD_LIBRARY_AS_DATAFILE` so
no package code runs, its bitmap resources are read, and every `TBitmap` is
copied before that mapping is released, so nothing is a handle into a module that
can be unloaded. A resource name is the class name with the size appended, so the
unsuffixed bitmap is the one a class is offered under and a suffixed one is used
when there is no unsuffixed one. The result is chained in front of the drawn-glyph
provider through the same `IPaletteIconProvider` interface, so a class without a
bitmap is displayed exactly as before.

**Two sets come out of a package, and they are not the same set.**

| Source | Yields | Used for |
|---|---|---|
| The `RegisterComponents` hook, while the package's `Register` procedures run | the pages and classes the package curates | palette entries |
| Type information for every module the candidate brought in | every `TComponent` descendant declared there, internal ones included | `RegisterClass`, so `TReader` resolves them |

The second is deliberately the wider one. A form file may name a class the
package never put on a palette — an internal dialog, for example — and that has
to stream rather than degrade. Registering the wider set and offering the
narrower one produces both.

**The wider set spans the dependencies.** A suite split into a design package and
the runtime packages its classes live in registers those classes *from* the
design package, so the palette entry for such a class comes out of a module that
does not declare it. Walking only the candidate's own type information would
offer classes the loader could not read back, which is the one thing the
single-registry design exists to prevent, so the walk covers the candidate and
everything loaded for it.

**But only as far as a form file can reach.** A package that declares itself
design-time only (`pfDesignOnly` in its own package information) is never linked
into the program a form belongs to, so no class of it can stand in a form file.
Those are skipped, and skipping them is not tidiness: every design package pulls
in the IDE's own, which carries a second class for many a familiar name, and
taking those on collides over classes nothing here could use. What the palette
offers is checked separately, so a page naming a class out of a module that was
not walked still cannot be offered unreadably.

**`Register` procedures are found in the export table, never by name.** Their
mangled names normalize the unit's spelling, so a name constructed from the unit
names a package reports would not be present. The export directory is walked and
every entry ending in the registration suffix is called. A unit whose name
contains dots mangles into several segments, which the suffix scan covers and a
constructed name would not; a static dump of the file misses these exports
entirely, so the walk runs on the loaded module.

**The hooks are installed before anything of a package runs.** Registering
components with no hook in place raises, and a package registers as readily from
its unit initialization — during `LoadPackage` — as from `Register`. The hooks go
in first and the capture target is set *before* the load, not after it.

**All three hooks, not the two that look relevant.** The runtime offers a hook
for palette registration, one for registration without an icon, and one for
declaring which classes are not to be offered as automation components. Only the
first two concern a palette, but *any* of the three raises when it is not
assigned — and a `Register` procedure that raises stops there, taking every
registration it had not reached yet with it. A package calling the third one
first would appear to register nothing. The third hook therefore exists and does
nothing.

**Design-time windows require a registered form designer.** An editor's dialog
may be one of the design-time layer's own windows. Such a window queries a
registry for a component designer matching the extension a form is designed
under and follows the answer without checking it, so with nothing registered it
fails before it is shown — and because the layer builds those windows inside an
exception guard, it fails silently: the editor call returns normally, nothing
reports a change, and the button appears inert. Collection editors are the common
case.

`DesignTime.Environment` is the first half of the answer: the environment object
a component designer cannot be built without. It is installed by `Packages.Host`
alongside the registration hooks, and the core installs the provider that answers
`GetMainWindowSize` from the active document window. Of its 32 methods that is
the one with a real answer; the rest report themselves once each, so what a
package actually requires is established from evidence.

**The second half is the IDE's own designer package, completed rather than
replaced** (`HostFormDesigner`). Registering a designer of this project's own was
measured and did not open the windows: with one registered, the two steps that had
been failing both ran and nothing raised, and the dialog still did not appear.
What works is loading the package the IDE ships, calling its exported initializer
with the environment stub, and activating the `.dfm` designer it registers. Two
details are required: the hooks are reinstated after that load and again after the
initializer, because both register as freely as a `Register` procedure does; and
any form the package shows on its way up is hidden and named in the log, because
it is the IDE's window and not this program's. `HostFormDesigner` runs once per
process, and only while `HostedEditors` is on — the same setting that decides
whether the inspector's rows come from the editors.

**The hooks are the runtime's questions; the IDE's service layer is queried
directly.** A design package also reaches past every hook into
`BorlandIDEServices`: one registers IDE wizards for the personalities it finds
and removes them in a unit finalization, and with no service object in place both
ends dereference nil — the first inside the guarded `Register` call, the second
during the shutdown unload, where only the unload loop's own guard stands.
`DesignTime.IdeServices` is therefore installed before anything loads, together
with the hooks, and left in place: it reports no personalities, so no wizard is
ever registered; it accepts the bookkeeping of removing one; and it answers every
service nobody has been measured requiring with a refusal, which a caller meets
as a catchable error instead of a call through nil.

**A refusal is catchable, which does not make it harmless.** A package that casts
with `as` rather than querying first meets that refusal as an exception in the
middle of its own initialization, and the whole package fails to load. One
unserved interface, `IOTAProjectFileStorage`, accounted for eighteen such
failures, where a design package stores its own settings in a project file. There
is no project file here, so the answer has the same shape as the wizard one:
accept the notifier bookkeeping, retain nothing, answer nil for a document tree
this program does not have. Serving it took the failures from 21 to 3 and the
palette from 395 entries to 563. The three remaining are version-control plugins,
which register no components.

Which interface a failing cast wanted is not determinable from the outside.
Making the stub report every interface it refuses — through the cast that raises
and through the two lookups that answer past it, once per distinct refusal per
package load — is what turns "some interface was unsupported" into a name. **That
reporting stays in.** It produces a line only where a service is actually
missing, and a machine with other packages installed can fail the same way for a
reason nothing else would report.

**A package failure is diagnosed from a log, not from a debugger**, because the
machine it occurs on is usually not a development machine and the package is
usually not one that can be stepped into. `Packages.Stacks` installs the RTL
stack-info hooks before the first load and names every address it captures as its
module, the offset into it, and the exported symbol below it. The frames come
from a scan of stack slots for return addresses recognized by their call opcodes,
because the 32-bit RTL and VCL are built without frame pointers and there is no
chain to walk, which means a listed frame may name a call that has already
returned. Win32 only, and not thread-safe: the module and symbol caches are unit
variables reached without a lock.

**Failure is contained at three levels**, because the designer has to start no
matter what is configured: a path that does not exist is a warning and the rest
still load; a package that will not load is an error and the rest still load; a
single `Register` procedure that raises is a warning and its siblings still run.
The last of the three is not defensive polish: a design package commonly spreads
its registrations over several procedures, and the palette of one depends on the
others being called. It is a poor diagnostic, though — a procedure that raises
has usually requested something that is not answered here, and the message names
the call.

**A class name is claimed once.** A name already known, from the built-in table
or an earlier package, leaves the later entry off the palette with a warning. Two
different classes under one name is what the streaming registry cannot represent.

**Loading happens before there is anywhere to report it.** The palette is built
while the main window is being created, so packages have to be loaded before
that. The log is buffered in `Packages.Host` and handed to the document's log
once the messages pane exists (`ReportInto`).

**Every candidate leaves a verdict behind, loaded or not** (`TPackageStatus`).
The manager dialog displays what happened to a package this session never
touched, which is most of them, so `SurveyPackages` starts from what the session
did and evaluates everything else fresh — the pre-check first, so a fact about
the file outranks a setting, and only then whether it was switched off, held back
by the allow list, or never offered. What was loaded is settled and is not
re-evaluated.

**The manager dialog writes settings and nothing else** (`Packages.ManagerDialog`,
Tools → Packages). It cannot load or drop a package: the palette holds its
classes, the document holds instances of them and the streaming registry holds
them by name, so what it decides is written to the settings key and read at the
next start. The dialog states this, which is why it is a settings dialog rather
than a lifecycle one. It is built in code like the other dialogs here.

**The teardown order is required.** Leaving a package loaded at process exit
disturbs the shutdown and discards whatever was written last — for the test
runner that is its own summary, which is why truncated output is the regression
signal for this. Everything naming a class of a package releases it first: the
document and its instances, then the palette model (`DropDynamicItems`), then the
registry entries and the harvested icons, and only then the packages themselves
in reverse load order, followed by the dependencies loaded for them. In a window
that sequence sits at the end of `FormDestroy`, the last point at which the
document is certainly gone; placing it after `Application.Run` would be too
early, since the main form is owned by `Application` and outlives that call. Undo
snapshots are safe by construction: they hold text, not classes. Unloading
mid-session is not offered — restarting is how a changed package is picked up.

**A package that is not installed leaves its components unknown and nothing
else.** The classes are not registered, so the blocks are kept verbatim and
displayed as placeholders, and the file still saves byte for byte.
`pica_components.dfm` and `teechart_form.dfm` are run through the round-trip test
both ways to hold that.

## Hosting the Design-Time Layer (`DesignTime.Designer`)

A design package registers property and component editors as readily as it
registers components, and those editors are what the IDE's own inspector shows.
This program links the design-time package as a runtime package and presents
itself to them as a designer, so the same editors serve its rows.

**The interface is large and what is required of it is small.** The designer an
editor holds spans eight interfaces and some sixty methods, but enumerating,
reading, writing, drop-downs, expansion and every editor dialog measured so far
exercise exactly two: the selection, and the report that something changed.
`TVallentaDesigner` answers what the document knows — the root, its components
and their names, the naming rule, the selection both ways, the methods the event
map holds — and returns a fixed value for the rest. Which of those fixed values
is a gap and which is merely true of this program is what the once-per-method
line in the messages pane establishes: a suite requesting something unanswered
appears as a line rather than as a failure.

**The standard editors are registered by this program.** A component package
registers its own; the editors for colours, cursors, fonts, component references,
brush and pen styles, shortcuts and modal results belong to the IDE, and outside
the IDE nobody performs those registrations. Without them a hosted inspector
displays a colour as a number and an unset reference as a class name.
`InstallStandardEditors` performs them at startup, before any package's
`Register` runs, so a package registering its own editor for the same type still
wins by being the more specific answer.

**One designer per document.** `TFormDesigner` builds it on first use, so it
finds the event map the load installed, hands it the document's own naming rule,
and releases it before the event map and before any package can be unloaded from
under it. It carries the current selection whenever it is handed out, because that
is what the editors are served from.

Every call into an editor is exception-guarded, and a failure degrades one row:
the editor-backed row descends from the type-information row over the same
property, so degrading is a flag rather than a rebuild. What survives that guard
is the one ceiling this has: an editor reaching past the designer into the IDE's
own service layer cannot be served and degrades to its plain row.

## Notifications

`TFormDesigner` raises the following, all single-cast:

| Event | Raised when | Consumer |
|---|---|---|
| `OnDirtyChanged` | the dirty flag changes | window title |
| `OnModified` | every change, not only the first after a save | the recovery journal, which needs more than the one-bit dirty flag |
| `OnSaved` | the document was written | the window. Refused for a guarded document; a failed write is logged rather than raised |
| `OnSaveRequest` | the save chord is pressed on the surface | the shell's save action |
| `OnUndoRequest`, `OnRedoRequest` | the undo or redo chord is pressed | the shell, which defers the restore |
| `OnSelectionChanged` | the selection changes | tree and grids |
| `OnStructureChanged` | a component is created or deleted, and after any hosted editor's dialog that reported a change | tree rebuild |
| `OnComponentsChanged` | together with `OnStructureChanged` | the owning window, where `OnStructureChanged` goes to a pane |
| `OnGeometryChanged` | bounds or a tile position changed through a gesture | geometry rows |
| `OnCreationFinished` | a placement ended, however it ended | palette releases its pressed button |
| `OnContextMenu` | the right button is released, after the press has selected | the menu host, which reads the selection and cursor position itself |

Three are queries rather than announcements, and they are answered by the window
because only it holds the session reference: `OnCouplingQuery` answers whether a code
coupling is available, `OnRenameRequest` sends a rename, and `OnRenameQuery`
answers whether one is still pending. A rename answer can arrive **after a
restore has replaced the designer**, which is why the request is routed through
the window rather than held on the designer that sent it.

Repainting is not an event: the designer invalidates `SurfaceControl` directly,
which is the root's own window for a form or frame and the icon canvas for a data
module.

## DPI Policy

The design PPI is pinned to 96 and the designer reports the low-DPI design mode,
so a document loads, renders and saves at its authored size on any monitor and
the round-trip comparison stays machine-independent.

**The program itself is per-monitor DPI aware.** `AppDPIAwarenessMode` is
`PerMonitorV2` and `Manifest_File` names `$(BDS)\bin\default_app.manifest`,
because leaving it at `(Default)` emits **no manifest at all**: the setting
resembles a default that keeps the IDE's, and produces an executable the desktop
stretches. The symptom that identified it was a control given 320 pixels covering
400 on a monitor at 125%, while mouse coordinates still arrived in the 320 the
program had requested.

The two settings are independent, which is the point of this section: the shell
scales with the monitor, the *document* does not. A form is designed at the size
it was authored at, whatever scale the shell is displayed at.

A form whose stored PPI is not 96 is rescaled as it loads, and that is not saved
back; the designer logs a `[warn]` line for that case rather than silently
rewriting the file.

## The Round-Trip Test and the Suite Around It

`RoundTripDfm` runs the full designer path with nothing shown, saves to `%TEMP%`,
and compares byte by byte, reporting the offset, both bytes and the differing
line from each file. It builds the same document the shell does, frames parented
to their host included. `Tests.RoundTrip` calls it in process and carries the
matrix as `[TestCase]` rows, each fixture with its own expectation, so a fixture
that is *supposed* to differ still asserts something: it round-trips, or it
refuses to load with a documented message.

**One package situation per process.** Packages are never unloaded mid-session,
so the suite establishes its situation once — `BeginDesignerSession` in
`Tests.Environment`, which brings up the VCL application, registers the standard
property editors and loads the design packages, and does nothing on every call
after the first. `EndDesignerSession` unloads them once everything holding a
class has been released. **The suite configures no packages**, which makes the
situation the code's own defaults: discovery on, no allow list narrowing it,
nothing configured by hand, so every design package the IDE has installed is
loaded. Pointing `LoadPackagesFrom` at another key below `HKEY_CURRENT_USER` is
how a run is deliberately given something else, and that is what the favourites
cases do so they never write the key the product reads.

That is also why the degradation cases read as they do: `pica_components.dfm`
runs with its package **absent**, because nothing configures it, and
`teechart_form.dfm` runs with its components **present**, because the IDE has its
design package installed. Both round-trip either way.

Several fixtures are only meaningful **together**: a frame or an ancestor is
found by looking beside the document, so `frame_host.dfm` needs `frame_child.dfm`
in the same directory and `vfi_grand.dfm` needs both `vfi_child.dfm` and
`vfi_base.dfm` with their companion units. Copying one out on its own makes it a
different test, which is exactly what `frame_missing.dfm` and `inherited_form.dfm`
are.

**Fixtures are working-tree files, not repository files.** The suite finds them
by walking up from the test executable until a `fixtures` directory holding
`basic_form.dfm` appears. A suite that silently found none would report success,
so a missing directory raises instead.

**A `[TestCase]` splits its values on commas by default.** That silently reduced
four of seven malformed-request rows in `Tests.SingleInstance` to a fragment, all
of them then exercising the same parse-failure branch while the suite reported
green. Pass an explicit separator, and have each row assert the particular answer
it expects rather than merely that there was one.

**A passing case proves nothing until the condition it watches has been broken
once.** Every guard here was mutation-tested: the settled image, the frame drag
counting as a gesture, the re-arm when it ends, the chrome sink (which fails with
a tab order of 11 where the document's own controls make 3), and the log ring's
ordering.

## Fixtures

| Fixture | Covers |
|---|---|
| `basic_form.dfm` | Stub streaming, font sub-properties, set values, anchored child |
| `nested_panels.dfm` | Nested containers, alignment, non-windowed control |
| `event_handlers.dfm` | Event names survive |
| `roundtrip_events.dfm` | Event names survive with one handler shared by two components |
| `roundtrip_types.dfm` | Boolean, enum and string-list values, nesting, a component reference |
| `roundtrip_image.dfm` | Binary blob property (`Picture.Data`) — generated, never hand-written |
| `string_continuation.dfm` | Long-string continuation and escaped characters |
| `frame_basic.dfm` | A frame root, classified from its companion `frame_basic.pas` |
| `frame_sniffed.dfm` | A frame root with no companion, so classification falls to the property sniff |
| `frame_child.dfm` | The frame `frame_host.dfm` uses; a frame root in its own right, so it round-trips on its own as well |
| `frame_host.dfm` | A form holding a frame instance with two overridden children — the block stays `inline`, the overrides stay `inherited`, and the frame's own contents stay out of the host's file |
| `frame_missing.dfm` | A frame instance whose class no file beside the document declares; it degrades to being kept verbatim rather than refusing the load |
| `frame_outer.dfm` | A frame that uses a frame of its own; as a document it loads and round-trips, and the inner block shows the diff working |
| `frame_nesting.dfm` | The same file used *as* a frame, which is refused and kept verbatim instead |
| `nonvisual_on_form.dfm` | A positioned `TTimer` beside controls; a design-time timer that runs |
| `datamodule_basic.dfm` | A data module root with two positioned components, classified from `datamodule_basic.pas` |
| `unknown_property.dfm` | Unread property lines are kept and put back where they were |
| `unknown_class.dfm` | An unknown class is kept verbatim rather than aborting the load |
| `preserved_unknown.dfm` | An unknown windowed container with a nested unknown inside it, an unknown component without a window, and unread properties on the root and on a control; the tab slot of the unknown container is held, so its siblings keep their own |
| `vfi_base.dfm` | The form the other two are built on; an ordinary form in its own right |
| `vfi_child.dfm` | A form built on it — an override on an inherited component and one component of its own; what it did not change is not in its file |
| `vfi_grand.dfm` | A third level, which is what shows the chain followed more than one step and the files streamed base-most first |
| `inherited_form.dfm` | A form built on another with nothing to identify which; refused, naming what is missing |
| `pica_components.dfm` | Two classes out of a runtime package beside a built-in button, with an event assignment and properties the package declares. Run both ways: with the package it streams and round-trips, without it the two blocks are unknown classes kept verbatim, and the button keeps the tab slot the stand-ins hold for it |
| `teechart_form.dfm` | A class out of a *design* package — one that arrives with a dependency chain, registers editors it cannot install here, and ships real icons — beside a built-in button. Run both ways in the same manner |

Two files sit in the same directory with no expectation, because the matrix knows
only the fixtures listed above. `blank_form.dfm` is the empty canvas the manual
palette pass places components on. `crossversion_newer_property.dfm` is a form
written by a **newer** release than the one under test, held for opening by hand;
no case names it. It declares `TForm1` as `basic_form.dfm` does, so every run
reports that both declare the name and which one the class index kept. That line
is expected output.

The companion `.pas` files exist only for the classifier to read; they are never
compiled. Copying a fixture *without* its companion is how the property-sniff
stage is exercised deliberately.

## Constraints and Pitfalls

- **Fixtures are exactly what the writer emits.** A hand-authored file does not
  survive the round-trip comparison: line endings must be CRLF, a property whose
  value equals its default is not written at all, and an auto-sizing control
  stores the width it measured rather than the width it was given. Author a
  fixture, put it through `RoundTripDfm`, and inspect every difference before
  adopting the output; adopting it unexamined would bake a save defect into the
  fixture. A binary blob cannot be authored at all: the bytes have to come from
  the framework's own writer, streaming an object built for the purpose.
- **Never leave state on a borrowed canvas.** A form re-measures the text height
  it stores at save time through its own canvas, so a font left behind by the
  tile renderer silently rewrites that property. Anything drawing on a borrowed
  canvas restores what it touched. The headless round-trip test cannot catch
  this: it never paints.
- **`Application.MainFormOnTaskbar` is safe only while the shell is the main
  form.** The stored `ShowInTaskBar` property is acquired by whichever form is
  the application's main form; a designed form holding that role ended up with
  the property in the saved file. Never let a designed form, or a frame's host,
  become the main form.
- **A data module created in code has no `PixelsPerInch` at all**, and zero is a
  value the filer stores. The stub starts at the default screen DPI so the
  property disappears again unless the file names one.
- **A set constructor cannot hold window message or system command constants.**
  They exceed the range a set element may have. Use a `case` statement; the
  compiler error points at the set, not at the cause.
- **Never shadow a stored property of the designed root.** The window title
  belongs to the shell precisely so a form's own `Caption` stays untouched and
  stays editable in the inspector; a frame's host is placed around it so its
  `Left` and `Top` stay untouched for the same reason. Anything the designer
  needs to display about the document goes on the shell. The save path asserts
  rather than repairs: it checks that focus never moved and lets the byte
  comparison catch the rest.
- **An instance handed to the reader is not adopted by it.** The reader assigns
  an owner only to instances it builds itself, and only what the root owns is
  ever written, so a pre-built frame handed over without one is silently left out
  of the saved file. It has to be created with the reader's own current owner.
- **A block reads `inline` because the instance is marked, and for no other
  reason.** Nothing about the class, the file or the ancestor decides it. This
  was measured before anything was built on it, by putting a fixture through the
  writer and comparing bytes.
- **A frame instance without an ancestor is written out in full.** The ancestor
  callback is not an optimisation: without it the frame's entire contents land in
  the host's file as ordinary blocks, and the next load of that file has two
  copies of everything.
- **Designer chrome must stay unowned.** Giving the handles an owner would put
  them into the saved file. They are also in their parent's tab list while
  attached, and `TabOrder` is the index in that list, which is why a save, an
  undo snapshot, a clipboard write and a settled image all move the chrome to the
  end of that list first. Moved, not detached: taking a window out of its parent
  destroys it, which repaints the control underneath through the gap and releases
  the mouse capture a resize arrives on.
- **`EClassNotFound` under the IDE debugger is the placeholder mechanism working,
  not a failure.** An unknown class is how the reader reports one, and it is
  caught and answered with `Handled := True`; the debugger reports every raised
  exception first-chance whether or not anything catches it. Opening any form
  with a class the designer does not know produces it. The messages pane
  distinguishes the two: "kept as it stands and shown as a placeholder" means it
  was handled.
- **A lookup finding no class of that name does not mean the name is free.** The
  class registry keeps its classes in groups, one per framework and one for
  design time, and answers a lookup out of the groups currently in use, while
  registering a class reaches the group that class belongs to whether in use or
  not. A name can therefore be taken where no lookup here can see it, and
  registration then raises where the lookup reported nothing. Only the attempt is
  authoritative, which is why registering is exception-guarded per class rather
  than decided in advance.
- **A control hosted over a grid cell is isolated twice over.** A grid answers
  the notifications of its own inplace editor and discards every other one
  without passing it on, so a control parented into it receives nothing unless
  the grid reflects the message back explicitly — a button whose click
  notification is discarded never runs its handler, and is indistinguishable from
  a handler that does nothing. And because such a control takes focus when it is
  clicked, the editor beside it reports that it was left: applying there tears the
  overlay down between the press and the release, so the click never completes.
  Both have to be answered for a button beside an inplace editor to work, and
  neither appears as an error anywhere.
- **A row from the editors need not stand on a property at all.** The editors may
  present a row for a component that has nothing behind it — a suite can
  synthesize one to offer something the object does not publish — and such a row
  reports *no type*. That is an answer, not a failure: following it without
  checking is an access violation, and because rows are queried on every repaint,
  it is one per paint rather than one per session. Nil is a value here; only an
  editor that raises is a failure.
- **A class reference must not outlive the package it lives in.** Metaclasses are
  pointers into a loaded module; once it is unloaded, every one of them dangles.
  The palette holds one per entry and the registry holds one per class, which is
  why both are emptied before the unload rather than left to be freed in whatever
  order destruction reaches them.
- **`Exports` is a reserved word.** Naming a local variable for the export
  directory produces a page of misleading parse errors about global scope.
- **A field declared after a method is a compile error** (`E2169`), not a style
  note. Adding a private helper next to the field it works on breaks the class;
  the fields come first.
- **`Application.ModalLevel` counts only forms shown with `ShowModal`.** A
  `TColorDialog` or `TFontDialog` — which is what a property row opens — disables
  windows without raising it. Ask "is any document window disabled" instead.
- **Windows' own move/size loop pumps this thread's messages.**
  `TThread.ForceQueue` wakes the main thread by posting to the application
  window, and that loop dispatches it, so anything deferred is delivered *during*
  a frame drag rather than after it. Any timer beat that must not run
  mid-gesture has to check, and the root's own frame drag is a gesture that sets
  no drag state of the designer's.
- **A guard that cannot fail is equivalent to a comment asserting a guarantee the
  code does not give.** `Core.SingleInstance` carries a compile-time timeout
  check written as a subrange type for that reason; the first attempt at it
  reduced to `AnswerTimeout > AnswerTimeout`.
- **`TCategoryButtons` repaints synchronously on a collection change**
  (`RedrawWindow` with `RDW_UPDATENOW`), so a control that is on screen paints a
  button before the next line has assigned what it stands for.
  `Palette.Frame.BuildButtons` suppresses drawing across the rebuild and sets
  `Data` first. This went unseen while every rebuild happened on a window still
  being built, where the palette has no handle and never paints.
- **`WS_EX_COMPOSITED` is not the answer here.** It was tried on the designer
  window, producing an endless repaint loop, and on the three pane frames,
  producing a quiet palette and inspector, a messages pane that then flickered
  constantly, and a heavy drag. Both were reverted. Suppressing the window's own
  background erase changed nothing, which indicates the remaining resize flicker
  is not the window's.
- **A comment that outlives its mechanism is worse than none.** The three found
  in the last audit each sat on the exact function a reader would go to first:
  one explaining a chrome detach that had become a sink, one describing a journal
  contract a fix had already replaced, and one justifying a `MarkKept` that no
  longer behaved that way.
- **Debug tracing is temporary.** Trace calls added while diagnosing are removed
  before the change is finished. Two constraints apply while they exist: a
  `Format` argument is evaluated before the callee's `if FLog <> nil` guard can
  help, so anything a trace dereferences needs its own nil check; and an expanded
  row of a sub-object stands on no instance of its own. The one deliberate
  exception is the service-refusal reporting described under Component Packages,
  which reports a fact about the machine the program is running on rather than
  about a defect being investigated.
