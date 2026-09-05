(* Import resolution for Etal.
 *
 * `import "path"` splices the target file's declarations in order at
 * the import site. Paths resolve relative to the importing file's
 * directory (unlike drifblim's CWD-relative `~` includes).
 * Imports are recursive; each file is included once (diamond imports
 * are fine); cyclic imports and missing files are errors, as are
 * duplicate top-level definitions across the splice. *)

open Ast

let decl_name = function
  | FuncDecl f -> Some ("function", f.name)
  | MacroDecl m -> Some ("macro", m.macro_name)
  | GlobalVarDecl (n, _, _) -> Some ("global", n)
  | GlobalConstDecl (n, _) -> Some ("constant", n)
  | DeviceDecl d -> Some ("device", d.device_name)
  | GroupDecl g -> Some ("group", g.group_name)
  | DataDecl d -> Some ("data", d.data_name)
  | ImportDecl _ | RawDecl _ -> None

(* Minimal path normalization (no symlink resolution): collapse
   ".", ".." and duplicate slashes so the visited set is stable. *)
let normalize path =
  let is_abs = not (Filename.is_relative path) in
  let parts = String.split_on_char '/' path in
  let rec go acc = function
    | [] -> List.rev acc
    | ("" | ".") :: rest -> go acc rest
    | ".." :: rest ->
      (match acc with _ :: tl -> go tl rest | [] -> go [] rest)
    | p :: rest -> go (p :: acc) rest
  in
  let norm = String.concat "/" (go [] parts) in
  if is_abs then "/" ^ norm else norm

let absolutize path =
  if Filename.is_relative path then
    Filename.concat (Sys.getcwd ()) path
  else path

let read_source path importer =
  try
    let ic = open_in path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    s
  with Sys_error msg ->
    failwith (Printf.sprintf "cannot read `%s` (imported from `%s`): %s" path importer msg)

let load_program entry =
  let entry = normalize (absolutize entry) in
  let defined : (string, string) Hashtbl.t = Hashtbl.create 64 in
  let loaded = ref [] in
  let rec load path importer visited =
    if List.mem path visited then
      failwith (Printf.sprintf "cyclic import involving `%s`" path);
    if List.mem path !loaded then
      []
    else begin
      loaded := path :: !loaded;
      let source = read_source path importer in
      let decls = Parser.parse (Lexer.tokenize source) in
      List.concat_map (function
        | ImportDecl { path = p } ->
          let base = Filename.dirname path in
          let target = normalize
            (if Filename.is_relative p then Filename.concat base p else p) in
          load target path (path :: visited)
        | d ->
          (match decl_name d with
          | Some (kind, n) ->
            if Hashtbl.mem defined n then
              failwith (Printf.sprintf
                "duplicate definition of %s `%s` (also defined in `%s`, now in `%s`)"
                kind n (Hashtbl.find defined n) path)
            else Hashtbl.add defined n path
          | None -> ());
          [d]
      ) decls
    end
  in
  load entry entry []
