(* Native unix bundle backend: sh stub + tar.gz payload.
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

(* Per-OS VM rows. The host row comes first; the Linux row stays as a
   legacy fallback (plus resolve_tool's checkout fallbacks), so older
   layouts keep working. A missing host row fails with the expected
   path instead of a cryptic exec error. *)
let default_uxn2_path () =
  let row = Lazy.force host_row in
  let in_row r =
    List.map
      (fun v -> Filename.concat (Filename.concat v r) "uxn2")
      (Target.vendor_candidates ())
  in
  let candidates =
    in_row row
    @ (if row = "linux-x86_64" then [] else in_row "linux-x86_64")
    @ [Target.resolve_tool "uxn2"]
  in
  let rec find = function
    | [] ->
      if row = "linux-x86_64" then Target.resolve_tool "uxn2"
      else
        failwith (Printf.sprintf
          "no vendored uxn2 for this host (want vendor/%s/uxn2 next to etal; see vendor/BUILD.md)"
          row)
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

(* Self-extracting bundle stub. OFFSET is the byte length of the stub
   itself (including the marker line); the tar.gz payload follows. *)
let bundle_stub ~prog_name ~offset =
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
"$TMPD/uxn2" "$@" "$TMPD/game.rom"
rc=$?
exit $rc
__ETAL_PAYLOAD__
|} prog_name prog_name offset

let bundle ~verbose ~uxn2_path ~rom_path ~output_file =
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
      let stub = bundle_stub ~prog_name ~offset:guess in
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
