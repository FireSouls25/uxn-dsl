(* Main entry point for Etal compiler *)

open Printf

let usage = "Usage: etal [options] <input.ux>\n\nOptions:\n  -o <output>    Output file (default: input with .rom extension)\n  -t             Output Uxntal only (don't assemble to ROM)\n  -v             Verbose output\n  -h             Show this help\n"

let () =
  let input_file = ref None in
  let output_file = ref None in
  let emit_tal = ref false in
  let verbose = ref false in
  
  let speclist = [
    ("-o", Arg.String (fun s -> output_file := Some s), "Output file");
    ("-t", Arg.Unit (fun () -> emit_tal := true), "Output Uxntal only");
    ("-v", Arg.Unit (fun () -> verbose := true), "Verbose output");
  ] in
  
  Arg.parse speclist (fun s -> input_file := Some s) usage;
  
  let input_file = match !input_file with
    | Some f -> f
    | None -> eprintf "Error: No input file specified\n%s" usage; exit 1
  in
  
  let output_file = match !output_file with
    | Some f -> f
    | None ->
      let base = Filename.chop_extension input_file in
      if !emit_tal then base ^ ".tal"
      else base ^ ".rom"
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
    (* Token count of the top-level file only, for orientation *)
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
  if !verbose then begin
    eprintf "Generated %d bytes of Uxntal\n" (String.length tal_code);
    eprintf "Uxntal output:\n%s\n" tal_code
  end;
  
  (* Write output *)
  if !emit_tal then begin
    let oc = open_out output_file in
    output_string oc tal_code;
    close_out oc;
    if !verbose then eprintf "Wrote Uxntal to %s\n" output_file
  end else begin
    (* Write temporary .tal file in same dir as input for relative includes *)
    let input_dir = Filename.dirname input_file in
    let temp_file = Filename.temp_file ~temp_dir:input_dir "etal" ".tal" in
    let oc = open_out temp_file in
    output_string oc tal_code;
    close_out oc;
    
    (* Assemble with drifblim - resolve relative to project root *)
    let drifblim_path = 
      let base = Filename.dirname (Sys.executable_name) in
      (* base is src or src/bin, parent is src or project root *)
      let candidates = [
        Filename.concat base "drifblim.rom";
        Filename.concat (Filename.concat base "../uxn2/bin") "drifblim.rom";
        "uxn2/bin/drifblim.rom";
        Filename.concat (Filename.dirname base) "uxn2/bin/drifblim.rom";
      ] in
      let rec find = function
        | [] -> "uxn2/bin/drifblim.rom"
        | p::ps -> if Sys.file_exists p then p else find ps
      in
      find candidates
    in
    let uxn2_path =
      let base = Filename.dirname (Sys.executable_name) in
      let candidates = [
        Filename.concat base "uxn2";
        Filename.concat (Filename.concat base "../uxn2/bin") "uxn2";
        "uxn2/bin/uxn2";
        Filename.concat (Filename.dirname base) "uxn2/bin/uxn2";
      ] in
      let rec find = function
        | [] -> "uxn2/bin/uxn2"
        | p::ps -> if Sys.file_exists p then p else find ps
      in
      find candidates
    in
    
    if !verbose then begin
      eprintf "Using drifblim: %s\n" drifblim_path;
      eprintf "Using uxn2: %s\n" uxn2_path
    end;
    
    let cmd = sprintf "%s %s %s %s" uxn2_path drifblim_path temp_file output_file in
    if !verbose then eprintf "Running: %s\n" cmd;
    
    let ret = Sys.command cmd in
    if ret <> 0 then begin
      eprintf "Error: Assembly failed with code %d\n" ret;
      exit 1
    end;
    
    (* Clean up temp file *)
    Sys.remove temp_file;
    
    if !verbose then eprintf "Wrote ROM to %s\n" output_file
  end;
  
  printf "Success: %s -> %s\n" input_file output_file
