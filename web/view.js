'use strict'

/* etal web target: window sizing.
 *
 * The bundled page used to open at a hardcoded 2x with a Zoom button
 * that flipped between 1x and 2x, so a 128px game was a 256px letterbox
 * in the middle of a large screen and nothing ever used the width
 * available. This controller replaces that with:
 *
 *   Fit        the default -- the largest whole-number scale whose
 *              window still fits both axes, so nothing scrolls or
 *              overflows. Recomputed whenever the browser window or
 *              the ROM's screen size changes.
 *   1x 2x 3x   fixed integer scales, for pixel-exact work.
 *   Fullscreen the canvas takes the whole viewport.
 *
 * Whole-number scales only: a fractional scale makes a pixel-art tile
 * a different number of device pixels on alternating rows, which is
 * exactly the blur `image-rendering: pixelated` exists to prevent.
 * Fitting by width alone would also push tall games off the bottom of
 * the screen, so width is the target and height is the constraint.
 *
 * The choice is persisted per browser, so a reload keeps it. Ours
 * rather than vendored, and wired from the boot script (see
 * target_web.ml) so vendor/uxn5 stays byte-identical to upstream.
 */

/* Room left for the chrome: the meta bar above the canvas and a small
   margin. Measured from the real layout rather than hardcoded, so it
   survives a font-size or padding change. */
const CHROME = 8

const MODES = ["fit", "1", "2", "3", "full"]
const KEY = "uxn.etal.view"

function View(emu, initial)
{
	this.emu = emu
	this.screen = emu.screen
	this.mode = MODES.indexOf(initial) >= 0 ? initial : "fit"
	try {
		const saved = window.localStorage.getItem(KEY)
		if(saved && MODES.indexOf(saved) >= 0) this.mode = saved
	} catch(e) { /* private mode, or storage disabled: stay on default */ }
	this.bind()
	this.apply()
}

View.prototype.available = function () {
	const bar = document.getElementById("meta")
	const bar_h = bar ? bar.getBoundingClientRect().height : 0
	return {
		w: Math.max(1, window.innerWidth - CHROME * 2),
		h: Math.max(1, window.innerHeight - bar_h - CHROME * 2),
	}
}

/* Largest integer scale that fits both axes, never below 1x. */
View.prototype.fit_scale = function () {
	const s = this.screen
	if(!s.width || !s.height) return 1
	const a = this.available()
	return Math.max(1, Math.floor(Math.min(a.w / s.width, a.h / s.height)))
}

View.prototype.scale = function () {
	if(this.mode === "full") return this.fit_scale()
	if(this.mode === "fit") return this.fit_scale()
	return parseInt(this.mode, 10) || 1
}

/* The canvas element's CSS size is what the emulator's set_zoom
   writes, so this stays the single place scaling happens. */
View.prototype.apply = function () {
	const s = this.screen
	const want = this.scale()
	if(this.mode === "full") {
		const a = this.available()
		/* Fullscreen stretches the canvas to the viewport rather than
		   scaling by an integer, because the point is to fill the
		   screen. Nearest-neighbour keeps the pixels square. */
		const z = Math.max(want, Math.min(a.w / s.width, a.h / s.height))
		s.display.style.width = `${Math.floor(s.width * z)}px`
		s.display.style.height = `${Math.floor(s.height * z)}px`
	} else {
		s.set_zoom(want)
	}
	document.body.classList.toggle("full", this.mode === "full")
	this.sync_buttons()
}

View.prototype.set = function (mode) {
	if(MODES.indexOf(mode) < 0) return
	this.mode = mode
	try { window.localStorage.setItem(KEY, mode) } catch(e) { /* not fatal */ }
	this.apply()
}

View.prototype.sync_buttons = function () {
	const bar = document.getElementById("etal_view")
	if(!bar) return
	for(const b of bar.querySelectorAll("button")) {
		const on = b.dataset.mode === this.mode
		b.classList.toggle("on", on)
		b.setAttribute("aria-pressed", on ? "true" : "false")
	}
}

View.prototype.bind = function () {
	const self = this
	const bar = document.getElementById("etal_view")
	if(bar) {
		bar.addEventListener("click", (e) => {
			const b = e.target.closest("button")
			if(b && b.dataset.mode) self.set(b.dataset.mode)
		})
	}
	/* Re-fit on resize, but only in fit/full: a fixed 2x is a choice,
	   and yanking it back would fight the person who made it. */
	let pending = false
	window.addEventListener("resize", () => {
		if(self.mode !== "fit" && self.mode !== "full") return
		if(pending) return
		pending = true
		window.requestAnimationFrame(() => { pending = false; self.apply() })
	})
	/* The ROM owns the screen size: re-fit when it changes, which
	   happens on the first frame and on any width/height write. */
	const orig_resize = this.screen.resize
	this.screen.resize = function (w, h, scale) {
		const r = orig_resize.call(this, w, h, scale)
		self.apply()
		return r
	}
	/* Keep the vendored Zoom button working (it is still in the meta
	   bar, and ctrl+B alt+S reaches it): route it through us so the
	   persisted mode and the button state cannot drift apart. */
	this.screen.toggle_zoom = () => {
		self.set(self.screen.zoom === 2 ? "1" : "2")
	}
}
