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

let emit_html ~title ~game_name ~rom_bytes ~vendor_dir =
  let js = List.map (fun rel ->
    try read_text (Filename.concat vendor_dir rel)
    with Sys_error _ ->
      failwith (Printf.sprintf "web target: cannot read vendored uxn5 file `%s`" rel)
  ) uxn5_sources in
  let rom_b64 = base64_encode rom_bytes in
  let buf = Buffer.create 65536 in
  let w s = Buffer.add_string buf s in
  w "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\"/>\n";
  w "<meta name=\"viewport\" content=\"width=device-width\" />\n";
  w (Printf.sprintf "<title>%s</title>\n" title);
  w "<style>\n";
  w "body{font-family:monospace;padding:30px;margin:0;background:#000;color:#fff}\n";
  w "#emulator{width:fit-content;margin:auto}\n";
  w "#display{image-rendering:pixelated;image-rendering:crisp-edges;display:block;margin:0 auto}\n";
  w "body.embed{padding:0;overflow:hidden}\n";
  w "body.embed #meta{display:none}\n";
  w "#meta{text-align:center;margin-top:12px;font-size:12px;color:#888}\n";
  w "#meta button{background:#fff;border:0;border-radius:30px;padding:2px 12px;margin-right:10px}\n";
  w "#meta kbd{font-weight:bold;color:#fff}\n";
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
  w "<script>\n";
  w "const boot_ulz = 0;\nconst keyctrl = 0;\nconst default_zoom = 2;\n";
  w (Printf.sprintf "const ETAL_GAME = %S;\n" game_name);
  w (Printf.sprintf "const ETAL_ROM_B64 = \"%s\";\n" rom_b64);
  w "const emulator = new Emu(true);\n";
  w "emulator.init();\n";
  w "Promise.resolve().then(() => {\n";
  w "  const rom = Uint8Array.from(atob(ETAL_ROM_B64), c => c.charCodeAt(0));\n";
  w "  emulator.load(rom);\n";
  w "});\n";
  w "</script>\n</body>\n</html>\n";
  Buffer.contents buf

let name = "web"

let default_uxn5_dir () = Target.resolve_vendor_dir "uxn5"

let bundle ~verbose ~vendor_dir ~rom_path ~output_file =
  if verbose then Printf.eprintf "Using uxn5: %s\n" vendor_dir;
  let rom_bytes = Target.read_file_bin rom_path in
  let html = emit_html
    ~title:(Printf.sprintf "%s - etal" (Filename.basename output_file))
    ~game_name:(Filename.basename output_file)
    ~rom_bytes ~vendor_dir in
  (* Binary mode: same CRLF rationale (Windows line translation
     would corrupt the embedded base64 ROM). *)
  let oc = open_out_bin output_file in
  output_string oc html;
  close_out oc;
  if verbose then Printf.eprintf "Wrote web bundle to %s\n" output_file
