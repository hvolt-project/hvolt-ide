# hvolt-ide

An IDE that runs on the HarmonyOS device itself. It edits ArkTS, builds and installs the project
with [hvolt](https://github.com/hvolt-project/hvolt) through a native bridge, and carries a chat
loop that can call those same build tools.

No desktop IDE, no DevEco Studio, no host-side file sync: the phone is the workstation.

## What it does

- **Editor** — ArkTS sources with syntax highlighting, tabs, line numbers, word wrap and an
  embedded code editor. Language support (completion, diagnostics) comes from the hvolt LSP over
  the same bridge.
- **Build** — `build`, `sign`, `push` and `start` run inside the app. Output, signing state and
  device link are shown in the workbench.
- **Chat** — a streaming loop against any OpenAI-compatible endpoint, with tool calls into the
  build chain, file system and device shell. Replies render markdown: tables, token-coloured code,
  and mermaid diagrams.
- **Layout** — three breakpoints (compact / medium / expanded) and landscape. The toolbar,
  activity bar, panes and dock rearrange rather than scale.

## How it is put together

```
app/src/pages/model/      session state: project, editor, device link, build steps
app/src/pages/view/       the surfaces: panes, editor area, chat panel, settings, dock
app/src/pages/harness/    the chat loop: client, stream decoding, tools, MCP registry
app/src/pages/model/*.ts   pure logic with tests: markdown, stream, commands, format, completion, urls
test/                      node --test suites and the import-graph check
```

Device-side capability comes from `libhvolt.so`, a native library that exposes hvolt's build,
device and stream functions to ArkTS. ArkTS compilation on the device uses the SDK's own `es2abc`.

## Building

Requires `hvolt` (see its repository for install) and a HarmonyOS SDK.

Two kinds of files are **not** in this repository and have to be provided locally:

| Path | What it is | Where it comes from |
|---|---|---|
| `app/src/libs/arm64-v8a/libes2abc.so` | the device-side ArkTS compiler | the HarmonyOS SDK's `ets/build-tools`, cross-built for arm64 |
| `app/resources/rawfile/sdk/` | API declarations the editor offers completions from | `$SDK/<version>/ets/api`, plus `index.tsv` |

Both are SDK distribution and would put a 61 MB binary and several hundred `.d.ts` files into the
history, so they are ignored. Without them the app builds and runs, but the on-device compiler and
completion are unavailable.

Signing material (`app/signing/`) is likewise ignored: it holds the keystore. With it absent,
`hvolt build` produces an unsigned package. The passwords in `app/hvolt.toml` are inert without the
keystore they belong to.

```bash
cd app
hvolt build            # → build/entry-unsigned.hap
hvolt push <device>
hvolt start xyz.sudofree.hvolt.ide
```

## Tests

```bash
node --test test/            # 96 cases: markdown, stream decoding, commands, format, completion, urls
python3 test/check-imports.py
```

`check-imports.py` exists because the build chain does not verify that a named import is exported by
its source module; a symbol moved between files compiles cleanly and crashes the app at startup.
hvolt runs the same check before compiling.

## Limitations

**Native modules are not built on the device.** The build chain covers ArkTS only. A project that
declares a C++/NAPI module — a `type = "native"` dependency, or `cpp/CMakeLists.txt` under a member
— expects a host-side toolchain (clang, cmake, the NDK) that the device does not carry, and the
build reports the failure rather than cross-compiling it. Projects that need native code still have
to be built on a host and installed from there.

**No automated UI tests.** The `.ts` modules under `test/` cover parsing and formatting; the
surfaces themselves are verified by running them on a device.
