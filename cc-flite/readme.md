# cc-flite

Text to speech inside Minecraft, running on a ComputerCraft computer.

There is no server call and no internet. The whole synthesiser runs on the
in-game computer. It is a [Rust speech engine compiled to WebAssembly](https://github.com/GabrielVicini/flite-rs), then
translated into plain Lua so CC:Tweaked can run it. You give it a string, it
gives you back DFPWM audio you can hand to a speaker.

Runs at roughly realtime. (On CraftPC testing)

## How it fits together

```
src/lib.rs  ->  wasm  ->  wasm2lua  ->  out.lua  ->  tts.lua
                                                       ^
                                         shim.lua + api.lua
```

1. `flite-rs` does the actual speech synthesis. `src/lib.rs` wraps it in a tiny
   C style interface: write text into a buffer, call `speak`, read samples out.
2. `cargo` builds that to `wasm32-unknown-unknown`.
3. `wasm2lua` translates the WebAssembly into pure Lua.
4. `build.sh` glues the translated module together with a compatibility shim and
   the Lua API, producing one file: `tts.lua`.

`tts.lua` is the only thing you copy onto a computer.

## Files that matter

| File | What it is |
| --- | --- |
| `src/lib.rs` | The Rust side. Exports `speak`, plus rate and pitch controls. |
| `Cargo.toml` | Build settings. Optimised for size, which keeps the Lua small. |
| `.cargo/config.toml` | Compiler flags. The disabled features matter, see below. |
| `shim.lua` | Bit operations. wasm2lua expects LuaJIT, CC has `bit32` instead. |
| `api.lua` | The public library. Chunking, yielding, audio conversion, failsafes. |
| `build.sh` | Runs the whole pipeline and writes `tts.lua`. |
| `run.lua` | Example player. Parses arguments, calls the library. |
| `tts.lua` | The build output. One self contained file, about 8 MB of Lua. |

Everything else in the folder is test scaffolding or intermediate output.

## Using it

```lua
local tts = dofile("tts.lua")

tts.play("Hello world.")
tts.play("Slower and deeper.", { rate = 1.3, pitch = 0.85 })

local audio = tts.synthesize("Saved for later.")   -- DFPWM string
tts.save("A longer piece of text.", "speech.dfpwm")
```

Or from the shell:

```
run "Hello world."
run --rate 1.2 --save out.dfpwm "Written to a file."
```

Long text is split up and the library yields between pieces, so it will not trip
the "too long without yielding" watchdog no matter how much you throw at it.

## Changes to wasm2lua

wasm2lua has not been updated in a while, and it was written against smaller,
simpler modules than a whole speech engine. A few things needed fixing before
this would run. All of these live in `node_modules`, so they get wiped by
`npm install` and have to be reapplied.

In `wasm2lua/js/index.js`:

- **Load and store offsets.** The bundled parser puts memory offsets somewhere
  the code generator was not looking, so every offset came out as zero.
- **Memory exports.** Exporting memory from a module was simply not implemented
  and threw on sight.
- **`memory.copy` and `memory.fill`.** These bulk memory instructions had no
  implementation, so the generated Lua just raised an error wherever they
  appeared. LLVM emits them for things like `memcpy`, so there were dozens.
- **A register reuse bug in 64 bit stores.** Under the right conditions the
  value being stored could overwrite the address it was meant to be stored at.
- **Uninitialised locals.** WebAssembly zeroes its locals, Lua does not. The
  existing workaround missed the case where a local is only assigned on a branch
  that gets skipped, which quietly wrote `nil` into memory.

In `@webassemblyjs/helper-wasm-bytecode`:

- **Bulk memory operand counts.** The parser knew `memory.copy` and
  `memory.fill` existed but did not know they carry operands, so it stopped
  reading too early and treated the leftover bytes as instructions. Those bytes
  happen to decode as `unreachable`, which made the module trap for no visible
  reason.

In `wasm2lua/resources/fileheader_lua.lua`:

- The memory library is rewritten. It drops the float tracking table, which cost
  a lookup on every single read and write for the sake of a handful of float
  operations, and it does the address arithmetic directly instead of going
  through function calls. This is the difference between "too slow to be fun"
  and "about realtime".

## A note on compiler flags

`.cargo/config.toml` turns off `nontrapping-fptoint` and `sign-ext`. The parser
bundled with wasm2lua predates both and refuses to read a module that uses them.
If you see a `CompileError` about an unexpected instruction, that is why.

## Credits

Speech synthesis by [flite-rs](https://github.com/GabrielVicini/flite-rs) (me), a
Rust implementation of the Flite and Festival diphone techniques. Translation to
Lua by [wasm2lua](https://github.com/SwadicalRag/wasm2lua).
