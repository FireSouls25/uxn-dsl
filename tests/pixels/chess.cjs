// Chess pixel scenario: menu/color/board render, 300 idle frames with
// stable stacks, ESC + click pause/resume, select, human move with
// glide, chained bot reply with glide, settle, and quit-by-state.
// Usage: node chess.cjs <root> <outdir> <rom>
const H = require('./harness.cjs')(process.argv[2], process.argv[3]);
const {boot, assert} = H;
const emu = boot(process.argv[4]);
assert(emu.cvec !== 0 && emu.mvec !== 0, 'input vectors wired');

function boardDiff(a, b) {
  let d = 0;
  for (let y = 0; y < 128; y++) for (let x = 64; x < 192; x++)
    if (a[y][x] !== b[y][x]) d++;
  return d;
}

emu.frame(); emu.shot('menu'); emu.dumpPpm('menu');
emu.quickClick(84, 58); emu.shot('color');          // PLAY, sub-frame click
emu.click(80, 54);
for (let i = 0; i < 12; i++) emu.frame();
emu.shot('board'); emu.dumpPpm('board');
const baseline = emu.stacks();
for (let i = 0; i < 300; i++) {
  emu.frame();
  assert.strictEqual(emu.uxn.rst.ptr, baseline.rst, `idle rst at frame ${i + 1}`);
  assert.strictEqual(emu.uxn.wst.ptr, baseline.wst, `idle wst at frame ${i + 1}`);
}
emu.shot('idle');
console.log('PASS: both stacks constant for 300 frames', baseline);
emu.tapKey(27); emu.shot('pause-esc');
emu.checkStacks('esc-pause', baseline);
emu.tapKey(27); emu.shot('resume-esc');
emu.checkStacks('esc-resume', baseline);
emu.click(4, 54); emu.shot('pause-click');
emu.checkStacks('click-pause', baseline);
emu.click(68, 66); emu.shot('resume-click');
emu.checkStacks('click-resume', baseline);
emu.click(136, 104); emu.shot('selected');
emu.click(136, 72);                                 // e2-e4, arms human slide
emu.frame();
const slideA = emu.grid();
emu.frame(); emu.frame(); emu.frame();
const slideB = emu.grid();
const mdHuman = boardDiff(slideA, slideB);
assert(mdHuman > 50, `human slide shows no motion (diff ${mdHuman})`);
console.log(`PASS: human slide in motion (board diff ${mdHuman})`);
for (let i = 0; i < 7; i++) emu.frame();            // AI chains off t==1
emu.frame();
const slideC = emu.grid();
emu.frame(); emu.frame(); emu.frame();
const slideD = emu.grid();
const mdBot = boardDiff(slideC, slideD);
assert(mdBot > 50, `bot slide shows no motion (diff ${mdBot})`);
console.log(`PASS: bot slide in motion (board diff ${mdBot})`);
for (let i = 0; i < 14; i++) emu.frame();
emu.shot('moved'); emu.dumpPpm('moved');
emu.checkStacks('move', baseline);

// Quit on a fresh boot (menu screen): click and keyboard paths.
for (const via of ['mouse', 'key']) {
  const e2 = boot(process.argv[4]);
  e2.frame();
  if (via === 'mouse') {
    e2.setMouse(84, 74);
    e2.uxn.dev[0x96] = 1; e2.uxn.eval(e2.mvec); e2.frame();
  } else {
    e2.tapButton(0x20);                             // Down to QUIT
    e2.tapKey(13);                                  // Enter confirms
  }
  assert.strictEqual(e2.uxn.dev[0x0f], 1, `${via} QUIT did not set System/state`);
  console.log(`PASS: ${via} QUIT sets System/state (clean exit)`);
}
console.log('ALL-OK');
