# Changelog

All notable changes to **Vallenta Designer** will be documented in this file. Versions follow the file version the executable reports in its version information.


## [0.8.1] unreleased (put new entries here!)

### Changed
- **Palette** — the Components and Favourites tabs are rebuilt together, and a tab keeps its expanded categories across a rebuild.
- **Package loading, an exception the VCL handles itself** — such an exception is now written to the log with its stack instead of being shown in a message box.
- **VCL style** — loaded at startup from the `Styles` folder of the Delphi release the designer runs against instead of being linked into the executable: Windows Modern where the release ships it, otherwise Windows10.

### Fixed
- **Design surface** — the form takes mouse input where it is displayed, also after a pane beside it is resized or the surface is scrolled.
- **Palette** — a double click on the header of a collapsed category places nothing.
- **Palette** — a click on the header of a collapsed category expands it instead of arming one of the components the category hides.
- **Packages, a design package exporting methods named `Register`** — a package's registration procedures are now identified by the mangled name of each unit it contains, and loading such a package no longer raises an access violation.
- **Packages, EurekaLog installed in the IDE** — the EurekaLog packages are excluded from discovery, and starting the designer no longer shows the EurekaLog trial message box.
- **Building with Delphi 13.0** — the resource step no longer fails on `WindowsModern.vsf`, which ships only with Delphi 13.1 and later.


## [0.8.0] - 2026-09-08

First published source release. Beta.

### Added
- **Design surface** — select, marquee, move and resize against a grid, nudge and resize by key, delete, and select the parent. Forms, frames and data modules, with an icon surface for a data module.
- **Component palette** — built from the pages the loaded packages register, each component carrying the icon its package ships, with a search filter and favourites kept between sessions.
- **Object inspector** — rows come from the property editors the installed design packages registered, over a component tree, with multiple components edited at once.
- **Component editors** — the context menu offers the verbs a component's own editor registers, and a double click runs its default verb.
- **Undo and redo** — a 100-step history.
- **Clipboard** — cut, copy and paste through the system clipboard in the format the IDE uses.
- **Arrange commands** — bring to front, send to back, align, same size, tab order and creation order.
- **Inherited forms and nested frames** — a frame used inside a form, and a form built on another form, are read and written as the difference from what they are based on.
- **A class no installed package declares** — the component is preserved verbatim and shown as a placeholder.
- **A form referencing a component in another module** — the form opens read-only, naming the modules that could not be resolved.
- **Resident core** — closing the last document window leaves the designer running, a second invocation hands its file to the running core over a named pipe, and the notification area icon reports the open documents and ends the process.
- **Recovery journal** — unsaved changes are journalled as an openable form file and offered back per document after an abnormal termination.
- **Vallenta Studio integration over a named pipe** — adding a component creates its field in the form class, double-clicking an event property creates the handler, and renaming a component renames its field and its handlers.
- **Delphi 11.3 Alexandria, 12 Athens and 13 Florence** — one source tree builds against all three, with each release's output kept apart.

FMX forms and designing inside a VS Code tab are not implemented.
