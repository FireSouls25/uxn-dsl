'use strict'

/* etal web target: the Varvara Audio device.
 *
 * Upstream uxn5 ships no audio device at all -- vendor/uxn5/src/devices
 * has console, controller, datetime, mouse, screen, system, and emu.js
 * routes only port pages 0x00, 0x10, 0x20 and 0xc0. A bundled page
 * therefore never heard anything: writes to Audio0.pitch landed in raw
 * device memory and stopped there. This file is the missing device.
 *
 * It is a faithful port of uxn2's renderer (uxn2/src/uxn2.c, the
 * "Audio" section) so a ROM sounds the same on both VMs: the same
 * advances table, the same NOTE_PERIOD/ADSR_STEP math, the same
 * envelope, the same single-cycle vs sample-repeat period choice, and
 * the same "high nibble is the left channel" volume convention.
 *
 * Deliberately ours rather than vendored: the wiring is done from the
 * boot script (see target_web.ml), so vendor/ stays byte-identical to
 * the pinned upstream checkout.
 *
 * Port map, one voice per 16-byte block:
 *   +0x00 vector   2   accepted, no handler (matches uxn2)
 *   +0x02 position 2   read: playback position
 *   +0x04 output   1   read: stereo VU meter
 *   +0x08 adsr     2
 *   +0x0a length   2
 *   +0x0c addr     2
 *   +0x0e volume   1   high nibble = left, low nibble = right
 *   +0x0f pitch    1   write triggers playback; high bit = play once
 */

const SAMPLE_FREQUENCY = 44100

/* uxn2: SAMPLE_FREQUENCY * 0x4000 / 11025. Integer math, 65536. */
const NOTE_PERIOD = (SAMPLE_FREQUENCY * 0x4000 / 11025) | 0

/* uxn2: SAMPLE_FREQUENCY / 0xf. Integer math, 2940. */
const ADSR_STEP = (SAMPLE_FREQUENCY / 0xf) | 0

/* uxn2: advances[12], the per-note semitone step size. */
const ADVANCES = [
	0x80000, 0x879c8, 0x8facd, 0x9837f, 0xa1451, 0xaadc1,
	0xb504f, 0xbfc88, 0xcb2ff, 0xd7450, 0xe411f, 0xf1a1c
]

/* Voice device pages, matching uxn2's &dev[0x30..0x60]. */
const VOICE_PAGES = [0x30, 0x40, 0x50, 0x60]

/* uxn2 renders on demand inside an audio callback, so it needs no cap.
   We render the whole note up front into an AudioBuffer, which needs
   one: a looping sample with a long release would never terminate.
   Eight seconds is far past any chiptune envelope. */
const MAX_RENDER = SAMPLE_FREQUENCY * 8

/* uxn2 casts `(Uint8 sample + 0x80)` down to Sint8, so 0x80..0xff wrap
   negative. Same wrap, spelled out. */
function sint8(x) {
	x &= 0xff
	return x > 127 ? x - 256 : x
}

function Audio(emu)
{
	this.emu = emu
	this.ctx = null
	this.voices = []
	for(let i = 0; i < VOICE_PAGES.length; i++) {
		this.voices.push({
			addr: 0, len: 0, period: 0, advance: 0,
			age: 0, i: 0, count: 0,
			a: 0, d: 0, s: 0, r: 0,
			volume: [0, 0],
			repeat: false,
			node: null,
		})
	}

	/* Browsers refuse to start audio without a gesture, and a ROM
	   starts playing at load. The context is created lazily and
	   resumed on the first interaction, so a page nobody touches stays
	   silent and a page somebody plays makes noise. */
	this.unlock = () => {
		if(!this.ctx) {
			const Ctor = window.AudioContext || window.webkitAudioContext
			if(!Ctor) return
			this.ctx = new Ctor()
		}
		if(this.ctx.state === "suspended") this.ctx.resume()
	}

	this.voice_of = (port) => {
		for(let i = 0; i < VOICE_PAGES.length; i++)
			if((port & 0xf0) === VOICE_PAGES[i]) return i
		return -1
	}

	/* DEI: only position and output are computed. Everything else
	   falls through to raw device memory, which is what uxn2 does too
	   -- its dei_handlers table overrides only those two. */
	this.dei = (port) => {
		const n = this.voice_of(port)
		if(n < 0) return this.emu.uxn.dev[port]
		const v = this.voices[n]
		const off = port - VOICE_PAGES[n]
		if(off === 0x04) return this.vu(v)
		if(off === 0x02) return v.i & 0xff
		if(off === 0x03) return (v.i >> 8) & 0xff
		return this.emu.uxn.dev[port]
	}

	/* DEO: writing pitch starts the note, exactly as uxn2's
	   deo_handlers[0x3f / 0x4f / 0x5f / 0x6f] do. */
	this.deo = (port) => {
		const n = this.voice_of(port)
		if(n < 0) return
		if(port - VOICE_PAGES[n] === 0x0f) this.play(n)
	}

	/* uxn2: envelope(c, age) -- the ADSR curve. Returns the amplitude
	   multiplier and clears the voice's advance once the release is
	   over, which is how the note stops. */
	this.envelope = (v, age) => {
		if(!v.r) return 0x0888
		if(age < v.a) return 0x0888 * age / v.a
		if(age < v.d) {
			/* uxn2 divides by (d - a). A zero span is UB in C, so hold
			   the level flat rather than emit NaN into the buffer. */
			const span = v.d - v.a
			return span === 0 ? 0x0888 : 0x0444 * (2 * v.d - v.a - age) / span
		}
		if(age < v.s) return 0x0444
		if(age < v.r) {
			const span = v.r - v.s
			return span === 0 ? 0x0444 : 0x0444 * (v.r - age) / span
		}
		return 0
	}

	/* uxn2: audio_get_vu -- stereo level meter, 4 bits per channel. */
	this.vu = (v) => {
		if(!v.advance || !v.period) return 0
		let sum0 = 0, sum1 = 0
		if(v.volume[0]) sum0 = 1 + this.envelope(v, v.age) * v.volume[0] / 0x800
		if(v.volume[1]) sum1 = 1 + this.envelope(v, v.age) * v.volume[1] / 0x800
		if(sum0 > 0xf) sum0 = 0xf
		if(sum1 > 0xf) sum1 = 0xf
		return (sum0 << 4) | sum1
	}

	/* uxn2: audio_start -- read the device block, derive the note. */
	this.start = (n, d) => {
		const v = this.voices[n]
		const pitch = d[0xf] & 0x7f
		const addr = (d[0x0c] << 8) | d[0x0d]
		const adsr = (d[0x08] << 8) | d[0x09]
		let len = (d[0x0a] << 8) | d[0x0b]
		if(len > 0x10000 - addr) len = 0x10000 - addr
		v.addr = addr
		v.len = len
		v.volume[0] = d[0x0e] >> 4
		v.volume[1] = d[0x0e] & 0xf
		v.repeat = !(d[0x0f] & 0x80)
		v.age = 0
		v.i = 0
		v.count = 0
		if(pitch < 108 && len) {
			v.advance = ADVANCES[pitch % 12] >> (8 - Math.floor(pitch / 12))
		} else {
			v.advance = 0
			v.period = 0
			return
		}
		v.a = ADSR_STEP * (adsr >> 12)
		v.d = ADSR_STEP * ((adsr >> 8) & 0xf) + v.a
		v.s = ADSR_STEP * ((adsr >> 4) & 0xf) + v.d
		v.r = ADSR_STEP * (adsr & 0xf) + v.s
		/* Short samples run "single cycle": the period is stretched so
		   one pass of the sample fills the note. Longer ones play at
		   1:1 from middle C. */
		v.period = len <= 0x100 ? NOTE_PERIOD * 337 / 2 / len | 0 : NOTE_PERIOD
	}

	/* uxn2: audio_render's inner loop. `st` is the running voice state
	   (uxn2 keeps these in the struct; we keep them apart so the note
	   can be rendered twice without touching the live voice). Passing
	   `out` as null makes this a counting pass. */
	this.walk = (v, st, out) => {
		const mem = this.emu.uxn.mem
		let n = 0
		/* `!v.r` is uxn2's "no envelope" case (adsr == 0): it holds full
		   amplitude forever, so only the sample end or the cap stops it. */
		while(st.advance && v.period && (!v.r || st.age < v.r) && n < MAX_RENDER) {
			st.count += st.advance
			st.i += Math.floor(st.count / v.period)
			st.count %= v.period
			if(st.i >= v.len) {
				if(!v.repeat) { st.advance = 0; break }
				st.i %= v.len
			}
			const s = sint8(mem[(v.addr + st.i) & 0xffff] + 0x80) * this.envelope(v, st.age++)
			if(out) {
				/* uxn2 accumulates into Sint16, so its peak is ~1.08e4.
				   Web Audio buffers are floats in [-1, 1], so scale by
				   the Sint16 full scale or every note clips flat. */
				out[0][n] = s * v.volume[0] / 0x180 / 32768
				out[1][n] = s * v.volume[1] / 0x180 / 32768
			}
			n++
		}
		return n
	}

	/* Trigger a voice: render the note, then schedule it. Retriggering
	   stops the previous node first, so a held note does not stack up. */
	this.play = (n) => {
		const dev = this.emu.uxn.dev
		const base = VOICE_PAGES[n]
		/* Read the block into a scratch array so the offsets read like
		   uxn2's `d[0x08]`, where `d` is &dev[base]. */
		const d = []
		for(let k = 0; k < 16; k++) d[k] = dev[base + k]
		const v = this.voices[n]
		this.start(n, d)
		if(!v.advance) {
			/* uxn2's audio_start clears advance for a silent pitch
			   (>= 108) or a zero length, and a voice with no advance
			   renders nothing -- so a rest silences whatever the voice
			   was already playing. Drop the scheduled node to match. */
			if(v.node) {
				try { v.node.stop() } catch(e) { /* already ended */ }
				v.node.disconnect()
				v.node = null
			}
			return
		}
		this.unlock()
		if(!this.ctx) return
		/* Two passes: count the frames, then fill exactly-sized
		   buffers. Cheaper than growing arrays mid-note. */
		const frames = this.walk(v, { count: 0, i: 0, age: 0, advance: v.advance }, null)
		if(!frames) return
		const left = new Float32Array(frames)
		const right = new Float32Array(frames)
		const st = { count: 0, i: 0, age: 0, advance: v.advance }
		this.walk(v, st, [left, right])
		/* Keep the live voice in sync with the render, so position and
		   VU report the finished note rather than a stale one. */
		v.count = st.count
		v.i = st.i
		v.age = st.age
		v.advance = st.advance
		const buffer = this.ctx.createBuffer(2, frames, SAMPLE_FREQUENCY)
		buffer.copyToChannel(left, 0)
		buffer.copyToChannel(right, 1)
		if(v.node) {
			try { v.node.stop() } catch(e) { /* already ended */ }
			v.node.disconnect()
		}
		const node = this.ctx.createBufferSource()
		node.buffer = buffer
		node.loop = v.repeat
		node.connect(this.ctx.destination)
		node.start()
		v.node = node
	}
}
