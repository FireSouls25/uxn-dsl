(* Type checker for Etal *)

open Ast

type type_env = {
  mutable vars: (string * typ) list;
  mutable funcs: (string * (param list * typ option)) list;
  mutable devices: (string * (string * typ) list) list;
  mutable groups: (string * (string * typ) list) list;
  (* Structs: name -> [(field, type)]; offsets derive from sizes. *)
  mutable structs: (string * (string * typ) list) list;
  (* Names bound by `::` / `: t :` at the same env level as vars, so a
     mutable shadowing declaration wins over an outer constant. *)
  mutable consts: string list;
  parent: type_env option;
}

let create_env parent = {
  vars = [];
  funcs = [];
  devices = [];
  groups = [];
  structs = [];
  consts = [];
  parent;
}

let lookup_var env name =
  let rec find env =
    try Some (List.assoc name env.vars)
    with Not_found ->
      match env.parent with
      | Some parent -> find parent
      | None -> None
  in
  find env

let add_var env name typ =
  env.vars <- (name, typ) :: env.vars

let add_const env name =
  env.consts <- name :: env.consts

(* Is the visible binding of `name` a constant? Resolves alongside the
   var chain so a mutable shadowing declaration wins. *)
let rec resolve_const env name =
  if List.mem_assoc name env.vars then
    Some (List.mem name env.consts)
  else
    match env.parent with
    | Some parent -> resolve_const parent name
    | None -> None

(* Modular-integer helpers. *)
let rec mod_base = function
  | TypMod (b, _) -> mod_base b
  | t -> t

let mod_modulus = function
  | TypMod (_, m) -> Some m
  | _ -> None

let add_struct env name fields =
  env.structs <- (name, fields) :: env.structs

let rec lookup_struct env name =
  try Some (List.assoc name env.structs)
  with Not_found ->
    (match env.parent with
    | Some p -> lookup_struct p name
    | None -> None)

let lookup_struct_field env sname fname =
  match lookup_struct env sname with
  | Some fields ->
    (try Some (List.assoc fname fields) with Not_found -> None)
  | None -> None

(* Struct helpers (proposal 4 v1). Whole struct values never touch the
   stack — only `.field` access compiles — so any value position
   holding one is a compile error with a field-directed message. *)
let rec contains_struct = function
  | TypStruct _ -> true
  | TypMod (b, _) -> contains_struct b
  | TypArray (e, _) -> contains_struct e
  | TypPointer e -> contains_struct e
  | _ -> false

let reject_struct_value what typ =
  if contains_struct typ then
    failwith (Printf.sprintf "%s: cannot use a whole struct value (access `.field` instead)" what)

(* v2: does an Ident/Index/Field chain touch a struct-typed node?
   Devices/groups never do (they aren't vars), so legacy paths stay
   untouched wherever this is false. *)
let rec path_involves_struct env = function
  | Ident n ->
    (match lookup_var env n with
     | Some t -> contains_struct t
     | None -> false)
  | Index (a, _) -> path_involves_struct env a
  | Field (e, _) -> path_involves_struct env e
  | _ -> false

(* Validate a declared type: structs must be declared (in order),
   pointers to structs are unsupported, mod-ness is parser-checked. *)
let rec validate_type env what = function
  | TypStruct n ->
    (match lookup_struct env n with
    | Some _ -> ()
    | None ->
      failwith (Printf.sprintf "%s: unknown type `%s` (want u8/u16/bool or a declared struct)" what n))
  | TypPointer t when contains_struct t ->
    failwith (Printf.sprintf "%s: pointers to structs are not supported (index buffers instead)" what)
  | TypArray (e, _) -> validate_type env what e
  | TypMod (b, _) -> validate_type env what b
  | _ -> ()

(* Value of type `src` may flow where `dst` is expected (stores,
   initializers, call arguments). Plain rules (equal, u8 widens to
   u16) plus: a mod value fits wherever its base fits, and — since
   the value is already below the modulus — mod(u16, m <= 256) fits
   u8. Anything flowing INTO a mod slot is reduced at runtime, so
   plain values of a fitting width are accepted there too. *)
let rec assign_compat dst src =
  (* Backstop: whole-struct flows are rejected with directed messages
     at each site; this just keeps the lattice sound. *)
  if contains_struct dst || contains_struct src then false
  else if dst = src then true
  else match dst, src with
  | TypU16, TypU8 -> true
  | TypU16, TypMod _ -> true
  | TypU8, TypMod (TypU8, _) -> true
  | TypU8, TypMod (TypU16, m) -> m <= 256
  | TypMod (b, m), TypMod (b2, m2) ->
    m = m2 && (b2 = b || (b2 = TypU8 && b = TypU16))
  | TypMod (b, _), s ->
    (match mod_base s with
    | TypU8 -> true
    | TypU16 -> b = TypU16
    | _ -> false)
  | _ -> false

(* Result of `+ - * / %`: same modulus preserves the bound (width
   widens), mixed moduli are a type error, mixing with plain coerces
   to plain — the result is no longer bounded. *)
let arith_result l r =
  match mod_modulus l, mod_modulus r with
  | Some m1, Some m2 when m1 = m2 ->
    let b =
      if mod_base l = TypU16 || mod_base r = TypU16 then TypU16 else TypU8
    in
    TypMod (b, m1)
  | Some _, Some _ ->
    failwith "mixed-modulus arithmetic is a type error (reduce one side with % first)"
  | Some _, None | None, Some _ ->
    (match mod_base l, mod_base r with
    | TypU8, TypU8 -> TypU8
    | TypU16, TypU16 -> TypU16
    | TypU8, TypU16 -> TypU16
    | TypU16, TypU8 -> TypU16
    | _ -> failwith "Invalid operands for arithmetic operation")
  | None, None ->
    (match l, r with
    | TypU8, TypU8 -> TypU8
    | TypU16, TypU16 -> TypU16
    | TypU8, TypU16 -> TypU16
    | TypU16, TypU8 -> TypU16
    | _ -> failwith "Invalid operands for arithmetic operation")

let rec lookup_func env name =
  try Some (List.assoc name env.funcs)
  with Not_found ->
    (match env.parent with
    | Some p -> lookup_func p name
    | None -> None)

let add_func env name (params: param list) return_typ =
  env.funcs <- (name, (params, return_typ)) :: env.funcs

let add_device env name ports =
  env.devices <- (name, ports) :: env.devices

let add_group env name subs =
  env.groups <- (name, subs) :: env.groups

let rec lookup_device_port env device_name port_name =
  let rec find env =
    try Some (List.assoc port_name (List.assoc device_name env.devices))
    with Not_found ->
      match env.parent with
      | Some p -> find p
      | None -> None
  in
  find env

let rec lookup_group_field env group_name field_name =
  let rec find env =
    try Some (List.assoc field_name (List.assoc group_name env.groups))
    with Not_found ->
      match env.parent with
      | Some p -> find p
      | None -> None
  in
  find env

let rec type_of_expr env expr =
  match expr with
  | IntLit n ->
    if n >= 0 && n <= 255 then TypU8
    else if n >= 0 && n <= 65535 then TypU16
    else failwith (Printf.sprintf "Integer %d out of range" n)
  | StringLit _ -> TypPointer TypU8
  | Ident name ->
    (match lookup_var env name with
    | Some typ -> typ
    | None -> failwith (Printf.sprintf "Undefined variable %s" name))
  | BinOp (op, left, right) ->
    let left_typ = type_of_expr env left in
    let right_typ = type_of_expr env right in
    (match op with
    | Add | Sub | Mul | Div | Mod -> arith_result left_typ right_typ
    | And | Or | Xor | Lshift | Rshift ->
      (* Conservative: bitwise results are no longer bounded, so mods
         decay to their plain base here (comparisons still yield bool). *)
      (match mod_base left_typ, mod_base right_typ with
      | TypU8, TypU8 -> TypU8
      | TypU16, TypU16 -> TypU16
      | TypU8, TypU16 -> TypU16
      | TypU16, TypU8 -> TypU16
      | _ -> failwith "Invalid operands for bitwise operation")
    | Eq | Neq | Lt | Gt | Le | Ge ->
      if contains_struct left_typ || contains_struct right_typ then
        failwith "cannot compare structs (compare fields)";
      TypBool
    | AndAnd | OrOr ->
      TypBool
    | Not ->
      (* Unreachable: the parser only builds Not as UnOp. *)
      failwith "Not is a unary operator")
  | UnOp (op, expr) ->
    let expr_typ = type_of_expr env expr in
    reject_struct_value "unary operator" expr_typ;
    (match op with
    | Neg -> mod_base expr_typ
    | NotBit -> mod_base expr_typ
    | Not -> TypBool)
  | Call (func_expr, args) ->
    (* Type check all arguments *)
    List.iter (fun arg -> ignore (type_of_expr env arg)) args;
    (match func_expr with
    | Ident name ->
      (match lookup_func env name with
      | Some (params, return_typ) ->
        if List.length params <> List.length args then
          failwith (Printf.sprintf "Function %s expects %d arguments, got %d" 
            name (List.length params) (List.length args));
        List.iter2 (fun param arg ->
          let arg_typ = type_of_expr env arg in
          if contains_struct param.typ || contains_struct arg_typ then
            failwith (Printf.sprintf "struct argument `%s` of function `%s` is not supported (pass fields)"
              param.name name);
          if not (assign_compat param.typ arg_typ) then
            failwith (Printf.sprintf "Type mismatch for argument %s of function %s"
              param.name name)
        ) params args;
        (match return_typ with
        | Some typ -> typ
        | None -> TypVoid)
      | None ->
        (* Unreachable for defined functions: signatures are
           pre-collected whole-program (proposal 9), so anything left
           is a typo — fail here instead of at assembly time. *)
        failwith (Printf.sprintf "undefined function `%s`" name))
    | Field _ -> TypVoid
    | _ -> failwith "Invalid function call")
  | Index (arr, index) ->
    let arr_typ = type_of_expr env arr in
    let index_typ = type_of_expr env index in
    (* A mod index is already in range — always a safe index. *)
    (match mod_base index_typ with
    | TypU8 | TypU16 -> ()
    | _ -> failwith "Array index must be u8 or u16");
    (match arr_typ with
    | TypArray (elem_typ, _) -> elem_typ
    | TypPointer elem_typ -> elem_typ
    | _ -> failwith "Cannot index non-array type")
  | Field (expr, field) ->
    (* Whole struct values never reach here as anything but a field
       base — anything else holding one is rejected below. *)
    let struct_field_of sname =
      match lookup_struct_field env sname field with
      | Some t -> t
      | None -> failwith (Printf.sprintf "`%s` has no field `%s`" sname field)
    in
    (match expr with
    | Ident base ->
      (match lookup_var env base with
      | Some (TypStruct sname) -> struct_field_of sname
      | _ ->
        (match lookup_device_port env base field with
        | Some typ -> typ
        | None ->
          (match lookup_group_field env base field with
          | Some typ -> typ
          | None ->
            let expr_typ = type_of_expr env expr in
            reject_struct_value "field base" expr_typ;
            (match expr_typ with
            | TypU16 -> TypU16
            | TypVoid -> TypU8
            | _ -> TypU8))))
    | Index (arr, index) ->
      (match arr with
      | Ident aname ->
        (match lookup_var env aname with
        | Some (TypArray (TypStruct sname, _)) ->
          let index_typ = type_of_expr env index in
          (match mod_base index_typ with
          | TypU8 | TypU16 -> ()
          | _ -> failwith "Array index must be u8 or u16");
          struct_field_of sname
        | _ ->
          let expr_typ = type_of_expr env expr in
          reject_struct_value "field base" expr_typ;
          (match expr_typ with
          | TypU16 -> TypU16
          | TypVoid -> TypU8
          | _ -> TypU8))
      | _ when path_involves_struct env arr ->
        (* v2: field of a nested struct row or array element, e.g.
           `m.rows[i].x` or `t.notes[1].pitch` — resolve the chain. *)
        (match composite_typ env arr with
         | TypArray (TypStruct sname, _) -> struct_field_of sname
         | _ ->
           failwith (Printf.sprintf "cannot access field `%s` of non-struct row" field))
      | _ ->
        let expr_typ = type_of_expr env expr in
        reject_struct_value "field base" expr_typ;
        (match expr_typ with
        | TypU16 -> TypU16
        | TypVoid -> TypU8
        | _ -> TypU8))
    | _ when path_involves_struct env expr ->
      (* v2: chained access over nested structs, e.g. `a.pos.x` —
         resolve the whole path. *)
      composite_typ env (Field (expr, field))
    | _ ->
      let expr_typ = type_of_expr env expr in
      reject_struct_value "field base" expr_typ;
      (match expr_typ with
      | TypU16 -> TypU16
      | TypVoid -> TypU8
      | _ -> TypU8))
  | AddrOf _ -> TypU16
  | RawLit _ -> TypU16
  | Assign (left, right) ->
    (match left with
    | Ident n ->
      (match resolve_const env n with
      | Some true ->
        failwith (Printf.sprintf "cannot assign to constant `%s`" n)
      | _ -> ())
    | _ -> ());
    let left_typ = type_of_expr env left in
    let right_typ = type_of_expr env right in
    (* v2: same-type struct values copy whole (`a = b` lowers to a
       byte copy). Anything else holding a struct is still an error. *)
    (match left_typ, right_typ with
     | TypStruct s1, TypStruct s2 when s1 = s2 -> left_typ
     | _ ->
       if contains_struct left_typ || contains_struct right_typ then
         failwith "cannot assign whole structs of different type (same-type struct values copy with `=`)";
       if right_typ = TypVoid || assign_compat left_typ right_typ ||
          (match left with Field _ -> true | _ -> false) then
         left_typ
       else
         failwith "Type mismatch in assignment")
  | CompoundLit (name, fields) ->
    TypU16

(* v2: resolve an Ident/Index/Field chain over structs and arrays to
   its type. Mutual with type_of_expr (index expressions need it).
   Only struct/array-typed nodes are traversed — devices, groups and
   anything else fail here, so callers try their own shapes first. *)
and composite_typ env = function
  | Ident n ->
    (match lookup_var env n with
     | Some t -> t
     | None -> failwith (Printf.sprintf "Undefined variable %s" n))
  | Index (a, i) ->
    let it = type_of_expr env i in
    (match mod_base it with
     | TypU8 | TypU16 -> ()
     | _ -> failwith "Array index must be u8 or u16");
    (match composite_typ env a with
     | TypArray (e, _) | TypPointer e -> e
     | _ -> failwith "Cannot index non-array type")
  | Field (e, f) ->
    (match composite_typ env e with
     | TypStruct s ->
       (match lookup_struct_field env s f with
        | Some t -> t
        | None -> failwith (Printf.sprintf "`%s` has no field `%s`" s f))
     | _ -> failwith (Printf.sprintf "cannot access field `%s` of non-struct value" f))
  | _ -> failwith "not a struct/array path"

let rec type_check_stmt env stmt =
  match stmt with
  | ExprStmt expr ->
    let t = type_of_expr env expr in
    (match expr, t with
     (* v2: a same-type struct copy is a complete statement (the
        Assign case already rejected mixed types). It leaves nothing
        on the stack, so bare `a = b;` is balanced. *)
     | Assign _, TypStruct _ -> ()
     | _ -> reject_struct_value "expression statement" t)
  | Return expr ->
    (match expr with
    | Some expr ->
      reject_struct_value "return value" (type_of_expr env expr)
    | None -> ())
  | BrkStmt -> ()
  | Goto _ -> ()
  | Label _ -> ()
  | RPush expr ->
    reject_struct_value "rpush" (type_of_expr env expr)
  | RPop -> ()
  | RPeek -> ()
  | RawStmt _ -> ()
  | If (condition, then_body, elifs, else_body) ->
    let cond_typ = type_of_expr env condition in
    if cond_typ <> TypBool && cond_typ <> TypU8 && cond_typ <> TypU16 then
      failwith "Condition must be boolean";
    let then_env = create_env (Some env) in
    List.iter (type_check_stmt then_env) then_body;
    List.iter (fun (cond, body) ->
      let cond_typ = type_of_expr env cond in
      if cond_typ <> TypBool && cond_typ <> TypU8 && cond_typ <> TypU16 then
        failwith "Condition must be boolean";
      let elif_env = create_env (Some env) in
      List.iter (type_check_stmt elif_env) body
    ) elifs;
    let else_env = create_env (Some env) in
    List.iter (type_check_stmt else_env) else_body
  | While (condition, body) ->
    let cond_typ = type_of_expr env condition in
    if cond_typ <> TypBool && cond_typ <> TypU8 && cond_typ <> TypU16 then
      failwith "Condition must be boolean";
    let body_env = create_env (Some env) in
    List.iter (type_check_stmt body_env) body
  | For (var_name, start_expr, end_expr, body) ->
    let start_typ = type_of_expr env start_expr in
    let end_typ = type_of_expr env end_expr in
    (match mod_base start_typ with TypU8 | TypU16 -> () | _ -> failwith "For loop start must be u8 or u16");
    (match mod_base end_typ with TypU8 | TypU16 -> () | _ -> failwith "For loop end must be u8 or u16");
    let body_env = create_env (Some env) in
    add_var body_env var_name TypU16;
    List.iter (type_check_stmt body_env) body
  | Block stmts ->
    let block_env = create_env (Some env) in
    List.iter (type_check_stmt block_env) stmts
  | Match _ ->
    failwith "internal error: unexpanded match reached the type checker"
  | VarDecl (name, typ, init) ->
    validate_type env (Printf.sprintf "variable `%s`" name) typ;
    (match init with
    | Some expr ->
      let init_typ = type_of_expr env expr in
      if contains_struct typ || contains_struct init_typ then
        failwith (Printf.sprintf "cannot initialize `%s` with a whole struct (declare bare, then assign fields or copy with `=`)" name);
      if not (assign_compat typ init_typ) then
        failwith (Printf.sprintf "Type mismatch in variable declaration for %s" name)
    | None -> ());
    add_var env name typ
  | InferDecl _ ->
    failwith "internal error: unelaborated `:=` reached the type checker"
  | ConstDecl (name, typopt, expr) ->
    let expr_typ = type_of_expr env expr in
    if contains_struct expr_typ then
      failwith (Printf.sprintf "constant `%s` cannot hold a whole struct" name);
    let t =
      match typopt with
      | Some t ->
        validate_type env (Printf.sprintf "constant `%s`" name) t;
        if contains_struct t then
          failwith (Printf.sprintf "constant `%s` cannot be struct-typed" name);
        if assign_compat t expr_typ then t
        else failwith (Printf.sprintf "Type mismatch in constant declaration for %s" name)
      | None ->
        (match expr_typ with
        | TypVoid ->
          failwith (Printf.sprintf "cannot infer type of constant `%s`: void initializer" name)
        | t -> t)
    in
    add_var env name t;
    add_const env name

let type_check_func env (func: func) =
  let func_env = create_env (Some env) in
  List.iter (fun (p: param) ->
    validate_type env (Printf.sprintf "parameter `%s` of `%s`" p.name func.name) p.typ;
    if contains_struct p.typ then
      failwith (Printf.sprintf "struct parameter `%s` of `%s` is not supported (pass fields)" p.name func.name);
    add_var func_env p.name p.typ
  ) func.params;
  (match func.return_typ with
  | Some t ->
    validate_type env (Printf.sprintf "return type of `%s`" func.name) t;
    if contains_struct t then
      failwith (Printf.sprintf "struct return type of `%s` is not supported" func.name)
  | None -> ());
  List.iter (type_check_stmt func_env) func.body

let typ_of_size size =
  if size = 1 then TypU8 else if size = 2 then TypU16 else TypU8

let type_check_program program =
  let global_env = create_env None in
  (* Add built-in functions *)
  add_func global_env "print" [{ name = "msg"; typ = TypPointer TypU8 }] None;
  (* Proposal 9: collect every function signature before checking any
     body, so calls are arity- and type-checked order-independently.
     This deliberately does not enable recursion — locals stay static
     (see limitations); it only makes call checking complete. *)
  List.iter (function
    | FuncDecl f -> add_func global_env f.name f.params f.return_typ
    | _ -> ()) program;
  List.iter (fun decl ->
    match decl with
    | FuncDecl func -> type_check_func global_env func
    | MacroDecl _ -> ()
    | ImportDecl _ -> ()
    | GlobalVarDecl (name, typ, init) ->
      validate_type global_env (Printf.sprintf "global `%s`" name) typ;
      (match init with
      | Some expr ->
        let init_typ = type_of_expr global_env expr in
        if contains_struct typ || contains_struct init_typ then
          failwith (Printf.sprintf "cannot initialize `%s` with a whole struct (declare bare, then assign fields or copy with `=`)" name);
        if not (assign_compat typ init_typ) then
          failwith (Printf.sprintf "Type mismatch in global variable declaration for %s" name)
      | None -> ());
      add_var global_env name typ
    | GlobalInferDecl _ ->
      failwith "internal error: unelaborated global `:=` reached the type checker"
    | GlobalConstDecl (name, typopt, expr) ->
      let expr_typ = type_of_expr global_env expr in
      if contains_struct expr_typ then
        failwith (Printf.sprintf "constant `%s` cannot hold a whole struct" name);
      let t =
        match typopt with
        | Some t ->
          validate_type global_env (Printf.sprintf "constant `%s`" name) t;
          if contains_struct t then
            failwith (Printf.sprintf "constant `%s` cannot be struct-typed" name);
          if assign_compat t expr_typ then t
          else failwith (Printf.sprintf "Type mismatch in global constant declaration for %s" name)
        | None ->
          (match expr_typ with
          | TypVoid ->
            failwith (Printf.sprintf "cannot infer type of global constant `%s`: void initializer" name)
          | t -> t)
      in
      add_var global_env name t;
      add_const global_env name
    | DeviceDecl device ->
      let ports = List.map (fun p -> (p.port_name, typ_of_size p.port_size)) device.ports in
      let full_ports = ("vector", TypU16) :: ports in
      add_device global_env device.device_name full_ports
    | GroupDecl g ->
      let reject_mod w t =
        match t with
        | TypMod _ ->
          failwith (Printf.sprintf "mod type not supported for %s (v1: mod lives on variables only)" w)
        | _ -> ()
      in
      let reject_struct w t =
        match t with
        | TypStruct _ ->
          failwith (Printf.sprintf "struct types not supported for %s (v1: groups hold scalars; use a named struct instead)" w)
        | _ -> ()
      in
      reject_mod (Printf.sprintf "group `%s` base" g.group_name) g.base_typ;
      reject_struct (Printf.sprintf "group `%s` base" g.group_name) g.base_typ;
      List.iter (fun (fname, ftyp) ->
        reject_mod (Printf.sprintf "field `%s.%s`" g.group_name fname) ftyp;
        reject_struct (Printf.sprintf "field `%s.%s`" g.group_name fname) ftyp
      ) g.fields;
      let base_size = g.base_typ in
      add_var global_env g.group_name base_size;
      let fields = List.map (fun (fname, ftyp) -> (fname, ftyp)) g.fields in
      add_group global_env g.group_name fields
    | DataDecl _ -> ()
    | AssetDecl _ -> ()
    | MetaDecl (title, author) ->
      let check field v =
        if v = "" then
          failwith (Printf.sprintf "meta `%s` must not be empty" field);
        if String.contains v '\x00' then
          failwith (Printf.sprintf "meta `%s` must not contain NUL" field)
      in
      check "title" title;
      check "author" author
    | BufferDecl b ->
      (match b.buf_elem with
      | TypU8 | TypU16 | TypBool -> ()
      | TypMod _ ->
        failwith (Printf.sprintf "buffer `%s` cannot hold mod-typed elements (v1: mod lives on variables only)" b.buf_name)
      | TypStruct n ->
        (match lookup_struct global_env n with
        | Some _ -> ()
        | None -> failwith (Printf.sprintf "buffer `%s`: unknown type `%s`" b.buf_name n))
      | _ -> failwith (Printf.sprintf "buffer `%s` must hold u8/u16/bool" b.buf_name));
      add_var global_env b.buf_name (TypArray (b.buf_elem, b.buf_len))
    | StructDecl s ->
      (* v2 fields: scalars, previously-declared structs (nesting),
         and fixed arrays of scalars or structs. Checking is
         single-pass, so only earlier structs resolve — a forward
         reference or cycle is an unknown-type error here, never a
         miscompile downstream. *)
      let rec valid_field fname = function
        | TypU8 | TypU16 | TypBool -> ()
        | TypStruct n ->
          (match lookup_struct global_env n with
           | Some _ -> ()
           | None ->
             failwith (Printf.sprintf "struct `%s` field `%s`: unknown type `%s` (declare it first)" s.struct_name fname n))
        | TypArray (e, n) ->
          if n < 1 then
            failwith (Printf.sprintf "struct `%s` field `%s`: array length must be positive" s.struct_name fname);
          (match e with
           | TypU8 | TypU16 | TypBool -> ()
           | TypStruct sn ->
             (match lookup_struct global_env sn with
              | Some _ -> ()
              | None ->
                failwith (Printf.sprintf "struct `%s` field `%s`: unknown type `%s` (declare it first)" s.struct_name fname sn))
           | _ ->
             failwith (Printf.sprintf "struct `%s` field `%s`: only arrays of u8/u16/bool or structs (v2)" s.struct_name fname))
        | _ ->
          failwith (Printf.sprintf "struct `%s` field `%s`: mod/pointer fields are not supported (v2: scalars, structs, arrays)" s.struct_name fname)
      in
      List.iter (fun (fname, ftyp) -> valid_field fname ftyp) s.struct_fields;
      add_struct global_env s.struct_name s.struct_fields
    | RawDecl _ -> ()
  ) program;
  global_env
