(* Main entry point for Etal compiler *)

open Printf

let usage = "Usage: etal [options] <input.ux>\n\nOptions:\n  -o <output>    Output file (default depends on mode)\n  -t             Output Uxntal source (.tal)\n  -r             Output assembled ROM (.rom)\n  --target <t>   Bundle target: native (default) or web (single .html)\n  -v             Verbose output\n  -h             Show this help\n\nWith neither -t nor -r, etal outputs a single self-contained\nbundle: the vendored uxn vm plus the assembled ROM (native), or\na playable web page with the vendored uxn5 emulator (--target web).\nExtra native-bundle arguments are passed to the vm\n(e.g. ./game -2 for 2x zoom).\n"

let () =
  let input_file = ref None in
  let output_file = ref None in
  let emit_tal = ref false in
  let emit_rom = ref false in
  let target = ref "native" in
  let verbose = ref false in

  let speclist = [
    ("-o", Arg.String (fun s -> output_file := Some s), "Output file");
    ("-t", Arg.Unit (fun () -> emit_tal := true), "Output Uxntal only");
    ("-r", Arg.Unit (fun () -> emit_rom := true), "Output ROM only");
    ("--target", Arg.String (fun s -> target := s), "Bundle target: native (default) or web");
    ("-v", Arg.Unit (fun () -> verbose := true), "Verbose output");
  ] in

  Arg.parse speclist (fun s -> input_file := Some s) usage;

  if !emit_tal && !emit_rom then begin
    eprintf "Error: -t and -r are mutually exclusive\n";
    exit 1
  end;

  let mode = if !emit_tal then `Tal else if !emit_rom then `Rom else `Bundle in

  let target =
    match !target with
    | "native" -> `Native
    | "web" -> `Web
    | s -> eprintf "Error: unknown --target `%s` (want native or web)\n" s; exit 1
  in

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
      | `Bundle -> (match target with `Native -> base | `Web -> base ^ ".html"))
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
    let ic = open_in_bin input_file in
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
    (* Binary mode: text mode would CRLF-translate on Windows and the
       golden .tal diff could never match. *)
    let oc = open_out_bin output_file in
    output_string oc tal_code;
    close_out oc;
    if !verbose then eprintf "Wrote Uxntal to %s\n" output_file
  | `Rom | `Bundle ->
    (* Write temporary .tal file in same dir as input for relative includes *)
    let input_dir = Filename.dirname input_file in
    let temp_tal = Filename.temp_file ~temp_dir:input_dir "etal" ".tal" in
    let oc = open_out_bin temp_tal in
    output_string oc tal_code;
    close_out oc;

    let drifblim_path = Target_native.default_drifblim_path () in
    let uxn2_path = Target_native.default_uxn2_path () in

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
      Target.copy_file temp_rom output_file;
      Sys.remove temp_rom;
      if !verbose then eprintf "Wrote ROM to %s\n" output_file
    | `Bundle ->
      (match target with
      | `Native ->
        Target_native.bundle ~verbose:!verbose ~uxn2_path ~rom_path:temp_rom ~output_file;
        Sys.remove temp_rom;
        if !verbose then eprintf "Wrote executable bundle to %s\n" output_file
      | `Web ->
        Target_web.bundle ~verbose:!verbose
          ~vendor_dir:(Target_web.default_uxn5_dir ())
          ~rom_path:temp_rom ~output_file;
        Sys.remove temp_rom)
    | `Tal -> assert false));

  printf "Success: %s -> %s\n" input_file output_file
