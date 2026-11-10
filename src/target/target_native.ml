(* Native bundle backends: unix rows use a sh stub + tar.gz payload,
 * the Windows row is one .exe and the Linux rows one ELF (the VM with
 * the ROM appended, see bundle_embedded) when their VM is built with
 * scripts/uxn2-embed.c; other rows (macOS, older VMs) keep the stub.
 *
 * Output is a self-contained executable: the vendored uxn vm plus the
 * assembled ROM. Running it launches the ROM in the vm. Extra
 * arguments are passed to the vm before the ROM (e.g. ./game -2).
 * Requires sh, tar, mktemp, tail, chmod at runtime (present on Linux
 * and macOS); the payload VM itself is per-OS (see default_uxn2_path). *)

open Printf

let name = "native"

(* Host platform row: matches the vendor/ layout (see vendor/BUILD.md).
   Detected once via uname(1); Windows takes its row without asking.
   Unknown unixes fall back to the Linux row (today's behavior). *)
let host_row : string Lazy.t = lazy (
  match Sys.os_type with
  | "Win32" | "Cygwin" -> "windows-x86_64"
  | _ ->
    let uname arg =
      try
        let ic = Unix.open_process_in ("uname " ^ arg) in
        let s = try input_line ic with End_of_file -> "" in
        ignore (Unix.close_process_in ic);
        String.trim s
      with _ -> ""
    in
    (match uname "-s", uname "-m" with
    | "Darwin", ("arm64" | "aarch64") -> "macos-arm64"
    | "Darwin", _ -> "macos-x86_64"
    | ("Linux", ("aarch64" | "arm64")) -> "linux-aarch64"
    | _ -> "linux-x86_64")
)

(* Explicit bundle rows: the .rom is portable, only the VM half varies
   (see vendor/BUILD.md). `native` means the host row below; any other
   row can be bundled from any host — assembly still runs under the
   host VM, only the packaged binary comes from the target row. This is
   what lets one Linux backend serve all download options. *)
let known_rows = [
  "linux-x86_64";
  "linux-aarch64";
  "macos-arm64";
  "macos-x86_64";
  "windows-x86_64";
]

let is_windows_row row =
  row = "windows-x86_64"

let uxn_binary_name row =
  if is_windows_row row then "uxn2.exe" else "uxn2"

(* Resolve the vendored VM for an explicit row. The binary name is
   per-row (uxn2.exe on Windows); a legacy bare `uxn2` next to the
   row dir is also accepted so half-populated checkouts keep working.
   Missing rows fail naming the wanted path (backend maps this to a
   410/501 "target not vendored yet", not a crash). *)
let uxn2_path_for_row row =
  let names =
    if is_windows_row row then [ "uxn2.exe"; "uxn2" ]
    else [ "uxn2" ]
  in
  let candidates =
    List.concat_map (fun name ->
      List.map
        (fun v -> Filename.concat (Filename.concat v row) name)
        (Target.vendor_candidates ()))
      names
  in
  let rec find = function
    | [] ->
      failwith (Printf.sprintf
        "no vendored uxn2 for target `%s` (want vendor/%s/%s next to etal; see vendor/BUILD.md)"
        row row (uxn_binary_name row))
    | p :: ps -> if Sys.file_exists p then p else find ps
  in
  find candidates

(* Per-OS VM rows. The host row comes first; the Linux row stays as a
   legacy fallback (plus resolve_tool's checkout fallbacks), so older
   layouts keep working. *)
let default_uxn2_path () =
  let row = Lazy.force host_row in
  let in_row r =
    List.map
      (fun v -> Filename.concat (Filename.concat v r) "uxn2")
      (Target.vendor_candidates ())
  in
  let candidates =
    (try [uxn2_path_for_row row] with Failure _ -> [])
    @ (if row = "linux-x86_64" then [] else in_row "linux-x86_64")
    @ [Target.resolve_tool "uxn2"]
  in
  let rec find = function
    | [] -> uxn2_path_for_row row
    | p :: ps -> if Sys.file_exists p then p else find ps
  in
  find candidates

let default_drifblim_path () =
  let candidates =
    List.map
      (fun v -> Filename.concat (Filename.concat v "shared") "drifblim.rom")
      (Target.vendor_candidates ())
    @ [Target.resolve_tool "drifblim.rom"]
  in
  let rec find = function
    | [] -> Target.resolve_tool "drifblim.rom"
    | p :: ps -> if Sys.file_exists p then p else find ps
  in
  find candidates

(* uxn2's own command line is deliberately tiny: `-f` for fullscreen and
   `-2` for 2x. It has no -1 and no -3 (its in-app key cycles 1..3, but
   the CLI does not). So a whole-number scale maps like this:
 *
 *   1    -> no flag (1x)
 *   2    -> -2
 *   3    -> -2, and the in-app key reaches 3x from there
 *   fit  -> -2: the default, "as large as the display allows". uxn2
 *           cannot measure the display from its CLI, and a 1x window
 *           of a 256x192 game is tiny on any modern screen, while 2x
 *           of even 320x240 fits every display.
 *
 * `full` passes no scale flag (fullscreen is its own -f). *)
let vm_args (w : Target.window) =
  let args = ref [] in
  if w.fullscreen then args := "-f" :: !args;
  (match w.scale with
   | "2" | "3" | "fit" -> args := "-2" :: !args
   | _ -> ());
  List.rev !args

(* Self-extracting bundle stub. OFFSET is the byte length of the stub
   itself (including the marker line); the tar.gz payload follows.
   vm_args render bare: Filename.quote would write `-f` as `'-f'`,
   which the shell strips anyway but which reads like a mistake in a
   file people open and edit. Only the caller's own "$@" needs
   quoting, and that is already quoted in the stub. *)
let bundle_stub ~prog_name ~offset ~vm_args =
  let flags =
    match vm_args with
    | [] -> ""
    | args -> " " ^ String.concat " " args
  in
  sprintf {|#!/bin/sh
# ETAL bundle: %s - vendored uxn vm + rom. Executes the rom in the vm.
# Extra arguments are passed to the vm before the rom (e.g. ./%s -2).
OFFSET=%d
SELF="$0"
case "$SELF" in */*) ;; *) SELF="./$SELF";; esac
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/etal-run.XXXXXX") || exit 1
trap 'rm -rf "$TMPD"' EXIT INT TERM
tail -c +$((OFFSET + 1)) "$SELF" | tar -xzf - -C "$TMPD" || exit 1
chmod +x "$TMPD/uxn2"
# Preflight: the vendored vm links SDL2 dynamically. Fail with install
# help instead of a cryptic dynamic-linker error (`-v` only prints).
if ! "$TMPD/uxn2" -v >/dev/null 2>&1; then
  echo "etal bundle: the vendored uxn vm failed to start (SDL2 likely missing)." >&2
  echo "Install it, e.g.: sudo apt install libsdl2-2.0-0  # Ubuntu/Debian" >&2
  echo "  sudo pacman -S sdl2  # Arch | brew install sdl2  # macOS" >&2
  exit 1
fi
# Run as a child (not exec) so the EXIT trap cleans up $TMPD.
"$TMPD/uxn2"%s "$@" "$TMPD/game.rom"
rc=$?
exit $rc
__ETAL_PAYLOAD__
|} prog_name prog_name offset flags

let bundle ~verbose ~uxn2_path ~rom_path ~output_file ~window =
  let prog_name = Filename.basename output_file in
  (* Stage payload files under fixed names. *)
  let stage = Filename.temp_file "etal-stage" "" in
  Sys.remove stage;
  let rc_mkdir = Sys.command (sprintf "mkdir -p %s" (Filename.quote stage)) in
  if rc_mkdir <> 0 then (eprintf "Error: cannot create staging dir\n"; exit 1);
  (try
    Target.copy_file uxn2_path (Filename.concat stage "uxn2");
    Target.copy_file rom_path (Filename.concat stage "game.rom");
    let payload = Filename.temp_file "etal-payload" ".tgz" in
    (* Fixed mtimes + gzip -n keep same-machine bundles byte-identical.
       (Cross-builder uid/gid strings may still vary; see TARGET docs.) *)
    ignore (Sys.command (sprintf "touch -t 200001010000 %s %s"
      (Filename.quote (Filename.concat stage "uxn2"))
      (Filename.quote (Filename.concat stage "game.rom"))));
    let rc_tar = Sys.command (sprintf "tar --numeric-owner -cf - -C %s uxn2 game.rom | gzip -n > %s"
      (Filename.quote stage) (Filename.quote payload)) in
    if rc_tar <> 0 then (eprintf "Error: tar failed (is tar installed?)\n"; exit 1);
    let payload_bytes = Target.read_file_bin payload in
    (* Stub length depends on the offset digits; iterate once to fixpoint. *)
    let rec fix_stub guess =
      let stub = bundle_stub ~prog_name ~offset:guess ~vm_args:(vm_args window) in
      let actual = String.length stub in
      if actual = guess then stub else fix_stub actual
    in
    let stub = fix_stub 0 in
    if verbose then eprintf "Bundle stub is %d bytes, payload %d bytes\n"
      (String.length stub) (String.length payload_bytes);
    let oc = open_out_bin output_file in
    output_string oc stub;
    output_string oc payload_bytes;
    close_out oc;
    Sys.remove payload;
  with e ->
    ignore (Sys.command (sprintf "rm -rf %s" (Filename.quote stage)));
    raise e);
  ignore (Sys.command (sprintf "rm -rf %s" (Filename.quote stage)));
  let rc_chmod = Sys.command (sprintf "chmod +x %s" (Filename.quote output_file)) in
  if rc_chmod <> 0 then (eprintf "Error: chmod +x failed\n"; exit 1)

(* Windows carrier: one .exe. The vendored uxn2.exe is uxn2 built with
   scripts/uxn2-embed.c and a static SDL2 (scripts/build-uxn2-windows.sh),
   so it needs no DLL beside it and, when its own file ends in a
   footer, runs the ROM stored just before that footer:

     [uxn2.exe][game.rom]["ETALROM1"][u32 LE rom length][flags][0 0 0]

   flags: 1 = fullscreen, 2 = 2x window (the same choice vm_args makes
   for the unix rows). Windows ignores bytes after the PE image, so
   the result is an ordinary executable. *)
let embed_capable vm =
  (* The wrapper's explicit marker; older builds only show the footer
     magic (as a string literal, unless gcc folded the compare). *)
  let has m =
    let n = String.length vm and k = String.length m in
    let rec go i = i + k <= n && (String.sub vm i k = m || go (i + 1)) in
    go 0 in
  has "ETAL-EMBED-CAPABLE-1" || has "ETALROM1"

let bundle_embedded ~verbose ~row ~vm ~rom_path ~output_file ~window =
  let rom = Target.read_file_bin rom_path in
  let len = String.length rom in
  if len = 0 || len > 0x10000 then (eprintf "Error: ROM size %d does not fit a single-file bundle\n" len; exit 1);
  let args = vm_args window in
  let flags = (if List.mem "-f" args then 1 else 0) lor (if List.mem "-2" args then 2 else 0) in
  let footer = Bytes.make 16 '\000' in
  Bytes.blit_string "ETALROM1" 0 footer 0 8;
  Bytes.set footer 8 (Char.chr (len land 0xff));
  Bytes.set footer 9 (Char.chr ((len lsr 8) land 0xff));
  Bytes.set footer 10 (Char.chr ((len lsr 16) land 0xff));
  Bytes.set footer 11 (Char.chr ((len lsr 24) land 0xff));
  Bytes.set footer 12 (Char.chr flags);
  let oc = open_out_bin output_file in
  output_string oc vm;
  output_string oc rom;
  output_bytes oc footer;
  close_out oc;
  if not (is_windows_row row) then Unix.chmod output_file 0o755;
  if verbose then eprintf "Wrote single-file %s bundle to %s (%d + %d bytes)\n" row output_file (String.length vm) len

(* What --target <row> produces (for --list-targets): "exe" (Windows),
   "elf" (Linux with an embed-capable VM) or "sh+tar.gz" (the stub). *)
let carrier_of_row row =
  if is_windows_row row then "exe"
  else
    let linux = String.length row > 6 && String.sub row 0 6 = "linux-" in
    match uxn2_path_for_row row with
    | path when linux && embed_capable (Target.read_file_bin path) -> "elf"
    | _ -> "sh+tar.gz"
    | exception Failure _ -> "sh+tar.gz"

(* Bundle for an explicit row. Unix rows reuse the sh+tar.gz carrier
   with that row's VM; the Windows row uses the zip carrier. *)
let bundle_for_row ~verbose ~row ~rom_path ~output_file ~window =
  if not (List.mem row known_rows) then
    failwith (Printf.sprintf "unknown native row `%s` (want one of: %s)"
      row (String.concat ", " known_rows));
  let uxn2_path = uxn2_path_for_row row in
  if verbose then eprintf "Using uxn2 row %s: %s\n" row uxn2_path;
  let vm = Target.read_file_bin uxn2_path in
  let linux = String.length row > 6 && String.sub row 0 6 = "linux-" in
  if is_windows_row row then begin
    if not (embed_capable vm) then
      failwith (Printf.sprintf "%s: this uxn2.exe cannot carry a ROM (build it with scripts/build-uxn2-windows.sh)" uxn2_path);
    bundle_embedded ~verbose ~row ~vm ~rom_path ~output_file ~window
  end
  else if linux && embed_capable vm then
    bundle_embedded ~verbose ~row ~vm ~rom_path ~output_file ~window
  else
    (* macOS: appending to a signed Mach-O needs testing on a Mac
       (Gatekeeper); older VMs lack the wrapper. *)
    bundle ~verbose ~uxn2_path ~rom_path ~output_file ~window
