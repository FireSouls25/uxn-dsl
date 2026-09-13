(* Dead-function elimination for Etal.
 *
 * Every compiled FuncDecl permanently reserves zero-page slots for
 * its params and locals — importing a library would otherwise budget
 * all of them, used or not, against the 256-byte limit. This pass
 * keeps the functions reachable from the entry point and drops the
 * rest, after checking (so even unused code must type-check — typos
 * fail loudly) and before codegen (so pruned slots are never
 * allocated). Expansion+elaboration already ran, so macro-generated
 * calls and inferred declarations are concrete.
 *
 * Roots: `main` (the fixed `;main JSR2` entry) plus every AddrOf
 * target (event vectors and data addresses ride references, not
 * calls). Reachability follows Ident calls transitively to a
 * fixpoint. Only FuncDecl is pruned — globals/buffers/devices may
 * back vector tables and registration order matters.
 *
 * Escape hatch: any raw node (RawDecl/RawStmt/RawLit) disables the
 * pass entirely, since raw text may reference any label. *)

open Ast

let rec called_in_expr acc = function
  | Call (Ident f, args) ->
    List.fold_left called_in_expr (f :: acc) args
  | Call (f, args) ->
    List.fold_left called_in_expr acc (f :: args)
  | BinOp (_, l, r) -> called_in_expr (called_in_expr acc l) r
  | UnOp (_, e) -> called_in_expr acc e
  | Index (a, i) -> called_in_expr (called_in_expr acc a) i
  | Field (e, _) -> called_in_expr acc e
  | Assign (l, r) -> called_in_expr (called_in_expr acc l) r
  | CompoundLit (_, fs) -> List.fold_left called_in_expr acc fs
  | _ -> acc

let rec addrs_in_expr acc = function
  | AddrOf n -> n :: acc
  | Call (f, args) -> List.fold_left addrs_in_expr acc (f :: args)
  | BinOp (_, l, r) -> addrs_in_expr (addrs_in_expr acc l) r
  | UnOp (_, e) -> addrs_in_expr acc e
  | Index (a, i) -> addrs_in_expr (addrs_in_expr acc a) i
  | Field (e, _) -> addrs_in_expr acc e
  | Assign (l, r) -> addrs_in_expr (addrs_in_expr acc l) r
  | CompoundLit (_, fs) -> List.fold_left addrs_in_expr acc fs
  | _ -> acc

let rec called_in_stmt (acc : string list) : stmt -> string list = function
  | ExprStmt e | Return (Some e) | RPush e -> called_in_expr acc e
  | Return None | BrkStmt | Goto _ | Label _ | RPop | RPeek | RawStmt _ -> acc
  | If (c, t, elifs, e) ->
    let acc = called_in_expr acc c in
    let acc = called_in_stmts acc t in
    let rec loop acc = function
      | [] -> acc
      | (cond, body) :: rest ->
        loop (called_in_stmts (called_in_expr acc cond) body) rest
    in
    let acc = loop acc elifs in
    called_in_stmts acc e
  | While (c, b) -> called_in_stmts (called_in_expr acc c) b
  | For (_, s, e, b) ->
    called_in_stmts (called_in_expr (called_in_expr acc s) e) b
  | Block ss -> called_in_stmts acc ss
  | VarDecl (_, _, Some e) -> called_in_expr acc e
  | ConstDecl (_, _, e) -> called_in_expr acc e
  | VarDecl (_, _, None) -> acc
  | InferDecl (_, e) -> called_in_expr acc e
  | Match _ -> failwith "internal error: unexpanded match reached DCE"

and called_in_stmts (acc : string list) (ss : stmt list) : string list =
  List.fold_left called_in_stmt acc ss

let rec addrs_in_stmt acc = function
  | ExprStmt e | Return (Some e) | RPush e -> addrs_in_expr acc e
  | Return None | BrkStmt | Goto _ | Label _ | RPop | RPeek | RawStmt _ -> acc
  | If (c, t, elifs, e) ->
    let acc = addrs_in_expr acc c in
    let acc = addrs_in_stmts acc t in
    let acc = List.fold_left (fun a (c, b) -> addrs_in_stmts (addrs_in_expr a c) b) acc elifs in
    addrs_in_stmts acc e
  | While (c, b) -> addrs_in_stmts (addrs_in_expr acc c) b
  | For (_, s, e, b) ->
    addrs_in_stmts (addrs_in_expr (addrs_in_expr acc s) e) b
  | Block ss -> addrs_in_stmts acc ss
  | VarDecl (_, _, Some e) -> addrs_in_expr acc e
  | ConstDecl (_, _, e) -> addrs_in_expr acc e
  | VarDecl (_, _, None) -> acc
  | InferDecl (_, e) -> addrs_in_expr acc e
  | Match _ -> failwith "internal error: unexpanded match reached DCE"

and addrs_in_stmts acc ss = List.fold_left addrs_in_stmt acc ss

let rec has_raw_expr = function
  | RawLit _ -> true
  | Call (f, args) -> List.exists has_raw_expr (f :: args)
  | BinOp (_, l, r) -> has_raw_expr l || has_raw_expr r
  | UnOp (_, e) -> has_raw_expr e
  | Index (a, i) -> has_raw_expr a || has_raw_expr i
  | Field (e, _) -> has_raw_expr e
  | Assign (l, r) -> has_raw_expr l || has_raw_expr r
  | CompoundLit (_, fs) -> List.exists has_raw_expr fs
  | _ -> false

let rec has_raw_stmt = function
  | RawStmt _ -> true
  | ExprStmt e | Return (Some e) | RPush e -> has_raw_expr e
  | If (c, t, elifs, e) ->
    has_raw_expr c || List.exists has_raw_stmt t
    || List.exists (fun (c, b) -> has_raw_expr c || List.exists has_raw_stmt b) elifs
    || List.exists has_raw_stmt e
  | While (c, b) -> has_raw_expr c || List.exists has_raw_stmt b
  | For (_, s, e, b) ->
    has_raw_expr s || has_raw_expr e || List.exists has_raw_stmt b
  | Block ss -> List.exists has_raw_stmt ss
  | VarDecl (_, _, Some e) -> has_raw_expr e
  | ConstDecl (_, _, e) -> has_raw_expr e
  | VarDecl (_, _, None) -> false
  | InferDecl (_, e) -> has_raw_expr e
  | _ -> false

let has_raw program =
  List.exists (function
    | RawDecl _ -> true
    | FuncDecl f -> List.exists has_raw_stmt f.body
    | MacroDecl m -> List.exists has_raw_stmt m.macro_body
    | GlobalVarDecl (_, _, Some e) -> has_raw_expr e
    | GlobalConstDecl (_, _, e) -> has_raw_expr e
    | GlobalVarDecl (_, _, None) -> false
    | GlobalInferDecl (_, e) -> has_raw_expr e
    | _ -> false
  ) program

let eliminate program =
  if has_raw program then program
  else begin
    let funcs = Hashtbl.create 32 in
    List.iter (function
      | FuncDecl f -> Hashtbl.replace funcs f.name f
      | _ -> ()) program;
    (* Roots: entry point plus every address-taken name. *)
    let roots = ref ["main"] in
    let add_addrs_in_decl = function
      | FuncDecl f ->
        roots := addrs_in_stmts !roots f.body
      | GlobalVarDecl (_, _, Some e) -> roots := addrs_in_expr !roots e
      | GlobalConstDecl (_, _, e) -> roots := addrs_in_expr !roots e
      | GlobalVarDecl (_, _, None) -> ()
      | GlobalInferDecl (_, e) -> roots := addrs_in_expr !roots e
      | _ -> ()
    in
    List.iter add_addrs_in_decl program;
    (* Transitive call closure to a fixpoint. *)
    let seen = Hashtbl.create 32 in
    let rec visit name =
      if not (Hashtbl.mem seen name) then begin
        Hashtbl.add seen name ();
        match Hashtbl.find_opt funcs name with
        | Some f -> List.iter (fun c -> visit c) (called_in_stmts [] f.body)
        | None -> ()
      end
    in
    List.iter visit !roots;
    List.filter (function
      | FuncDecl f -> Hashtbl.mem seen f.name
      | _ -> true
    ) program
  end
