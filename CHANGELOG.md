# Changelog

All notable changes to **Vallenta Designer** will be documented in this file. Versions follow the file version the executable reports in its version information.

## [0.8.2] - 2026-10-03

### Added
- **Window style** — a list at the right end of the alignment bar switches the designer's own windows to any VCL style shipped with the Delphi release, dark styles included, and keeps the choice for the next start.
- **Menu designer** — the Menu Designer opens from the context menu of a main menu and from its `Items` property in the object inspector.
- **Menu designer, captions** — a key typed in the Menu Designer edits the item's caption in the object inspector, and pressing Enter returns the focus to the Menu Designer.
- **Design surface, main menu** — a designed form shows its main menu as a menu bar below its caption.

### Fixed
- **Design surface, speed** — a drag on the design surface redraws in about 4 ms per step.
- **Main window, resize** — the panes beside the design surface keep their content while the window is resized.
- **Forms built on other forms, a class name declared in several form files** — the ancestor is read from the form file named after the unit declaring the class.
- **Forms built on other forms, a form file copied without its unit** — the form opens when the ancestor's unit lies elsewhere on the search path or is missing.
- **References into another module, a copied ancestor module** — a form referring to a component that a data module inherits from a module copied without its unit opens for editing, without the read-only banner.
- **Frames, a class name declared in several form files** — the frame is read from the form file named after a unit in the uses clause of the form's unit.
- **Log, form files of the same name** — the messages about the other form files read for a document show each file's full path.
- **Log, a class name declared in several form files** — the warning appears once per class, naming every file, and only when the uses clauses of the form's unit do not decide which file applies.
- **Opening a form on a long search path** — a form on a search path of 150 directories that refers to components of two other modules opens in 1.5 s.
- **Messages pane, a burst of messages** — the pane repaints once for the whole burst.
- **Designer start, speed** — the designer starts about 2.5 s faster with some 250 packages installed.
- **Opening a form, a message box from a component** — a dialog box shown by a component while its form is loaded, such as an ActiveX control reporting an error, opens in front of the other windows and is reported in the messages pane.
- **Object inspector, speed** — the component tree of a form with a few hundred components is shown fully expanded without delay.
- **Messages pane, a new window** — a new designer window shows the session's messages without delay.
- **Search path, a directory listed twice** — the directory is searched once and counted once.


## [0.8.1] - 2026-09-20

### Added
- **Alignment bar** — a bar above the design surface opens a menu of the ten align actions, each carrying its own glyph.
- **Design surface, alignment guides** — while Shift or Alt is held, during a drag and after a keyboard nudge, a line runs along every edge the selected component shares with another component on the form, in any container.

### Changed
- **Design surface, drag** — a move or resize snaps to another component's edge within four pixels, in any container, before it snaps to the grid.
- **Design surface, multiple selection** — every selected component wears grab handles, black on the component selected last and grey on the rest.
- **Object inspector, multiple selection** — the component tree highlights every selected component, and a selection of several components can be built in it.
- **Palette** — the Components and Favourites tabs are rebuilt together, and a tab keeps its expanded categories across a rebuild.
- **Package loading, an exception the VCL handles itself** — such an exception is now written to the log with its stack instead of being shown in a message box.
- **Align commands** — an align measures against the extent the selection spans, whatever order the selection was built in.
- **Align and same size, a component whose `Align` property leaves its bounds to its parent** — the component keeps its bounds and the messages pane reports how many were left alone.
- **VCL style** — loaded at startup from the `Styles` folder of the Delphi release the designer runs against instead of being linked into the executable: Windows Modern where the release ships it, otherwise the system style.
- **Packages, log of refused IDE services** — a request for the IDE theming service is reported by its interface name instead of its GUID.

### Fixed
- **Design surface** — the form takes mouse input where it is displayed, also after a pane beside it is resized or the surface is scrolled.
- **Palette** — a double click on the header of a collapsed category places nothing.
- **Palette** — a click on the header of a collapsed category expands it instead of arming one of the components the category hides.
- **Packages, a design package exporting methods named `Register`** — a package's registration procedures are now identified by the mangled name of each unit it contains, and loading such a package no longer raises an access violation.
- **Packages, EurekaLog installed in the IDE** — the EurekaLog packages are excluded from discovery, and starting the designer no longer shows the EurekaLog trial message box.
- **Packages, an IDE expert carrying a dockable tool window** — a package that derives a window from the IDE's dockable form (Devart's DataSetManager, which its installer registers as a component package) is skipped before it is loaded and listed as `skipped (IDE tool window)` under Tools, Packages; loading it raised an access violation inside the IDE's design package and left a half-built window in the process.
- **Design surface, a gesture that moves nothing** — the document stays unmodified and the history keeps no step for it.
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
