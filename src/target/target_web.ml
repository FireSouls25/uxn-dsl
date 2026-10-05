(* Web target: single self-contained game.html.
 *
 * Embeds the vendored uxn5 javascript emulator (ISC, Hundred Rabbits;
 * license notice is stamped into every emitted page) plus the game ROM
 * as base64. ROM bytes load through the stock Emu.load path after
 * device init (microtask ordering: our loader queues behind init's
 * own .then). Vanilla JS core only (no wasm payload to fetch). *)

let uxn5_notice = "uxn5 (c) 2020 Devine Lu Linvega - ISC, vendored from \
  https://git.sr.ht/~rabbits/uxn5 - Permission to use, copy, modify, and \
  distribute this software for any purpose with or without fee is hereby \
  granted, provided that the above copyright notice and this permission \
  notice appear in all copies."

(* Ordered emulator sources (boot.js excluded: we provide our own
   boot consts + loader snippet). *)
let uxn5_sources = [
  "src/uxn.js";
  "src/devices/system.js";
  "src/devices/console.js";
  "src/devices/controller.js";
  "src/devices/datetime.js";
  "src/devices/mouse.js";
  "src/devices/screen.js";
  "src/emu.js";
]

let base64_encode s =
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" in
  let n = String.length s in
  let buf = Buffer.create ((n + 2) / 3 * 4) in
  let get i = if i < n then Char.code s.[i] else 0 in
  let rec loop i =
    if i >= n then ()
    else begin
      let b0 = get i and b1 = get (i + 1) and b2 = get (i + 2) in
      Buffer.add_char buf alphabet.[b0 lsr 2];
      Buffer.add_char buf alphabet.[((b0 land 3) lsl 4) lor (b1 lsr 4)];
      Buffer.add_char buf (if i + 1 < n then alphabet.[((b1 land 15) lsl 2) lor (b2 lsr 6)] else '=');
      Buffer.add_char buf (if i + 2 < n then alphabet.[b2 land 63] else '=');
      loop (i + 3)
    end
  in
  loop 0;
  Buffer.contents buf

let read_text path =
  (* Binary mode: same CRLF rationale as Loader.read_source. *)
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s
(* NOTE: intentionally duplicates Loader.read_source instead of calling
   it, so etal_target stays independent of etal_loader. *)

(* Bundle-time patch for the uxn5 per-vector step cap (vendor files stay
   pristine — the replacement happens on the in-memory copy at emit time).
   Root cause: vendor/uxn5/src/uxn.js eval caps at steps=0x80000 per vector,
   while uxn2 runs unbounded for(;;) to BRK (uxn2.c eval). Chess ai_choose
   needs ~2.5-2.8M steps, so the web core truncates mid make/unmake ->
   flash/teleport as white, unplayable as black. Raised here to 0x800000
   (~8.4M, ~3x headroom). Native targets untouched. *)
let step_needle = "let steps = 0x80000"
let step_patched =
  "let steps = 0x800000 /* etal bundle: raise uxn5 per-vector cap from \
   0x80000 (~512k) to 0x800000 (~8.4M); chess AI needs ~2.5-2.8M steps \
   (ai_choose), native uxn2 is unbounded to BRK, so the stock cap truncates \
   mid make/unmake. Vendor file stays pristine. */"

(* Second bundle-time patch, same rationale: the Audio device has to
   read the ROM to resample a note, but `ram` in uxn.js is a closure
   local with no accessor. Expose it as `this.mem` on the core object.
   Only the 64KB main-RAM array matches this needle; the 256-byte
   device array declared above it does not, so this stays single-shot. *)
let mem_needle = "const ram = new Uint8Array(0x10000)"
let mem_patched =
  "const ram = this.mem = new Uint8Array(0x10000) /* etal bundle: expose \
   main RAM so the Audio device can read samples (uxn2 reads &ram[addr]). \
   Vendor file stays pristine. */"

(* Minimal single-occurrence replace (no Str dependency). *)
let replace_once ~needle ~replacement s =
  let nl = String.length needle in
  let sl = String.length s in
  let rec find i =
    if i + nl > sl then None
    else if String.sub s i nl = needle then Some i
    else find (i + 1)
  in
  match find 0 with
  | None -> s
  | Some i ->
    String.sub s 0 i ^ replacement ^ String.sub s (i + nl) (sl - i - nl)

let patch_step_budget src =
  replace_once ~needle:step_needle ~replacement:step_patched src

let patch_main_ram src =
  replace_once ~needle:mem_needle ~replacement:mem_patched src

(* Ours, not vendored: uxn5 upstream has no audio device, and the
   window-size behaviour is a page concern, not an emulator one. Kept
   out of vendor/ so vendor/uxn5 stays byte-identical to the pinned
   checkout. Shipped next to the etal binary in web/. *)
let read_extra ~support_dir name =
  let path = Filename.concat support_dir name in
  try read_text path
  with Sys_error _ ->
    failwith (Printf.sprintf
      "web target: cannot read support file `%s` (looked in %s; these ship \
       with etal under web/)" name support_dir)

let emit_html ~title ~game_name ~rom_bytes ~vendor_dir ~support_dir ~view =
  let js = List.map (fun rel ->
    try
      let src = read_text (Filename.concat vendor_dir rel) in
      if rel = "src/uxn.js" then patch_main_ram (patch_step_budget src) else src
    with Sys_error _ ->
      failwith (Printf.sprintf "web target: cannot read vendored uxn5 file `%s`" rel)
  ) uxn5_sources in
  let audio_js = read_extra ~support_dir "audio.js" in
  let view_js = read_extra ~support_dir "view.js" in
  let rom_b64 = base64_encode rom_bytes in
  let buf = Buffer.create 65536 in
  let w s = Buffer.add_string buf s in
  w "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\"/>\n";
  w "<meta name=\"viewport\" content=\"width=device-width\" />\n";
  w (Printf.sprintf "<title>%s</title>\n" title);
  w "<style>\n";
  w "body{font-family:monospace;padding:8px;margin:0;background:#000;color:#fff}\n";
  w "#emulator{width:fit-content;margin:auto}\n";
  w "#display{image-rendering:pixelated;image-rendering:crisp-edges;display:block;margin:0 auto}\n";
  w "body.embed{padding:0;overflow:hidden}\n";
  w "body.embed #meta{display:none}\n";
  (* Fullscreen: the canvas owns the viewport, no chrome, no scroll. *)
  w "body.full{padding:0;overflow:hidden}\n";
  w "body.full #emulator{position:fixed;inset:0;display:flex;align-items:center;justify-content:center}\n";
  w "body.full #display{margin:0}\n";
  w "#meta{text-align:center;margin-top:12px;font-size:12px;color:#888}\n";
  w "#meta button{background:#fff;border:0;border-radius:30px;padding:2px 12px;margin-right:10px}\n";
  w "#meta kbd{font-weight:bold;color:#fff}\n";
  w "#etal_view{margin-right:14px}\n";
  w "#etal_view button{background:#333;color:#ccc}\n";
  w "#etal_view button.on{background:#fff;color:#000}\n";
  w "</style>\n</head>\n<body>\n";
  w "<div id=\"emulator\">\n<canvas id=\"display\" width=\"100\" height=\"100\"></canvas>\n";
  (* All ids below are required by the vendored emulator scripts
     (console.js needs console_input/std/err, emu.js needs
     browser/save/share, system.js may need metarom). Hidden in
     embed mode via CSS. *)
  w "<div id=\"console\" style=\"display:none\">\n";
  w "<input id=\"console_input\" type=\"text\" />\n";
  w "<pre id=\"console_std\"></pre>\n<pre id=\"console_err\"></pre>\n</div>\n";
  w "<div id=\"meta\">\n";
  w "<span id=\"etal_view\">\n";
  List.iter (fun (mode, label) ->
    w (Printf.sprintf "<button data-mode=\"%s\">%s</button>\n" mode label)
  ) [ ("fit", "Fit"); ("1", "1&times;"); ("2", "2&times;"); ("3", "3&times;");
      ("full", "Fullscreen") ];
  w "</span>\n";
  w "<button onclick=\"emulator.screen.toggle_zoom()\">Zoom</button>\n";
  w "<span><kbd>A</kbd> ctrl <kbd>B</kbd> alt <kbd>SEL</kbd> shift <kbd>Start</kbd> home</span>\n";
  w "<span id=\"share\"></span><span id=\"save\"></span><span id=\"metarom\"></span>\n";
  w "<input id=\"browser\" type=\"file\" style=\"display:none\" />\n";
  w "</div>\n</div>\n";
  w "<!-- ";
  w uxn5_notice;
  w " -->\n";
  List.iter (fun src ->
    w "<script>\n";
    w src;
    w "\n</script>\n"
  ) js;
  (* Ours: the Audio device uxn5 lacks, then the window-size
     controller. Both only define a constructor; the boot script below
     instantiates them, after Emu exists. *)
  w "<script>\n";
  w audio_js;
  w "\n</script>\n";
  w "<script>\n";
  w view_js;
  w "\n</script>\n";
  w "<script>\n";
  w "const boot_ulz = 0;\nconst keyctrl = 0;\n";
  (* The size controller owns scaling; 1x here is just the value the
     emulator applies for the frame before the ROM reports its size. *)
  w "const default_zoom = 1;\n";
  w (Printf.sprintf "const ETAL_GAME = %S;\n" game_name);
  w (Printf.sprintf "const ETAL_VIEW = %S;\n" view);
  w (Printf.sprintf "const ETAL_ROM_B64 = \"%s\";\n" rom_b64);
  w "const emulator = new Emu(true);\n";
  (* Audio: uxn5 routes port pages 0x00/0x10/0x20/0xc0 only, so the
     four Varvara voices (0x30/0x40/0x50/0x60) fall through to raw
     memory. Wrap dei/deo rather than editing emu.js, keeping the
     vendored source pristine. *)
  w "emulator.audio = new Audio(emulator);\n";
  w "(() => {\n";
  w "  const dei = emulator.dei, deo = emulator.deo;\n";
  w "  const is_audio = (port) => (port & 0xf0) >= 0x30 && (port & 0xf0) <= 0x60;\n";
  w "  emulator.dei = (port) => is_audio(port) ? emulator.audio.dei(port) : dei(port);\n";
  w "  emulator.deo = (port, val) => {\n";
  w "    deo(port, val);\n";
  w "    if(is_audio(port)) emulator.audio.deo(port, val);\n";
  w "  };\n";
  w "})();\n";
  (* A context created at load stays suspended until a gesture. *)
  w "['pointerdown','keydown','touchstart'].forEach(e =>\n";
  w "  window.addEventListener(e, () => emulator.audio.unlock(), {once:false}));\n";
  w "emulator.init();\n";
  w "Promise.resolve().then(() => {\n";
  w "  const rom = Uint8Array.from(atob(ETAL_ROM_B64), c => c.charCodeAt(0));\n";
  w "  emulator.load(rom);\n";
  w "  emulator.view = new View(emulator, ETAL_VIEW);\n";
  w "});\n";
  w "</script>\n</body>\n</html>\n";
  Buffer.contents buf

let name = "web"

let default_uxn5_dir () = Target.resolve_vendor_dir "uxn5"
let bundle ~verbose ~vendor_dir ~rom_path ~output_file ~view =
  if verbose then Printf.eprintf "Using uxn5: %s\n" vendor_dir;
  let support_dir = Target.resolve_support_dir "web" in
  if verbose then Printf.eprintf "Using web support: %s\n" support_dir;
  let rom_bytes = Target.read_file_bin rom_path in
  let html = emit_html
    ~title:(Printf.sprintf "%s - etal" (Filename.basename output_file))
    ~game_name:(Filename.basename output_file)
    ~rom_bytes ~vendor_dir ~support_dir ~view in
  (* Binary mode: same CRLF rationale (Windows line translation
     would corrupt the embedded base64 ROM). *)
  let oc = open_out_bin output_file in
  output_string oc html;
  close_out oc;
  if verbose then Printf.eprintf "Wrote web bundle to %s\n" output_file
