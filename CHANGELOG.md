# Changelog

Notable changes to Vallenta Designer. Versions follow the file version the executable
reports in its version information.

## 0.8.0 — 2026-09-08

First published source release. Beta.

- Design surface: select, marquee, move and resize against a grid, nudge and resize by
  key, delete, and select the parent. Forms, frames and data modules, with an icon
  surface for a data module.
- Component palette built from the pages the loaded packages register, each component
  carrying the icon its package ships, with a search filter and favourites kept between
  sessions.
- Object inspector whose rows come from the property editors the installed design
  packages registered, over a component tree, with multiple components edited at once.
- Component editors: the context menu offers the verbs a component's own editor
  registers, and a double click runs its default verb.
- Undo and redo over a 100-step history. Cut, copy and paste through the system clipboard
  in the format the IDE uses. Bring to front, send to back, align, same size, tab order
  and creation order.
- Frames used inside a form, and forms built on other forms, are read and written as the
  difference from what they are based on. A class no installed package declares is
  preserved verbatim and shown as a placeholder.
- A form referencing a component in another module opens read-only, naming the modules
  that could not be resolved.
- Resident core: closing the last document window leaves the designer running, a second
  invocation hands its file to the running core over a named pipe, and the notification
  area icon reports the open documents and ends the process.
- Recovery journal: unsaved changes are journalled as an openable form file and offered
  back per document after an abnormal termination.
- Vallenta Studio integration over a named pipe: adding a component creates its field in
  the form class, double-clicking an event property creates the handler, and renaming a
  component renames its field and its handlers.
- One source tree builds against Delphi 11.3 Alexandria, 12 Athens and 13 Florence, with
  each release's output kept apart.

FMX forms and designing inside a VS Code tab are not implemented.
