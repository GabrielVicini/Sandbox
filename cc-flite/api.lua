--[[----------------------------------------------------------------------
  tts.lua -- offline text-to-speech for CC:Tweaked.
  Written by Gabriel Vicini 2026
  Apache-2.0 license

  Flite-RS diphone synthesis (Rust -> wasm -> Lua). Produces DFPWM or raw PCM;
  playback is the caller's business, apart from the convenience helpers.

    local tts = dofile("tts.lua")

    local audio, info = tts.synthesize("Hello world.")   -- DFPWM string
    tts.play("Hello world.", { rate = 1.2, pitch = 0.9 })
    tts.save("A long document...", "speech.dfpwm")
    for chunk, info in tts.stream(longText) do ... end

  Long input is split into chunks and the coroutine yields between them, so
  the computer never trips CC's "too long without yielding" watchdog no matter
  how much text is passed. Chunk size adapts to measured throughput, so it
  self-tunes to a slow server as well as a fast emulator.

  API
    tts.synthesize(text [,opts])  -> audio, info      | nil, err
    tts.stream(text [,opts])      -> iterator of (audio, info)
    tts.play(text [,opts])        -> true, info       | nil, err
    tts.save(text, path [,opts])  -> true, info       | nil, err
    tts.configure(opts)           -- change the defaults
    tts.getConfig() / tts.getParams() / tts.info() / tts.reset() / tts.yield()

  Options
    rate         1.0      speech rate; >1 is slower, <1 faster
    pitch        1.0      pitch multiplier on the voice's mean
    f0mean       nil      absolute mean pitch in Hz (overrides `pitch`)
    f0stddev     nil      pitch spread in Hz; 0 gives a monotone
    gain         1.0      output level; >1 risks clipping
    format       "dfpwm"  "dfpwm" | "pcm"
    budgetMs     2500     target compute per chunk; lower = yields more often
    maxInput     10000    reject inputs longer than this
    interpolate  true     linear resample; false is cheaper and harsher
    dither       false    TPDF dither on the 8-bit quantiser
    onChunkError "abort"  "abort" | "skip"
    speaker      nil      peripheral for play()
    trimSilence  true     strip the silence flite pads each chunk with, so a
                          split sentence does not gain a pause at the join
    prebuffer    "auto"   play(): lead-in before audio starts.
                          "auto" sizes it from measured speed, "all" renders
                          everything first, or give a number of seconds.
------------------------------------------------------------------------]]

local exports = __WASM__.exports
local memory  = __WASM__.memory

local TTS = { _VERSION = "1.0.0" }

-- The raw transpiled module. Not part of the API; exposed for benchmarks and
-- for diagnosing the wasm layer directly.
TTS._wasm = __WASM__

-- ------------------------------------------------------------- diagnostics

local ERRORS = {
  [-1] = "engine not initialised",
  [-2] = "text length out of range",
  [-3] = "text is not valid UTF-8",
}

-- --------------------------------------------------------------- defaults

local defaults = {
  rate      = 1.0,    -- 1.0 natural, >1 slower
  pitch     = 1.0,    -- multiplier on the voice's mean pitch
  f0mean    = nil,    -- absolute Hz; overrides `pitch` when set
  f0stddev  = nil,    -- absolute Hz; 0 = monotone
  gain      = 1.0,    -- output level multiplier; >1 can clip
  format    = "dfpwm",-- "dfpwm" | "pcm"
  budgetMs  = 2500,   -- target compute time per chunk (watchdog headroom)
  maxInput  = 10000,  -- refuse inputs longer than this many characters
  interpolate = true, -- linear resample; off = sample-and-hold (cheaper, harsher)
  dither    = false,  -- TPDF dither on the 8-bit quantiser
  onChunkError = "abort", -- "abort" | "skip"
  speaker   = nil,    -- peripheral for play()
  prebuffer = "auto", -- play(): "auto" | "all" | seconds of lead-in
  trimSilence = true, -- strip flite's per-utterance padding at chunk joins
}

-- Options whose default is nil are absent from `defaults`, so a membership test
-- against that table alone would reject them. Keep the key set separately.
local VALID = {
  rate = true, pitch = true, f0mean = true, f0stddev = true, gain = true,
  format = true, budgetMs = true, maxInput = true, interpolate = true,
  dither = true, onChunkError = true, speaker = true, prebuffer = true,
  trimSilence = true,
}

local config = {}
for k, v in pairs(defaults) do config[k] = v end

local function validate(o, level)
  local function num(key, min, max)
    local v = o[key]
    if v == nil then return end
    if type(v) ~= "number" or v ~= v then
      error(("option %s must be a number, got %s"):format(key, type(v)), level)
    end
    if v < min or v > max then
      error(("option %s out of range [%g,%g]: %s"):format(key, min, max, tostring(v)), level)
    end
  end
  num("rate", 0.05, 20)
  num("pitch", 0.1, 10)
  num("f0mean", 10, 1000)
  num("f0stddev", 0, 500)
  num("gain", 0.01, 16)
  num("budgetMs", 200, 60000)
  num("maxInput", 1, 10000000)
  if o.format ~= "dfpwm" and o.format ~= "pcm" then
    error("option format must be 'dfpwm' or 'pcm'", level)
  end
  if o.onChunkError ~= "abort" and o.onChunkError ~= "skip" then
    error("option onChunkError must be 'abort' or 'skip'", level)
  end
  local pb = o.prebuffer
  if pb ~= "auto" and pb ~= "all" then
    if type(pb) ~= "number" or pb < 0 or pb > 3600 then
      error("option prebuffer must be 'auto', 'all', or seconds", level)
    end
  end
end

--- Change the defaults used when a call does not specify options.
function TTS.configure(opts)
  if type(opts) ~= "table" then error("configure expects a table", 2) end
  for k in pairs(opts) do
    if not VALID[k] then error("unknown option: " .. tostring(k), 2) end
  end
  local merged = {}
  for k, v in pairs(config) do merged[k] = v end
  for k, v in pairs(opts) do merged[k] = v end
  validate(merged, 3)
  config = merged
  return TTS.getConfig()
end

--- A copy of the current defaults.
function TTS.getConfig()
  local o = {}
  for k, v in pairs(config) do o[k] = v end
  return o
end

local function resolve(opts, level)
  if opts == nil then return config end
  if type(opts) ~= "table" then error("options must be a table", level) end
  for k in pairs(opts) do
    if not VALID[k] then error("unknown option: " .. tostring(k), level) end
  end
  local o = {}
  for k, v in pairs(config) do o[k] = v end
  for k, v in pairs(opts) do o[k] = v end
  validate(o, level + 1)
  return o
end

-- ----------------------------------------------------------- rom modules

-- `require` is set up by the shell, so it is absent when a program is launched
-- any other way (a startup script, --script, a coroutine off a raw bios). The
-- ROM modules are still on disk, so fall back to loading them directly. They
-- require each other, hence the small recursive loader rather than a dofile.
local romCache = {}

local function loadChunk(src, name, env)
  local fn, err = load(src, name, "t", env)          -- 5.2+ signature
  if fn then return fn end
  if loadstring then                                  -- 5.1 fallback
    fn, err = loadstring(src, name)
    if fn and setfenv then setfenv(fn, env) end
  end
  return fn, err
end

local function romRequire(name)
  local hit = romCache[name]
  if hit ~= nil then return hit end
  local path = "/rom/modules/main/" .. name:gsub("%.", "/") .. ".lua"
  if not fs.exists(path) then error("module not found: " .. name, 0) end
  local h = fs.open(path, "r")
  local src = h.readAll()
  h.close()
  local env = setmetatable({ require = romRequire }, { __index = _G })
  local fn, err = loadChunk(src, "@" .. path, env)
  if not fn then error("cannot load " .. name .. ": " .. tostring(err), 0) end
  local mod = fn()
  romCache[name] = mod
  return mod
end

local function loadModule(name)
  if type(_G.require) == "function" then
    local ok, mod = pcall(_G.require, name)
    if ok and type(mod) == "table" then return mod end
  end
  local ok, mod = pcall(romRequire, name)
  if ok and type(mod) == "table" then return mod end
  return nil, tostring(mod)
end

-- ------------------------------------------------------------------ yield

--- Yield so CC can service the tick, without swallowing the caller's events.
-- os.pullEvent(filter) discards everything that doesn't match, which would eat
-- key presses and modem messages belonging to the host program. Pull raw and
-- put anything that isn't ours back.
local function breathe()
  os.queueEvent("tts_tick")
  local held = nil
  while true do
    local e = table.pack(os.pullEventRaw())
    if e[1] == "tts_tick" then break end
    held = held or {}
    held[#held + 1] = e
  end
  if held then
    for i = 1, #held do
      local e = held[i]
      os.queueEvent(table.unpack(e, 1, e.n))
    end
  end
end

TTS.yield = breathe

-- ------------------------------------------------------------------- init

local started = false
local applied = {}
local baseline = nil
local TEXT_CAP, PCM_CAP

local function readEngineFacts()
  TEXT_CAP = exports.text_cap()
  PCM_CAP  = exports.pcm_cap()
  -- The voice's own pitch settings. Omitting f0mean/f0stddev on a later call
  -- restores these rather than silently keeping whatever was last set.
  baseline = {
    f0mean   = exports.get_f0_mean(),
    f0stddev = exports.get_f0_stddev(),
  }
end

local function ensureStarted()
  if started then return end
  exports.init()
  started = true
  applied = {}
  readEngineFacts()
end

local function applyParams(o)
  local function set(fn, key, value, scale)
    if value == nil then return end
    if applied[key] == value then return end
    local rc = exports[fn](math.floor(value * scale + 0.5))
    if rc ~= 0 then error("tts: " .. (ERRORS[rc] or ("error " .. rc)), 0) end
    applied[key] = value
  end
  set("set_rate",      "rate",     o.rate,     1000)
  set("set_pitch",     "pitch",    o.pitch,    1000)
  set("set_f0_mean",   "f0mean",   o.f0mean   or baseline.f0mean,   1)
  set("set_f0_stddev", "f0stddev", o.f0stddev or baseline.f0stddev, 1)
end

--- Rebuild the engine from scratch. Also drops any parameters set so far.
function TTS.reset()
  exports.reset()
  started = true
  applied = {}
  readEngineFacts()
end

--- Static facts about the engine.
function TTS.info()
  ensureStarted()
  return {
    version    = TTS._VERSION,
    sampleRate = exports.sample_rate(),
    textCap    = TEXT_CAP,
    pcmCap     = PCM_CAP,
    maxChunkSeconds = PCM_CAP / exports.sample_rate(),
  }
end

--- Parameters currently in effect, in the units the options use.
function TTS.getParams()
  ensureStarted()
  return {
    rate     = exports.get_rate() / 1000,
    pitch    = exports.get_pitch() / 1000,
    f0mean   = exports.get_f0_mean(),
    f0stddev = exports.get_f0_stddev(),
  }
end

-- ------------------------------------------------------------- text hygiene

-- Flite is an ASCII engine. Anything outside printable ASCII is replaced with
-- a space rather than dropped, so words either side don't run together.
local function sanitize(text)
  local out = text:gsub("[^\32-\126]", " ")
  out = out:gsub("%s+", " ")
  return (out:gsub("^ ", ""):gsub(" $", ""))
end

-- Pack words into chunks no longer than `limit`, preferring to break just after
-- sentence-ending punctuation. Never splits inside a word; a single word longer
-- than the limit is emitted oversized rather than mangled.
local function splitInto(text, limit)
  local pieces, buf = {}, ""
  local function flush()
    if #buf > 0 then pieces[#pieces + 1] = buf; buf = "" end
  end
  for word in text:gmatch("%S+") do
    -- A "word" longer than a whole chunk is not really a word (a URL, a hash, a
    -- wall of punctuation). Cut it up rather than handing the module something
    -- larger than its text buffer, which it would reject outright.
    while #word > limit do
      flush()
      pieces[#pieces + 1] = word:sub(1, limit)
      word = word:sub(limit + 1)
    end
    if #buf == 0 then
      buf = word
    elseif #buf + 1 + #word <= limit then
      buf = buf .. " " .. word
    else
      flush()
      buf = word
    end
    -- prefer to break right after sentence-ending punctuation
    if #buf >= limit * 0.6 and buf:match("[%.%?%!]$") then flush() end
  end
  flush()
  return pieces
end

-- ------------------------------------------------------------- synthesis

-- Rolling estimate of synthesis cost, used to size the next chunk. The prior is
-- deliberately pessimistic so the very first chunk is small on an unknown host.
local msPerChar = 150
local MIN_CHUNK, MAX_CHUNK = 8, 400

local function chunkLimit(o)
  local limit = math.floor(o.budgetMs / msPerChar)
  if limit < MIN_CHUNK then limit = MIN_CHUNK end
  if limit > MAX_CHUNK then limit = MAX_CHUNK end
  if TEXT_CAP and limit > TEXT_CAP then limit = TEXT_CAP end
  return limit
end

-- Copy the chunk into the module's text buffer and synthesise it.
local function speakRaw(text)
  local ptr = exports.text_ptr()
  local write8 = memory.write8
  for i = 1, #text do
    write8(memory, ptr + i - 1, text:byte(i))
  end
  return exports.speak(#text)
end

-- Run one chunk with recovery: on a hard fault (a trap inside the module) the
-- engine is rebuilt and the chunk retried once before giving up.
local function synthChunk(text, o)
  local t0 = os.epoch("utc")
  local ok, n = pcall(speakRaw, text)
  if not ok then
    local rebuilt = pcall(TTS.reset)
    if rebuilt then pcall(applyParams, o) end
    ok, n = pcall(speakRaw, text)
    if not ok then
      return nil, "synthesis failed: " .. tostring(n)
    end
  end
  if type(n) ~= "number" then return nil, "synthesis returned " .. type(n) end
  if n < 0 then return nil, ERRORS[n] or ("error " .. tostring(n)) end

  local elapsed = os.epoch("utc") - t0
  if #text > 0 and elapsed > 0 then
    -- exponential moving average, so one slow chunk doesn't dominate
    msPerChar = msPerChar * 0.7 + (elapsed / #text) * 0.3
  end
  return n
end

-- --------------------------------------------------------------- resampling

-- Flite pads every utterance with silence -- measured at ~220ms before and
-- ~125ms after. Inside one utterance that is natural; at a chunk join it is
-- 345ms of dead air in the middle of a sentence, and it compounds with every
-- extra chunk. Find the audible span so the padding can be replaced with a gap
-- we choose.
-- Output is 8-bit, so anything under ~1.5 LSB of it (384 of 32768) quantises to
-- silence regardless; trimming it costs nothing audible.
local SILENCE = 384
local KEEP = 120    -- samples of margin kept either side (15ms at 8 kHz)

local function audibleRange(n)
  local pp = exports.pcm_ptr()
  local read16 = memory.read16
  local first, last

  for i = 0, n - 1 do
    local v = read16(memory, pp + i * 2)
    if v >= 32768 then v = v - 65536 end
    if v < 0 then v = -v end
    if v > SILENCE then first = i; break end
    if i > 0 and (i % 8192) == 0 then breathe() end
  end
  if not first then return nil end

  for i = n - 1, 0, -1 do
    local v = read16(memory, pp + i * 2)
    if v >= 32768 then v = v - 65536 end
    if v < 0 then v = -v end
    if v > SILENCE then last = i; break end
  end

  first = first - KEEP; if first < 0 then first = 0 end
  last = last + KEEP; if last > n - 1 then last = n - 1 end
  return first, last
end

-- How much silence to put after a chunk, standing in for what was trimmed.
local function gapAfter(piece)
  if piece:match("[%.%?%!][\"')]*$") then return 0.20 end
  if piece:match("[,;:][\"')]*$") then return 0.12 end
  return 0.05
end

-- 16-bit @ 8 kHz in the module -> 8-bit @ 48 kHz for CC's speaker.
local function renderPCM(from, to, o, carry, out)
  local rate  = exports.sample_rate()
  local ratio = math.floor(48000 / rate)
  if ratio < 1 then ratio = 1 end

  local pp     = exports.pcm_ptr()
  local read16 = memory.read16
  local floor, random = math.floor, math.random
  local gain   = o.gain / 256
  local interp = o.interpolate
  local dither = o.dither

  local k = #out
  local prev = carry
  for i = from, to do
    local v = read16(memory, pp + i * 2)
    if v >= 32768 then v = v - 65536 end
    if prev == nil then prev = v end

    if interp then
      -- interpolate from the previous sample up to this one; carrying `prev`
      -- across chunks keeps the joins click-free
      local step = (v - prev) / ratio
      for j = 0, ratio - 1 do
        local s = (prev + step * j) * gain
        if dither then s = s + (random() + random() - 1) * 0.5 end
        s = floor(s + 0.5)
        if s < -128 then s = -128 elseif s > 127 then s = 127 end
        k = k + 1; out[k] = s
      end
    else
      local s = v * gain
      if dither then s = s + (random() + random() - 1) * 0.5 end
      s = floor(s + 0.5)
      if s < -128 then s = -128 elseif s > 127 then s = 127 end
      for _ = 1, ratio do k = k + 1; out[k] = s end
    end

    prev = v
    if i > 0 and (i % 8192) == 0 then breathe() end
  end
  return prev
end

-- ----------------------------------------------------------------- public

--- Iterate a long input as a sequence of audio chunks.
-- Returns an iterator yielding (audio, info) where `audio` is a DFPWM string
-- (or a PCM sample table when format=="pcm"). Yields to the scheduler between
-- chunks, so arbitrarily long text is safe and memory stays flat.
function TTS.stream(text, opts)
  if type(text) ~= "string" then error("text must be a string", 2) end
  local o = resolve(opts, 2)
  ensureStarted()

  if #text > o.maxInput then
    error(("text too long: %d characters, limit %d"):format(#text, o.maxInput), 2)
  end
  applyParams(o)

  local encoder = nil
  if o.format == "dfpwm" then
    local dfpwm, why = loadModule("cc.audio.dfpwm")
    if not dfpwm then
      error("cc.audio.dfpwm unavailable (" .. tostring(why) .. "); use format='pcm'", 2)
    end
    -- One encoder for the whole utterance: DFPWM is differential, so a fresh
    -- encoder per chunk would click at every join.
    encoder = dfpwm.make_encoder()
  end

  local clean = sanitize(text)
  local queue = (#clean > 0) and splitInto(clean, chunkLimit(o)) or {}
  local index, carry = 1, nil

  return function()
    while index <= #queue do
      local piece = queue[index]
      index = index + 1

      local n, err = synthChunk(piece, o)

      if not n then
        if o.onChunkError ~= "skip" then error("tts: " .. err, 0) end
        breathe()

      elseif exports.truncated() == 1 and #piece > MIN_CHUNK then
        -- The chunk overran the module's PCM buffer. Split it and put the
        -- halves back on the queue rather than emitting audio with a hole in it.
        local half = math.floor(#piece / 2)
        local cut = piece:sub(1, half):match("^.*%s()") or (half + 1)
        table.insert(queue, index, piece:sub(cut))
        table.insert(queue, index, piece:sub(1, cut - 1))
        breathe()

      elseif n > 0 then
        local pcm = {}
        local from, to = 0, n - 1
        if o.trimSilence then
          local a, b = audibleRange(n)
          if a then from, to = a, b else from, to = 0, -1 end
        end
        carry = renderPCM(from, to, o, carry, pcm)

        -- Replace the trimmed padding with a gap sized for the punctuation,
        -- unless this is the final chunk (nothing follows it to run into).
        local remaining = #queue - index + 1
        if o.trimSilence and remaining > 0 and #pcm > 0 then
          local silence = math.floor(gapAfter(piece) * 48000)
          local base = #pcm
          for j = 1, silence do pcm[base + j] = 0 end
          carry = 0 -- next chunk interpolates up from silence, so no click
        end

        breathe()
        local info = {
          text = piece,
          samples = #pcm,
          seconds = #pcm / 48000,
          remaining = remaining,
        }
        if encoder then return encoder(pcm), info end
        return pcm, info
      end
    end
    return nil
  end
end

--- Synthesise the whole input and return it as one blob.
-- Returns (audio, info) or (nil, err). For long text prefer TTS.stream or
-- TTS.save, which don't hold the entire result in memory.
function TTS.synthesize(text, opts)
  -- Misuse (wrong types, bad options) raises so the traceback points at the
  -- caller; runtime trouble (a synthesis fault) comes back as nil, err.
  if type(text) ~= "string" then error("text must be a string", 2) end
  local o = resolve(opts, 2)
  if #text > o.maxInput then
    error(("text too long: %d characters, limit %d"):format(#text, o.maxInput), 2)
  end
  local ok, iter = pcall(TTS.stream, text, o)
  if not ok then return nil, tostring(iter) end

  local parts, seconds, chunks = {}, 0, 0
  while true do
    local got, audio, info = pcall(iter)
    if not got then return nil, tostring(audio) end
    if audio == nil then break end
    chunks = chunks + 1
    seconds = seconds + info.seconds
    if o.format == "pcm" then
      local base = #parts
      for i = 1, #audio do parts[base + i] = audio[i] end
    else
      parts[#parts + 1] = audio
    end
  end

  local out = (o.format == "pcm") and parts or table.concat(parts)
  return out, { seconds = seconds, chunks = chunks, format = o.format }
end

--- Play text through a speaker.
--
-- Naively streaming (synthesise a chunk, play it, synthesise the next) only
-- works when synthesis outruns playback. On a loaded server it doesn't, and the
-- speaker drains dry between chunks -- audible gaps mid-sentence.
--
-- So audio is buffered ahead before playback starts. If the whole clip lasts D
-- seconds and synthesis runs at r times realtime, playback consumes 1 second of
-- audio per second while synthesis supplies r, so the lead must cover the
-- shortfall over the entire clip: L >= D * (1 - r). With that lead the buffer
-- cannot run dry; without it, a clip long enough will always cut out.
--
-- The buffer holds DFPWM, not PCM -- eight times smaller, which matters for a
-- long clip on a real computer -- and is decoded just before it is fed out.
function TTS.play(text, opts)
  if type(text) ~= "string" then error("text must be a string", 2) end
  local o = resolve(opts, 2)
  if #text > o.maxInput then
    error(("text too long: %d characters, limit %d"):format(#text, o.maxInput), 2)
  end

  local speaker = o.speaker or peripheral.find("speaker")
  if not speaker then return nil, "no speaker attached" end

  -- A speaker holds only a second or two, so while we are feeding one we work
  -- in smaller pieces than the watchdog alone would need and come back often.
  -- With prebuffer="all" nothing is playing while we synthesise, so keep the
  -- chunks big: every extra chunk is another join, and joins cost prosody.
  if o.prebuffer ~= "all" and o.budgetMs > 1000 then o.budgetMs = 1000 end

  -- Buffer compressed when we can; fall back to raw PCM if DFPWM is missing.
  local decoder
  local dfpwm = loadModule("cc.audio.dfpwm")
  if dfpwm then
    o.format = "dfpwm"
    decoder = dfpwm.make_decoder()
  else
    o.format = "pcm"
  end

  local ok, iter = pcall(TTS.stream, text, o)
  if not ok then return nil, tostring(iter) end

  local queue, buffered = {}, 0
  local produced, chunks, rate, estTotal = 0, 0, nil, nil
  local finished, failure = false, nil

  -- Pull one chunk, timing it so we learn how fast this host actually is.
  local function pull()
    if finished then return false end
    local t0 = os.epoch("utc")
    local got, audio, info = pcall(iter)
    if not got then failure = tostring(audio); finished = true; return false end
    if audio == nil then finished = true; return false end

    local dt = (os.epoch("utc") - t0) / 1000
    if dt > 0 then
      local instant = info.seconds / dt
      rate = rate and (rate * 0.6 + instant * 0.4) or instant
    end
    chunks = chunks + 1
    produced = produced + info.seconds
    queue[#queue + 1] = { data = audio, seconds = info.seconds }
    buffered = buffered + info.seconds
    -- Extrapolate the full duration from what's been produced so far.
    if info.remaining and info.remaining > 0 then
      estTotal = produced * (chunks + info.remaining) / chunks
    else
      estTotal = produced
    end
    return true
  end

  local function leadNeeded()
    if o.prebuffer == "all" then return math.huge end
    if type(o.prebuffer) == "number" then return o.prebuffer end
    if not rate or not estTotal then return 1.0 end
    if rate >= 1 then return math.max(1.0, estTotal * 0.05) end
    -- The 1.4x margin and the one-second floor cover error in the duration
    -- estimate, the cost of decoding as we go, and the fact that `rate` drifts.
    return math.min(estTotal, estTotal * (1 - rate) * 1.4 + 1.0)
  end

  -- Phase 1: build the lead-in.
  while not finished and buffered < leadNeeded() do
    if not pull() then break end
  end
  if failure then return nil, failure end

  -- Phase 2: play, topping the buffer up whenever the speaker is busy.
  local MAX_FEED = 65536 -- playAudio accepts at most 128k samples
  local pending, pendingAt = nil, 1
  local stalls = 0

  while true do
    if not pending then
      local item = table.remove(queue, 1)
      if item then
        buffered = buffered - item.seconds
        pending = decoder and decoder(item.data) or item.data
        pendingAt = 1
      elseif finished then
        break
      else
        -- Buffer empty with audio still to come: the lead-in was too short.
        stalls = stalls + 1
        pull()
      end
    end

    if pending then
      local last = math.min(pendingAt + MAX_FEED - 1, #pending)
      local slice
      if pendingAt == 1 and last == #pending then
        slice = pending
      else
        slice = {}
        for j = pendingAt, last do slice[#slice + 1] = pending[j] end
      end

      if speaker.playAudio(slice) then
        -- Accepted: go straight back for more. Do NOT synthesise here -- the
        -- speaker holds only a second or two, and a synthesis pass takes about
        -- as long, so working now would let it run dry.
        pendingAt = last + 1
        if pendingAt > #pending then pending = nil end
      elseif not finished then
        -- Speaker full. This is the only genuinely idle time we have, so it is
        -- where the next chunk gets made.
        pull()
      else
        os.pullEvent("speaker_audio_empty")
      end
    end
  end

  if failure then return nil, failure end
  return true, {
    seconds = produced,
    chunks = chunks,
    rate = rate,
    lead = leadNeeded(),
    stalls = stalls,
  }
end

--- Write text to a .dfpwm file, streaming so memory stays flat.
function TTS.save(text, path, opts)
  if type(text) ~= "string" then error("text must be a string", 2) end
  if type(path) ~= "string" then error("path must be a string", 2) end
  local o = resolve(opts, 2)
  if #text > o.maxInput then
    error(("text too long: %d characters, limit %d"):format(#text, o.maxInput), 2)
  end
  o.format = "dfpwm"

  local ok, iter = pcall(TTS.stream, text, o)
  if not ok then return nil, tostring(iter) end

  local handle, ferr = fs.open(path, "wb")
  if not handle then return nil, ferr or ("cannot open " .. path) end

  local bytes, seconds = 0, 0
  while true do
    local got, chunk, info = pcall(iter)
    if not got then handle.close(); return nil, tostring(chunk) end
    if chunk == nil then break end
    handle.write(chunk)
    bytes = bytes + #chunk
    seconds = seconds + info.seconds
  end
  handle.close()
  return true, { bytes = bytes, seconds = seconds }
end

return TTS
