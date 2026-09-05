(* Macro expansion for Etal.
 *
 * Macros are expanded inline at each call site BEFORE type checking:
 * - expression position: the body must be exactly one `return <expr>`;
 *   the call is replaced by that expression.
 * - statement position (`name(...);`): the body statements are spliced
 *   inline. A `return <expr>;` inside becomes an expression statement
 *   (value discarded); a bare `return;` becomes an early return from
 *   the enclosing function.
 * Unlike a func (JSR2 call), expansion costs no jump/return.
 *
 * Hygiene: labels/gotos and macro-local bindings (let/const/for-var)
 * are freshened per expansion, so double expansion in one function
 * cannot collide. Bodies may reference parameters, globals, and their
 * own locals — but not the caller's locals.
 *
 * Recursive macro calls (direct or indirect) are rejected. *)

open Ast

type macro = {
  m_params : param list;
  m_return : typ option;
  m_body : stmt list;
}

let counter = ref 0

(* Names bound inside a body: locals plus labels. *)
let bound_names body =
  let names = ref [] in
  let add n = names := n :: !names in
  let rec stmt = function
    | VarDecl (n, _, _) -> add n
    | ConstDecl (n, _) -> add n
    | If (_, t, elifs, e) ->
      List.iter stmt t;
      List.iter (fun (_, b) -> List.iter stmt b) elifs;
      List.iter stmt e
    | While (_, b) -> List.iter stmt b
    | For (v, _, _, b) -> add v; List.iter stmt b
    | Block ss -> List.iter stmt ss
    | Label n -> add n
    | _ -> ()
  in
  List.iter stmt body;
  List.sort_uniq String.compare !names

let rename_of bound id =
  List.map (fun n -> (n, n ^ "__m" ^ string_of_int id)) bound

let rename_var rename n =
  try List.assoc n rename with Not_found -> n

let rec subst_expr psubst rename = function
  | Ident n as e ->
    (try List.assoc n psubst
     with Not_found ->
       (try Ident (List.assoc n rename) with Not_found -> e))
  | AddrOf n as e ->
    (try AddrOf (List.assoc n rename) with Not_found -> e)
  | BinOp (op, l, r) -> BinOp (op, subst_expr psubst rename l, subst_expr psubst rename r)
  | UnOp (op, e) -> UnOp (op, subst_expr psubst rename e)
  | Call (f, args) ->
    Call (subst_expr psubst rename f, List.map (subst_expr psubst rename) args)
  | Index (a, i) -> Index (subst_expr psubst rename a, subst_expr psubst rename i)
  | Field (e, f) -> Field (subst_expr psubst rename e, f)
  | Assign (l, r) -> Assign (subst_expr psubst rename l, subst_expr psubst rename r)
  | CompoundLit (n, fs) -> CompoundLit (n, List.map (subst_expr psubst rename) fs)
  | (IntLit _ | StringLit _ | RawLit _) as e -> e

let opt_subst psubst rename = function
  | None -> None
  | Some e -> Some (subst_expr psubst rename e)

let rec subst_stmt psubst rename = function
  | ExprStmt e -> ExprStmt (subst_expr psubst rename e)
  | Return e -> Return (opt_subst psubst rename e)
  | If (c, t, elifs, e) ->
    If (subst_expr psubst rename c,
        List.map (subst_stmt psubst rename) t,
        List.map (fun (c, b) -> (subst_expr psubst rename c, List.map (subst_stmt psubst rename) b)) elifs,
        List.map (subst_stmt psubst rename) e)
  | While (c, b) -> While (subst_expr psubst rename c, List.map (subst_stmt psubst rename) b)
  | For (v, s, e, b) ->
    For (rename_var rename v,
         subst_expr psubst rename s, subst_expr psubst rename e,
         List.map (subst_stmt psubst rename) b)
  | Block ss -> Block (List.map (subst_stmt psubst rename) ss)
  | VarDecl (n, t, i) -> VarDecl (rename_var rename n, t, opt_subst psubst rename i)
  | ConstDecl (n, e) -> ConstDecl (rename_var rename n, subst_expr psubst rename e)
  | Goto n -> Goto (rename_var rename n)
  | Label n -> Label (rename_var rename n)
  | RPush e -> RPush (subst_expr psubst rename e)
  | (RPop | RPeek | BrkStmt | RawStmt _) as s -> s

let lookup_macro macros m =
  try Some (List.assoc m macros) with Not_found -> None

let check_arity m (mac : macro) args =
  if List.length args <> List.length mac.m_params then
    failwith (Printf.sprintf "macro `%s` expects %d arguments, got %d"
      m (List.length mac.m_params) (List.length args))

(* Substitute params, freshen bound names, then expand nested calls. *)
let rec expand_body macros guard m (mac : macro) args =
  incr counter;
  let id = !counter in
  let pnames = List.map (fun (p : param) -> p.name) mac.m_params in
  let psubst = List.combine pnames args in
  let rename = rename_of (bound_names mac.m_body) id in
  let body = List.map (subst_stmt psubst rename) mac.m_body in
  expand_stmts macros (m :: guard) body

and expand_expr macros guard = function
  | Call (Ident m, args) as e ->
    (match lookup_macro macros m with
    | None ->
      (match e with
      | Call (f, a) -> Call (expand_expr macros guard f, List.map (expand_expr macros guard) a)
      | _ -> assert false)
    | Some mac ->
      if List.mem m guard then
        failwith (Printf.sprintf "recursive macro call to `%s`" m);
      check_arity m mac args;
      let args' = List.map (expand_expr macros guard) args in
      (match expand_body macros guard m mac args' with
      | [Return (Some r)] -> r
      | _ ->
        failwith (Printf.sprintf
          "macro `%s` used as an expression but its body is not a single return; call it as a statement" m)))
  | Call (f, args) -> Call (expand_expr macros guard f, List.map (expand_expr macros guard) args)
  | BinOp (op, l, r) -> BinOp (op, expand_expr macros guard l, expand_expr macros guard r)
  | UnOp (op, e) -> UnOp (op, expand_expr macros guard e)
  | Index (a, i) -> Index (expand_expr macros guard a, expand_expr macros guard i)
  | Field (e, f) -> Field (expand_expr macros guard e, f)
  | Assign (l, r) -> Assign (expand_expr macros guard l, expand_expr macros guard r)
  | CompoundLit (n, fs) -> CompoundLit (n, List.map (expand_expr macros guard) fs)
  | (Ident _ | IntLit _ | StringLit _ | AddrOf _ | RawLit _) as e -> e

and expand_stmt macros guard = function
  | ExprStmt (Call (Ident m, args)) when lookup_macro macros m <> None ->
    let mac = match lookup_macro macros m with Some x -> x | None -> assert false in
    if List.mem m guard then
      failwith (Printf.sprintf "recursive macro call to `%s`" m);
    check_arity m mac args;
    let args' = List.map (expand_expr macros guard) args in
    List.map (function
      | Return (Some e) -> ExprStmt e
      | Return None -> Return None
      | s -> s
    ) (expand_body macros guard m mac args')
  | ExprStmt e -> [ExprStmt (expand_expr macros guard e)]
  | Return e -> [Return (opt_expand macros guard e)]
  | If (c, t, elifs, e) ->
    [If (expand_expr macros guard c,
         expand_stmts macros guard t,
         List.map (fun (c, b) -> (expand_expr macros guard c, expand_stmts macros guard b)) elifs,
         expand_stmts macros guard e)]
  | While (c, b) -> [While (expand_expr macros guard c, expand_stmts macros guard b)]
  | For (v, s, e, b) ->
    [For (v, expand_expr macros guard s, expand_expr macros guard e, expand_stmts macros guard b)]
  | Block ss -> [Block (expand_stmts macros guard ss)]
  | VarDecl (n, t, i) -> [VarDecl (n, t, opt_expand macros guard i)]
  | ConstDecl (n, e) -> [ConstDecl (n, expand_expr macros guard e)]
  | RPush e -> [RPush (expand_expr macros guard e)]
  | (Goto _ | Label _ | RPop | RPeek | BrkStmt | RawStmt _) as s -> [s]

and opt_expand macros guard = function
  | None -> None
  | Some e -> Some (expand_expr macros guard e)

and expand_stmts macros guard stmts =
  List.concat_map (expand_stmt macros guard) stmts

let expand_program program =
  counter := 0;
  let macros = ref [] in
  List.iter (function
    | MacroDecl m ->
      if List.mem_assoc m.macro_name !macros then
        failwith (Printf.sprintf "duplicate macro `%s`" m.macro_name);
      macros := (m.macro_name,
        { m_params = m.macro_params; m_return = m.macro_return; m_body = m.macro_body }) :: !macros
    | _ -> ()
  ) program;
  let macros = !macros in
  List.concat_map (function
    | MacroDecl _ -> []
    | FuncDecl f -> [FuncDecl { f with body = expand_stmts macros [] f.body }]
    | GlobalVarDecl (n, t, i) -> [GlobalVarDecl (n, t, opt_expand macros [] i)]
    | GlobalConstDecl (n, e) -> [GlobalConstDecl (n, expand_expr macros [] e)]
    | d -> [d]
  ) program
