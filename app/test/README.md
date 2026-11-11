# Tests

Pure logic lives in `.ts` modules under `src/pages/model/` so it can run on Node's type stripping
without a device or an emulator.

```bash
node --test test/
```

Covered here: the markdown parser (blocks, tables, inline markers, code tokenising). Anything that
touches ArkUI stays on the device; this directory is for the parts where a regression should be
caught before a build.
