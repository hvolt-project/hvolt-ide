# Tests

Pure logic lives in `.ts` modules so it runs on Node's type stripping without a device or an
emulator:

```bash
node --test test/
```

| File | Covers |
|---|---|
| `session.test.ts` | `app/src/pages/harness/session/` — event seq, surface replace, transcript filtering, compaction range, JSONL round trip and all-or-nothing load |
| `recall.test.ts` | `app/src/pages/harness/loop/Recall.ts` — seq spans and body search over an event log in the current `data.message` shape |
| `markdown.test.ts` | `app/src/pages/model/Markdown.ts` — blocks, tables, inline markers, code tokenising |
| `stream.test.ts` | `app/src/pages/harness/loop/Stream.ts` — SSE framing, deltas, tool-call accumulation |
| `format.test.ts` | `app/src/pages/model/Format.ts` — failure line selection, turn summary, rolling log |
| `commands.test.ts` | `app/src/pages/model/Commands.ts` — argv shapes and the hvolt.toml bundle field |
| `complete.test.ts` | `app/src/pages/model/Complete.ts` — `/` and `@` completion rules |
| `lines.test.ts` | `app/src/pages/model/Lines.ts` — collapsed title per kind, expanded body, identity key, foldable predicate |
| `items.test.ts` | `app/src/pages/model/Items.ts` — line array to visible items: grouping, manual open, fold timing, header wording, error visibility |
| `urls.test.ts` | `app/src/pages/harness/loop/Urls.ts` — route derivation and provider label |

Two constraints shape these files:

- **Keep them out of `app/`.** `hvolt build` scans every `.ts` under the project, so a test that
  imports `node:test` fails the build. This directory sits beside `app/`, not inside it.
- **Import types with `import type`.** An `interface` is erased at run time, so a value import of
  one throws `does not provide an export named`. TypeScript syntax in a plain-value test file must
  use `import type` and explicit `.ts` extensions, because Node resolves ESM without guessing.

Anything that touches ArkUI stays on the device; this directory is for the parts where a
regression should be caught before a build.

## Import graph

```bash
python3 test/check-imports.py
```

The device build does not verify that a named import exists in its source module. Moving a symbol
between files therefore compiles cleanly and fails on the device with
`the requested module ... does not provide an export name <name>` — which is exactly how a session
crashed after `chatUrl` moved from `Models` to `Urls`. This walks the whole graph and reports any
import that does not resolve to a declared export.
