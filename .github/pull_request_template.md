# Description

What this change does, and the problem it solves.

## Related issue

Closes #

## Checklist

- [ ] The test suite was built and run, and reports no failures
- [ ] New units carry the five-line licence header, copied from an existing unit
- [ ] Comments document declarations; implementation bodies are left bare

## Tested against

- [ ] Delphi 11.3 Alexandria (22.0)
- [ ] Delphi 12 Athens (23.0)
- [ ] Delphi 13 Florence (37.0)

Building one release is enough to open a pull request. Anything touching package
loading, the object inspector or the design-time layer is worth trying on a second,
because those are where the releases differ.
