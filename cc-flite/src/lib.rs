use core::alloc::{GlobalAlloc, Layout};
use flite_rs::Engine;

// ---------------------------------------------------------------- allocator

// Bump allocator — never frees individual allocations. speak() rewinds to the
// high-water mark left by init(), so per-utterance garbage is reclaimed while
// the Engine's own allocations stay live.
struct Bump;

const ARENA: usize = 4 * 1024 * 1024;

// A plain [u8; N] static has align 1, so aligning an arena-relative offset says
// nothing about the alignment of the pointer actually handed out. Give the arena
// a real alignment and align absolute addresses against it.
#[repr(C, align(16))]
struct Arena([u8; ARENA]);

static mut HEAP: Arena = Arena([0; ARENA]);
static mut OFFSET: usize = 0;
static mut INIT_MARK: usize = 0;

unsafe impl GlobalAlloc for Bump {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let base = core::ptr::addr_of_mut!(HEAP).cast::<u8>();
        let align = l.align();
        let aligned = ((base as usize + OFFSET) + align - 1) & !(align - 1);
        let start = aligned - base as usize;
        let end = start + l.size();
        if end > ARENA {
            return core::ptr::null_mut();
        }
        OFFSET = end;
        base.add(start)
    }
    unsafe fn dealloc(&self, _: *mut u8, _: Layout) {}
}

#[global_allocator]
static A: Bump = Bump;

// ------------------------------------------------------------------ buffers

const TEXT_CAP: usize = 1024;
const PCM_CAP: usize = 48000; // 6 s at 8 kHz

static mut TEXT: [u8; TEXT_CAP] = [0; TEXT_CAP];
static mut PCM: [i16; PCM_CAP] = [0; PCM_CAP];
static mut RATE: u32 = 0;
static mut TRUNCATED: i32 = 0;
static mut ENGINE: Option<Engine> = None;
// set_duration_stretch rescales by the voice's own natural stretch, so reading
// params().duration_stretch back gives upstream's units, not the caller's.
// Remember what was asked for so set_rate/get_rate round-trip.
static mut RATE_MILLI: i32 = 1000;

// speak() status codes (negative = failure, >=0 = sample count)
const ERR_NO_ENGINE: i32 = -1;
const ERR_BAD_LEN: i32 = -2;
const ERR_BAD_UTF8: i32 = -3;

unsafe fn engine_ref() -> Option<&'static Engine> {
    (*core::ptr::addr_of!(ENGINE)).as_ref()
}

unsafe fn engine_mut() -> Option<&'static mut Engine> {
    (*core::ptr::addr_of_mut!(ENGINE)).as_mut()
}

// ------------------------------------------------------------------ exports

#[unsafe(no_mangle)]
pub extern "C" fn text_ptr() -> *mut u8 {
    core::ptr::addr_of_mut!(TEXT).cast()
}

#[unsafe(no_mangle)]
pub extern "C" fn pcm_ptr() -> *const i16 {
    core::ptr::addr_of!(PCM).cast()
}

/// Capacity of the text input buffer, in bytes.
#[unsafe(no_mangle)]
pub extern "C" fn text_cap() -> i32 {
    TEXT_CAP as i32
}

/// Capacity of the PCM output buffer, in samples.
#[unsafe(no_mangle)]
pub extern "C" fn pcm_cap() -> i32 {
    PCM_CAP as i32
}

#[unsafe(no_mangle)]
pub extern "C" fn sample_rate() -> i32 {
    unsafe { RATE as i32 }
}

/// 1 if the last speak() filled PCM exactly and dropped samples past the end.
#[unsafe(no_mangle)]
pub extern "C" fn truncated() -> i32 {
    unsafe { TRUNCATED }
}

#[unsafe(no_mangle)]
pub extern "C" fn init() {
    unsafe {
        ENGINE = Some(Engine::new());
        RATE = engine_ref().map(|e| e.sample_rate()).unwrap_or(0);
        // Everything allocated up to here belongs to the Engine and must survive.
        INIT_MARK = OFFSET;
    }
}

/// Tear the engine down and rebuild it, rewinding the arena completely. Used by
/// the Lua layer to recover after a synthesis failure left state unusable.
#[unsafe(no_mangle)]
pub extern "C" fn reset() {
    unsafe {
        ENGINE = None;
        OFFSET = 0;
        INIT_MARK = 0;
        TRUNCATED = 0;
        RATE_MILLI = 1000;
        init();
    }
}

/// Speech rate in thousandths: 1000 = the voice's natural rate, higher is
/// slower. The crate clamps to >= 0.05 and rescales by the voice's own stretch.
#[unsafe(no_mangle)]
pub extern "C" fn set_rate(milli: i32) -> i32 {
    unsafe {
        match engine_mut() {
            Some(e) => {
                e.set_duration_stretch(milli as f32 / 1000.0);
                RATE_MILLI = milli;
                0
            }
            None => ERR_NO_ENGINE,
        }
    }
}

/// Pitch multiplier in thousandths: 1000 leaves the voice unchanged, 1200 is
/// 20% higher. The crate clamps to >= 0.1.
#[unsafe(no_mangle)]
pub extern "C" fn set_pitch(milli: i32) -> i32 {
    unsafe {
        match engine_mut() {
            Some(e) => {
                e.set_f0_shift(milli as f32 / 1000.0);
                0
            }
            None => ERR_NO_ENGINE,
        }
    }
}

/// Target mean pitch in Hz, applied directly (no clamping upstream).
#[unsafe(no_mangle)]
pub extern "C" fn set_f0_mean(hz: i32) -> i32 {
    unsafe {
        match engine_mut() {
            Some(e) => {
                e.params_mut().int_f0_target_mean = hz as f32;
                0
            }
            None => ERR_NO_ENGINE,
        }
    }
}

/// Pitch spread in Hz around the mean. 0 gives a monotone.
#[unsafe(no_mangle)]
pub extern "C" fn set_f0_stddev(hz: i32) -> i32 {
    unsafe {
        match engine_mut() {
            Some(e) => {
                e.params_mut().int_f0_target_stddev = hz as f32;
                0
            }
            None => ERR_NO_ENGINE,
        }
    }
}

/// Current parameters, in the same units the setters take, for round-tripping.
#[unsafe(no_mangle)]
pub extern "C" fn get_rate() -> i32 {
    unsafe {
        match engine_ref() {
            Some(_) => RATE_MILLI,
            None => ERR_NO_ENGINE,
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn get_pitch() -> i32 {
    unsafe {
        match engine_ref() {
            Some(e) => (e.params().f0_shift * 1000.0) as i32,
            None => ERR_NO_ENGINE,
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn get_f0_mean() -> i32 {
    unsafe {
        match engine_ref() {
            Some(e) => e.params().int_f0_target_mean as i32,
            None => ERR_NO_ENGINE,
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn get_f0_stddev() -> i32 {
    unsafe {
        match engine_ref() {
            Some(e) => e.params().int_f0_target_stddev as i32,
            None => ERR_NO_ENGINE,
        }
    }
}

/// Synthesize TEXT[0..len]. Returns the sample count written to PCM, or a
/// negative error code. Invalid UTF-8 is rejected rather than reinterpreted,
/// so a malformed byte from Lua can't walk the synthesiser off a cliff.
#[unsafe(no_mangle)]
pub extern "C" fn speak(len: i32) -> i32 {
    unsafe {
        TRUNCATED = 0;

        if len < 0 || len as usize > TEXT_CAP {
            return ERR_BAD_LEN;
        }
        let bytes = core::slice::from_raw_parts(core::ptr::addr_of!(TEXT).cast::<u8>(), len as usize);
        let s = match core::str::from_utf8(bytes) {
            Ok(s) => s,
            Err(_) => return ERR_BAD_UTF8,
        };

        let eng = match engine_ref() {
            Some(e) => e,
            None => return ERR_NO_ENGINE,
        };

        // Rewind only the per-utterance allocations; the Engine lives below this.
        OFFSET = INIT_MARK;

        let audio = eng.synthesize(s);
        RATE = audio.sample_rate;

        let src: &[i16] = &audio.samples;
        let total = src.len();
        let n = if total > PCM_CAP {
            TRUNCATED = 1;
            PCM_CAP
        } else {
            total
        };
        let dst = core::ptr::addr_of_mut!(PCM).cast::<i16>();
        for i in 0..n {
            dst.add(i).write(src[i]);
        }
        n as i32
    }
}
