(* Native unix bundle backend: sh stub + tar.gz payload.
 *
 * Output is a self-contained executable: the vendored uxn vm plus the
 * assembled ROM. Running it launches the ROM in the vm. Extra
 * arguments are passed to the vm before the ROM (e.g. ./game -2).
 * Requires sh, tar, mktemp, tail, chmod at runtime (present on Linux
 * and macOS); the payload VM itself is per-OS (see default_uxn2_path). *)

open Printf

let name = "native"

let default_uxn2_path () = Target.resolve_tool "uxn2"

let default_drifblim_path () = Target.resolve_tool "drifblim.rom"

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
