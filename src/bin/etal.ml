(* Main entry point for Etal compiler *)

open Printf

let usage = "Usage: etal [options] <input.ux>\n\nOptions:\n  -o <output>    Output file (default depends on mode)\n  -t             Output Uxntal source (.tal)\n  -r             Output assembled ROM (.rom)\n  -v             Verbose output\n  -h             Show this help\n\nWith neither -t nor -r, etal outputs a single self-contained\nexecutable: the vendored uxn vm plus the assembled ROM. Running\nit launches the ROM in the vm. Extra arguments are passed to the\nvm (e.g. ./game -2 for 2x zoom).\n"

(* Resolve a vendored/dev tool path. Prefers the vendor/ directory next
   to the etal executable, falls back to the uxn2 checkout. *)
let resolve_tool filename =
  let exe_dir = Filename.dirname Sys.executable_name in
  let candidates = [
    Filename.concat (Filename.concat exe_dir "vendor") filename;
    Filename.concat exe_dir filename;
    Filename.concat (Filename.concat exe_dir "../uxn2/bin") filename;
    Filename.concat "uxn2/bin" filename;
    Filename.concat (Filename.dirname exe_dir) (Filename.concat "uxn2/bin" filename);
  ] in
  let rec find = function
    | [] -> Filename.concat "uxn2/bin" filename
    | p :: ps -> if Sys.file_exists p then p else find ps
  in
  find candidates

let copy_file src dst =
  let ic = open_in_bin src in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  let oc = open_out_bin dst in
  output_string oc s;
  close_out oc

let read_file_bin path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

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

let build_bundle ~verbose ~uxn2_path ~rom_path ~output_file =
  let prog_name = Filename.basename output_file in
  (* Stage payload files under fixed names. *)
  let stage = Filename.temp_file "etal-stage" "" in
  Sys.remove stage;
  let rc_mkdir = Sys.command (sprintf "mkdir -p %s" (Filename.quote stage)) in
  if rc_mkdir <> 0 then (eprintf "Error: cannot create staging dir\n"; exit 1);
  (try
    copy_file uxn2_path (Filename.concat stage "uxn2");
    copy_file rom_path (Filename.concat stage "game.rom");
    let payload = Filename.temp_file "etal-payload" ".tgz" in
    let rc_tar = Sys.command (sprintf "tar -czf %s -C %s uxn2 game.rom"
      (Filename.quote payload) (Filename.quote stage)) in
    if rc_tar <> 0 then (eprintf "Error: tar failed (is tar installed?)\n"; exit 1);
    let payload_bytes = read_file_bin payload in
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

let () =
  let input_file = ref None in
  let output_file = ref None in
  let emit_tal = ref false in
  let emit_rom = ref false in
  let verbose = ref false in

  let speclist = [
    ("-o", Arg.String (fun s -> output_file := Some s), "Output file");
    ("-t", Arg.Unit (fun () -> emit_tal := true), "Output Uxntal only");
    ("-r", Arg.Unit (fun () -> emit_rom := true), "Output ROM only");
    ("-v", Arg.Unit (fun () -> verbose := true), "Verbose output");
  ] in

  Arg.parse speclist (fun s -> input_file := Some s) usage;

  if !emit_tal && !emit_rom then begin
    eprintf "Error: -t and -r are mutually exclusive\n";
    exit 1
  end;

  let mode = if !emit_tal then `Tal else if !emit_rom then `Rom else `Bundle in

  let input_file = match !input_file with
    | Some f -> f
    | None -> eprintf "Error: No input file specified\n%s" usage; exit 1
  in

  let output_file = match !output_file with
    | Some f -> f
    | None ->
      let base = Filename.chop_extension input_file in
      (match mode with
      | `Tal -> base ^ ".tal"
      | `Rom -> base ^ ".rom"
      | `Bundle -> base)
  in

  if !verbose then eprintf "Compiling %s to %s\n" input_file output_file;

  (* Load with import resolution (recursive, file-relative) *)
  let program = Loader.load_program input_file in
  if !verbose then
    eprintf "Loaded %d declarations (imports resolved)\n" (List.length program);

  (* Expand macros inline *)
  let program = Expand.expand_program program in
  if !verbose then begin
    eprintf "Expanded to %d declarations\n" (List.length program);
    let ic = open_in input_file in
    let source = really_input_string ic (in_channel_length ic) in
    close_in ic;
    eprintf "Top-level file tokenized to %d tokens\n"
      (List.length (Lexer.tokenize source))
  end;

  (* Type checking *)
  let _env = Types.type_check_program program in
  if !verbose then
    eprintf "Type checking passed\n";

  (* Code generation *)
  let tal_code = Codegen.codegen_program program in
  if !verbose then
    eprintf "Generated %d bytes of Uxntal\n" (String.length tal_code);

  (* Write output *)
  (match mode with
  | `Tal ->
    let oc = open_out output_file in
    output_string oc tal_code;
    close_out oc;
    if !verbose then eprintf "Wrote Uxntal to %s\n" output_file
  | `Rom | `Bundle ->
    (* Write temporary .tal file in same dir as input for relative includes *)
    let input_dir = Filename.dirname input_file in
    let temp_tal = Filename.temp_file ~temp_dir:input_dir "etal" ".tal" in
    let oc = open_out temp_tal in
    output_string oc tal_code;
    close_out oc;

    let drifblim_path = resolve_tool "drifblim.rom" in
    let uxn2_path = resolve_tool "uxn2" in

    if !verbose then begin
      eprintf "Using drifblim: %s\n" drifblim_path;
      eprintf "Using uxn2: %s\n" uxn2_path
    end;

    let temp_rom = Filename.temp_file ~temp_dir:input_dir "etal" ".rom" in
    let cmd = sprintf "%s %s %s %s"
      (Filename.quote uxn2_path) (Filename.quote drifblim_path)
      (Filename.quote temp_tal) (Filename.quote temp_rom) in
    if !verbose then eprintf "Running: %s\n" cmd;

    let ret = Sys.command cmd in
    Sys.remove temp_tal;
    if ret <> 0 then begin
      (try Sys.remove temp_rom with _ -> ());
      eprintf "Error: Assembly failed with code %d\n" ret;
      exit 1
    end;

    (match mode with
    | `Rom ->
      copy_file temp_rom output_file;
      Sys.remove temp_rom;
      if !verbose then eprintf "Wrote ROM to %s\n" output_file
    | `Bundle ->
      build_bundle ~verbose:!verbose ~uxn2_path ~rom_path:temp_rom ~output_file;
      Sys.remove temp_rom;
      if !verbose then eprintf "Wrote executable bundle to %s\n" output_file
    | `Tal -> assert false));

  printf "Success: %s -> %s\n" input_file output_file
