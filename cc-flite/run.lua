--[[--------------------------------------------------------------------
  Example player for tts.lua. Everything interesting lives in the library;
  this just parses arguments and hands text to it.

    run "Hello there."
    run --rate 1.3 --pitch 0.85 "Slower and deeper."
    run --save speech.dfpwm "Written to a file instead of played."
    run --file story.txt
----------------------------------------------------------------------]]

local args = { ... }

local function usage()
  print("Usage: run [options] \"text\"")
  print("       run [options] --file <path>")
  print()
  print("  --rate <n>      1.0 natural, >1 slower      (0.05 - 20)")
  print("  --pitch <n>     1.0 natural, >1 higher      (0.1 - 10)")
  print("  --f0mean <hz>   absolute pitch in Hz        (10 - 1000)")
  print("  --f0stddev <hz> pitch spread; 0 = monotone  (0 - 500)")
  print("  --gain <n>      output level                (0.01 - 16)")
  print("  --save <path>   write DFPWM to a file instead of playing")
  print("  --file <path>   read the text from a file")
  print("  --dither        dither the 8-bit output")
  print("  --prebuffer <n> lead-in seconds before audio starts, or 'all'")
end

local opts, save, file, words = {}, nil, nil, {}
local i = 1
while i <= #args do
  local a = args[i]
  if a == "--rate" or a == "--pitch" or a == "--gain" then
    i = i + 1
    local v = tonumber(args[i])
    if not v then usage() error("--" .. a:sub(3) .. " needs a number", 0) end
    opts[a:sub(3)] = v
  elseif a == "--f0mean" or a == "--f0stddev" then
    i = i + 1
    local v = tonumber(args[i])
    if not v then usage() error(a .. " needs a number", 0) end
    opts[a:sub(3)] = v
  elseif a == "--save" then
    i = i + 1; save = args[i]
  elseif a == "--file" then
    i = i + 1; file = args[i]
  elseif a == "--prebuffer" then
    i = i + 1
    opts.prebuffer = tonumber(args[i]) or args[i]
  elseif a == "--dither" then
    opts.dither = true
  elseif a == "--help" or a == "-h" then
    usage(); return
  else
    words[#words + 1] = a
  end
  i = i + 1
end

local text
if file then
  if not fs.exists(file) then error("no such file: " .. file, 0) end
  local h = fs.open(file, "r")
  text = h.readAll()
  h.close()
else
  text = table.concat(words, " ")
end

if not text or #text == 0 then usage() return end

local t0 = os.epoch("utc")
local tts = dofile("tts.lua")
print(("loaded in %dms"):format(os.epoch("utc") - t0))

local ok, err, info
if save then
  t0 = os.epoch("utc")
  ok, info = tts.save(text, save, opts)
  if not ok then error("tts: " .. tostring(info), 0) end
  print(("saved %s: %d bytes, %.2fs of audio, %dms"):format(
    save, info.bytes, info.seconds, os.epoch("utc") - t0))
else
  t0 = os.epoch("utc")
  ok, info = tts.play(text, opts)
  if not ok then error("tts: " .. tostring(info), 0) end
  local elapsed = os.epoch("utc") - t0
  print(("spoke %.2fs of audio in %d chunks (%dms, %.2fx realtime)"):format(
    info.seconds, info.chunks, elapsed, info.seconds * 1000 / elapsed))
end
