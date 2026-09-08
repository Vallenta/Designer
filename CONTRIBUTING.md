# Contributing

The source is published so that bugs can be found and fixed by the developers who hit
them. Issues and pull requests are welcome.

## Reporting

Use the issue templates. The two fields that decide whether a report is reproducible are
the designer version, which the executable carries in its version information, and the
Delphi release the designer was built against — a designer loads only the design packages
of the release it was compiled with.

A problem with launching the designer from VS Code, or with the Form Designer settings
card, belongs in [Vallenta Studio](https://github.com/Vallenta/Studio/issues) rather than
here.

## Building

Requirements are in the [README](README.md): Windows, Win32, and Delphi 11.3 Alexandria,
12 Athens or 13 Florence. This is a runtime-packages build, so the IDE's `bin` directory
has to be on `PATH` at run time; `rsvars.bat` arranges that for a shell.

```
call "%BDS%\bin\rsvars.bat"
msbuild VallentaDesigner.dproj /t:Build /p:Config=Debug /p:Platform=Win32
```

Output lands in `bin\Win32\<Config>\<release>\`, where the release follows from the
compiler performing the build. `scripts\build-all.ps1` builds with every supported release
installed on the machine.

## Running the test suite

The suite compiles DUnitX from [source](https://github.com/VSoftTechnologies/DUnitX). Set
`DUNITX` to a clone of that repository, then run the suite from the repository root:

```
msbuild tests\VallentaDesignerTests.dproj /t:Build /p:Config=Debug /p:Platform=Win32
tests\bin\Win32\Debug\<release>\VallentaDesignerTests.exe
```

It is a console program that exits with the number of failures, so the exit code is the
result. `scripts\build-all.ps1 -Test` does the same for every installed release.

The suite does not link the whole program: the resident core, the main window, the
recovery dialog and the palette frame are compiled only by the product build. A change in
those is covered by running the designer, not by a green suite.

## Pull requests

- Build and run the test suite first. Building one release is enough; a change to package
  loading, the object inspector or the design-time layer is worth trying on a second.
- Every `.pas` and `.dpr` opens with the five-line MIT header. Copy it from an existing
  unit rather than typing it.
- Comments are English and document declarations rather than narrate bodies. The
  `interface` section is documented uniformly; implementation bodies stay bare.
- No source from the Delphi runtime or from a component library may be copied into this
  project. Those sources may be read to learn how something behaves; what lands here is
  written from scratch.

[docs/architecture.md](docs/architecture.md) describes the constraint each part is written
under. Its **Constraints and Pitfalls** chapter collects the ones that compile cleanly and
break behaviour at run time — worth reading before a first change.

## Licence

Contributions are accepted under the MIT licence that covers the project; see
[LICENSE](LICENSE).
