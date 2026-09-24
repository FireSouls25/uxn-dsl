(* Import resolution for Etal.
 *
 * `import "path"` splices the target file's declarations in order at
 * the import site. Paths resolve relative to the importing file's
 * directory (unlike drifblim's CWD-relative `~` includes).
 * Imports are recursive; each file is included once (diamond imports
 * are fine); cyclic imports and missing files are errors, as are
 * duplicate top-level definitions across the splice. *)

open Ast

(* Path handling is deliberately OS-independent pure string logic over
   forward slashes: the same .ux project must resolve identically on
   Linux/macOS/Windows, and unit tests must be able to feed Windows
   paths on any host. Backslashes count as separators (Windows), and
   `X:/` drive prefixes are roots that `..` cannot escape. In
   particular this module must NOT use Filename (OS-dependent). *)

let to_forward p =
  String.map (fun c -> if c = '\\' then '/' else c) p

let is_alpha c =
  ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z')

(* Split "D:/a/b" -> ("D:", "/a/b"); "D:rel" -> ("D:", "rel");
   anything else -> ("", whole). The drive letter is upcased so the
   visited set is stable on case-insensitive filesystems. *)
let split_drive p =
  if String.length p >= 2 && is_alpha p.[0] && p.[1] = ':' then
    (String.make 1 (Char.uppercase_ascii p.[0]) ^ ":",
     String.sub p 2 (String.length p - 2))
  else ("", p)

let is_absolute_path p =
  let drive, rest = split_drive (to_forward p) in
  drive <> "" ||
  (String.length rest > 0 && rest.[0] = '/')

(* Minimal normalization (no symlink resolution): collapse ".",
   duplicate slashes; resolve ".." without escaping an absolute root;
   preserve leading ".." on relative paths. *)
let normalize_path path =
  let drive, rest = split_drive (to_forward path) in
  let unc =
    drive = "" && String.length rest >= 2
    && rest.[0] = '/' && rest.[1] = '/'
  in
  let absolute = drive <> "" || unc ||
    (String.length rest > 0 && rest.[0] = '/') in
  let parts = String.split_on_char '/' rest in
  let rec go acc = function
    | [] -> List.rev acc
    | ("" | ".") :: tl -> go acc tl
    | ".." :: tl ->
      (match acc with
       | [] | ".." :: _ ->
         if absolute then go acc tl else go (".." :: acc) tl
       | _ :: tl2 -> go tl2 tl)
    | x :: tl -> go (x :: acc) tl
  in
  let norm = String.concat "/" (go [] parts) in
  if drive <> "" then
    if norm = "" then drive ^ "/" else drive ^ "/" ^ norm
  else if unc then "//" ^ norm
  else if absolute then "/" ^ norm
  else if norm = "" then "." else norm

let dirname_fwd p =
  let p = to_forward p in
  try String.sub p 0 (String.rindex p '/')
  with Not_found -> "."

let concat_fwd base p =
  if is_absolute_path p then normalize_path p
  else
    let b = to_forward base in
    let b =
      if b = "" then "/"
      else if b.[String.length b - 1] = '/' then
        String.sub b 0 (String.length b - 1)
      else b
    in
    normalize_path (b ^ "/" ^ p)

let absolutize path =
  let p = to_forward path in
  if is_absolute_path p then normalize_path p
  else normalize_path (concat_fwd (to_forward (Sys.getcwd ())) p)

let read_source path importer =
  try
    (* Binary mode: on Windows, text mode would CRLF-translate and
       break the length-prefixed read below. The lexer treats \r as
       whitespace, so CRLF sources lex identically. *)
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    s
  with Sys_error msg ->
    failwith (Printf.sprintf "cannot read `%s` (imported from `%s`): %s" path importer msg)

let load_program entry =
  let entry = normalize_path (absolutize entry) in
  let defined : (string, string) Hashtbl.t = Hashtbl.create 64 in
  let defpos : (string, Token.pos) Hashtbl.t = Hashtbl.create 64 in
  let locs = ref [] in
  let loaded = ref [] in
  let check_dup d path dpos =
    match decl_name d with
    | Some (kind, n) ->
      if Hashtbl.mem defined n then
        failwith (Printf.sprintf
          "duplicate definition of %s `%s` (%s, now %s)"
          kind n
          (Token.string_of_pos (Hashtbl.find defpos n))
          (Token.string_of_pos dpos))
      else begin
        Hashtbl.add defined n path;
        Hashtbl.add defpos n dpos
      end
    | None -> ()
  in
  let rec load path importer visited =
    if List.mem path visited then
      failwith (Printf.sprintf "cyclic import involving `%s`" path);
    if List.mem path !loaded then
      []
    else begin
      loaded := path :: !loaded;
      let source = read_source path importer in
      let tokens, poss = Lexer.tokenize_locd ~file:path source in
      let decls, dlocs = Parser.parse_locd ~file:path tokens poss in
      let here n =
        try List.assoc n dlocs with Not_found -> Token.nopos in
      locs := dlocs @ !locs;
      List.concat_map (function
        | ImportDecl { path = p } ->
          let base = dirname_fwd path in
          let target =
            if is_absolute_path p then normalize_path p
            else normalize_path (concat_fwd base p)
          in
          load target path (path :: visited)
        | AssetDecl a ->
          (* Resolve asset paths against the file declaring them,
             so codegen (which runs after splicing) needs no context. *)
          let fixed =
            if is_absolute_path a.asset_path then a
            else { a with asset_path =
              normalize_path (concat_fwd (dirname_fwd path) a.asset_path) }
          in
          check_dup (AssetDecl fixed) path (here a.asset_name);
          [AssetDecl fixed]
        | d ->
          let n = match decl_name d with Some (_, n) -> n | None -> "" in
          check_dup d path (here n);
          [d]
      ) decls
    end
  in
  let program = load entry entry [] in
  (program, !locs)
