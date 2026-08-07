#!/usr/bin/env bash
# Build the deployable tts.lua:  shim + transpiled wasm module + API layer.
set -e
cd "$(dirname "$0")"

WASM=target/wasm32-unknown-unknown/release/cc_flite.wasm

echo "==> cargo build"
cargo build --target wasm32-unknown-unknown --release

echo "==> wasm2lua"
npx wasm2lua --pureLua --nolibc "$WASM" out.lua 2>&1 | grep -viE "deprecat|trace-dep" || true

TODO=$(grep -c "TODO memory" out.lua || true)
if [ "$TODO" != "0" ]; then echo "FAILED: $TODO unimplemented instructions in out.lua"; exit 1; fi

echo "==> packaging tts.lua"
# The generated chunk ends in `return module`, so it can't simply be concatenated
# with more code. Wrap it in a function call instead. It reads `...` at the top,
# hence the vararg signature.
{
  cat shim.lua
  echo ""
  echo "local __WASM__ = (function(...)"
  cat out.lua
  echo "end)()"
  echo ""
  cat api.lua
} > tts.lua

echo "built tts.lua: $(stat -c%s tts.lua) bytes, $(awk 'END{print NR}' tts.lua) lines"
