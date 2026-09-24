// Shared headless-graphics core: the vendored uxn5 JS core plus its
// screen device, no browser needed. Loads a ROM, runs screen vectors,
// injects input exactly the way the C vm delivers it (ports poked,
// vectors evaled, self-clearing ports cleared), and reads back real
// layer pixels (not process liveness).
//
// The steps bump below emulates an uncapped core (native uxn2 has no
// per-vector cap): the vendored web core stops a vector after
// 0x80000 steps, which aborts the chess AI mid-move. Web builds
// genuinely stall there (see docs); the harness tests game logic,
// not the web cap.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');

module.exports = (ROOT, OUT) => {
  vm.runInThisContext(
    fs.readFileSync(`${ROOT}/vendor/uxn5/src/uxn.js`, 'utf8')
      .replace('let steps = 0x80000', 'let steps = 50000000'));
  vm.runInThisContext(
    fs.readFileSync(`${ROOT}/vendor/uxn5/src/devices/screen.js`, 'utf8'));

  function boot(romPath) {
    const emu = {};
    emu.uxn = new Uxn(emu);
    emu.screen = new Screen(emu);
    emu.screen.display = {style: {}};
    emu.screen.displayctx = {canvas: {}};
    emu.dei = p => (p & 0xf0) === 0x20 ? emu.screen.dei(p) : emu.uxn.dev[p];
    emu.deo = (p, v) => {
      emu.uxn.dev[p] = v;
      if ((p & 0xf0) === 0x20) emu.screen.deo(p);
      if (p >= 8 && p <= 13) emu.screen.update_palette();
    };
    emu.screen.resize(512, 320, 1);
    emu.uxn.load(fs.readFileSync(romPath)).eval(0x100);
    emu.cvec = (emu.uxn.dev[0x80] << 8) | emu.uxn.dev[0x81];
    emu.mvec = (emu.uxn.dev[0x90] << 8) | emu.uxn.dev[0x91];
    emu.frame = () => emu.uxn.eval(emu.screen.vector);
    emu.setMouse = (x, y) => {
      emu.uxn.dev[0x92] = x >> 8; emu.uxn.dev[0x93] = x;
      emu.uxn.dev[0x94] = y >> 8; emu.uxn.dev[0x95] = y;
    };
    // Slow human click: down, frames, up, frames.
    emu.click = (x, y) => {
      emu.setMouse(x, y);
      emu.uxn.dev[0x96] = 1; emu.uxn.eval(emu.mvec);
      emu.frame(); emu.uxn.dev[0x96] = 0; emu.uxn.eval(emu.mvec);
      emu.frame();
    };
    // Quick click: down+up between frames (must survive via latch).
    emu.quickClick = (x, y) => {
      emu.setMouse(x, y);
      emu.uxn.dev[0x96] = 1; emu.uxn.eval(emu.mvec);
      emu.uxn.dev[0x96] = 0; emu.uxn.eval(emu.mvec);
      emu.frame(); emu.frame();
    };
    // Controller button tap (mirrors controller_down/up + vector).
    emu.tapButton = mask => {
      emu.uxn.dev[0x82] |= mask; emu.uxn.eval(emu.cvec);
      emu.uxn.dev[0x82] &= ~mask; emu.uxn.eval(emu.cvec);
      emu.frame(); emu.frame();
    };
    // Key press (mirrors controller_key: port set, vector, cleared).
    emu.tapKey = k => {
      emu.uxn.dev[0x83] = k; emu.uxn.eval(emu.cvec); emu.uxn.dev[0x83] = 0;
      emu.frame(); emu.frame();
    };
    emu.stacks = () => ({rst: emu.uxn.rst.ptr, wst: emu.uxn.wst.ptr});
    emu.checkStacks = (tag, base) => {
      assert.strictEqual(emu.uxn.rst.ptr, base.rst, `${tag} return stack`);
      assert.strictEqual(emu.uxn.wst.ptr, base.wst, `${tag} working stack`);
    };
    emu.grid = () => {
      const s = emu.screen, out = [];
      for (let y = 0; y < s.height; y++) {
        const row = [];
        for (let x = 0; x < s.width; x++)
          row.push(s.layers.fg[(y + 8) * (s.width + 16) + x + 8] ||
                   s.layers.bg[(y + 8) * (s.width + 16) + x + 8]);
        out.push(row);
      }
      return out;
    };
    emu.shot = name => {
      const s = emu.screen, counts = [0, 0, 0, 0];
      for (let y = 0; y < s.height; y++) for (let x = 0; x < s.width; x++) {
        const i = (y + 8) * (s.width + 16) + x + 8;
        counts[s.layers.fg[i] || s.layers.bg[i]]++;
      }
      console.log(name, {counts, wst: emu.uxn.wst.ptr, rst: emu.uxn.rst.ptr});
      assert(counts.filter(n => n > 0).length > 1, `${name}: blank screen`);
      return counts;
    };
    emu.dumpPpm = name => {
      const s = emu.screen, rgb = [];
      for (let y = 0; y < s.height; y++) for (let x = 0; x < s.width; x++) {
        const i = (y + 8) * (s.width + 16) + x + 8;
        rgb.push(...s.palette[s.layers.fg[i] || s.layers.bg[i]]);
      }
      fs.writeFileSync(`${OUT}/chess-${name}.ppm`, Buffer.concat(
        [Buffer.from(`P6\n${s.width} ${s.height}\n255\n`), Buffer.from(rgb)]));
    };
    return emu;
  }

  return {boot, assert};
};
