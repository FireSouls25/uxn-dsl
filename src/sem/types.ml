(* Type checker for Etal *)

open Ast

(* Proposal 12: error context. The checker sees no token stream, so
   errors point at the declaration under check (file:line:col of its
   start) via the loader's name table; exact use-site lines need
   AST-wide positions (future work). The shadowed failwith keeps all
   call sites unchanged — every message is already a string. *)
let loc_table : (string * Token.pos) list ref = ref []
let check_ctx : string option ref = ref None
let set_locs t = loc_table := t
let set_ctx n = check_ctx := Some n

(* Proposal 12, exact lines: the last leaf (identifier, literal,
   address) visited by the checker. Reset at statement, function
   and declaration boundaries so only the current unit's leaves
   count; generated nodes carry nopos and fall back to context. *)
let last_leaf : Token.pos option ref = ref None
let reset_leaf () = last_leaf := None

let failwith (msg : string) =
  let prefix =
    match !last_leaf with
    | Some p when p.pfile <> "" -> Token.string_of_pos p ^ ": "
    | _ ->
      (match !check_ctx with
       | Some n ->
         (match List.assoc_opt n !loc_table with
          | Some p ->
            let s = Token.string_of_pos p in
            if s = "" then "" else s ^ ": "
          | None -> "")
       | None -> "") in
  Stdlib.failwith (prefix ^ msg)

(* Proposal 13: unused-discovery. Name-mentioned = used (mentioning
   covers reads, writes and references — write-only detection is
   future work; shadowing conflates, so a used shadower suppresses
   warnings for same-named dead bindings — sound, occasionally
   quiet). Tracked only where dead weight costs bytes: globals,
   stored (`: T :`) constants, locals, parameters, data and assets.
   Skipped: functions (DCE prunes them by design), free `::`
   constants (address labels, zero bytes), labels (zero cost —
   drifblim already warns downstream), macros (expanded away),
   buffers, devices, groups, structs.
   defs: name -> (kind, enclosing fn or "" for top level). *)
let uses : string list ref = ref []
let defs : (string * (string * string)) list ref = ref []
let mark_used n = uses := n :: !uses
(* Top-level sites pass ~func:"" explicitly: check_ctx there holds
   a stale (or self) name, never the right scope. Stmt-level sites
   run inside functions, so the ambient context is correct. *)
let def_name ?func n kind =
  let f =
    match func with
    | Some f -> f
    | None -> (match !check_ctx with Some c -> c | None -> "") in
  defs := (n, (kind, f)) :: !defs

(* Raw text may reference any name (same rationale as DCE's raw
   bail-out), so a program with raw skips warnings entirely. *)
let report_uses program =
  if Dce.has_raw program then () else
  let used = List.sort_uniq String.compare !uses in
  List.iter (fun (name, (kind, func)) ->
    if List.mem name used then () else
    let target = if func = "" then name else func in
    let at =
      match List.assoc_opt target !loc_table with
      | Some p ->
        let s = Token.string_of_pos p in
        if s = "" then "" else " (" ^ s ^ ")"
      | None -> "" in
    let where = if func = "" then "" else Printf.sprintf " in fn `%s`" func in
    Printf.eprintf "warning: unused %s `%s`%s%s\n" kind name where at
  ) (List.rev !defs)


type type_env = {
  mutable vars: (string * typ) list;
  (* params, return type, and whether the callee is an event vector
     (a JSR into one never comes back — see the Call case). *)
  mutable funcs: (string * (param list * typ option * bool)) list;
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

(* Signedness through mod wrappers (mods never wrap signed — the
   parser rejects those bases — so a direct match decides). *)
let is_signed = function
  | TypI8 | TypI16 -> true
  | _ -> false

(* Integer literals fit any slot whose range holds the value. This is
   what makes `x: i8 = 5` work while `x: i8 = some_u8` stays an error
   (and changes nothing for unsigned: a fitting literal already types
   compatibly there). Applied at every value-flow site. *)
let literal_fits dst = function
  | IntLit (n, _) ->
    (match dst with
     | TypU8 -> n >= 0 && n <= 255
     | TypU16 -> n >= 0 && n <= 65535
     | TypI8 -> n >= 0 && n <= 127
     | TypI16 -> n >= 0 && n <= 32767
     | _ -> false)
  | _ -> false

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

(* Whole arrays never touch the stack as values either — only Index
   (element access) compiles. Structs are rejected separately above;
   pointers are fine (they are addresses). *)
let is_array_value = function
  | TypArray _ -> true
  | _ -> false

let reject_array_value what typ =
  if is_array_value typ then
    failwith (Printf.sprintf "%s: cannot use a whole array value (index an element)" what)

(* Zero-length arrays (empty inline data, file assets whose size
   is known only at assembly): copying them would silently move
   nothing — index elements instead. *)
let is_empty_array = function
  | TypArray (_, 0) -> true
  | _ -> false

(* v2: does an Ident/Index/Field chain touch a struct-typed node?
   Devices/groups never do (they aren't vars), so legacy paths stay
   untouched wherever this is false. *)
let rec path_involves_struct env = function
  | Ident (n, _) ->
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
  (* Widening into signed is zero-extended, always sound. Anything
     narrowing or sign-changing needs an explicit bridge (`& 255`
     reinterprets same-width bits, `u8 mod 128` proves a value fits) —
     literals that fit are handled by literal_fits at each site. *)
  | TypI16, TypU8 -> true
  | TypI16, TypI8 -> true
  | TypU16, TypMod _ -> true
  | TypU8, TypMod (TypU8, _) -> true
  | TypU8, TypMod (TypU16, m) -> m <= 256
  | TypI8, TypMod (TypU8, m) -> m <= 128
  | TypI8, TypMod (TypU16, m) -> m <= 128
  | TypI16, TypMod (TypU16, m) -> m <= 32768
  | TypI16, TypMod (TypU8, _) -> true
  | TypMod (b, m), TypMod (b2, m2) ->
    m = m2 && (b2 = b || (b2 = TypU8 && b = TypU16))
  | TypMod (b, _), s ->
    (match mod_base s with
    | TypU8 -> true
    | TypU16 -> b = TypU16
    | _ -> false)
  | _ -> false

(* Address decay (proposal 10, second half): arrays — and explicit
   `&name` addresses — flow into pointer slots; the address is what
   moves. Plain u16 values do NOT (that would swallow typos). *)
let decays_to_pointer dst src = function
  | AddrOf _ ->
    (match dst with TypPointer _ -> true | _ -> false)
  | _ ->
    (match dst, src with
     | TypPointer TypU8, TypArray (e, _) -> e = TypU8 || e = TypBool
     | TypPointer TypU16, TypArray (TypU16, _) -> true
     | TypPointer TypI8, TypArray (TypI8, _) -> true
     | TypPointer TypI16, TypArray (TypI16, _) -> true
     | _ -> false)

(* Result of `+ - * / %`: same modulus preserves the bound (width
   widens), mixed moduli are a type error, mixing with plain coerces
   to plain — the result is no longer bounded. Same-sign widens like
   the unsigned pair; cross-sign needs an explicit reinterpret first.
   Signed `/` and `%` are rejected outright: Uxn divides unsigned, so
   negatives would miscompile — branch on the sign first. *)
let arith_result op l r =
  (match op with
   | Div | Mod when is_signed (mod_base l) || is_signed (mod_base r) ->
     failwith "signed `/` and `%` are not supported (Uxn divides unsigned — branch on the sign first)"
   | _ -> ());
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
    | TypI8, TypI8 -> TypI8
    | TypI16, TypI16 -> TypI16
    | TypI8, TypI16 | TypI16, TypI8 -> TypI16
    | _ -> failwith "mixed-sign arithmetic needs an explicit reinterpret first (`& 255` keeps same-width bits, `u8 mod 128` proves a value fits)")
  | None, None ->
    (match l, r with
    | TypU8, TypU8 -> TypU8
    | TypU16, TypU16 -> TypU16
    | TypU8, TypU16 -> TypU16
    | TypU16, TypU8 -> TypU16
    | TypI8, TypI8 -> TypI8
    | TypI16, TypI16 -> TypI16
    | TypI8, TypI16 | TypI16, TypI8 -> TypI16
    | _ -> failwith "mixed-sign arithmetic needs an explicit reinterpret first (`& 255` keeps same-width bits, `u8 mod 128` proves a value fits)")

let rec lookup_func env name =
  try Some (List.assoc name env.funcs)
  with Not_found ->
    (match env.parent with
    | Some p -> lookup_func p name
    | None -> None)

let add_func env name (params: param list) return_typ is_event =
  env.funcs <- (name, (params, return_typ, is_event)) :: env.funcs

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
  | IntLit (n, p) ->
    last_leaf := Some p;
    if n >= 0 && n <= 255 then TypU8
    else if n >= 0 && n <= 65535 then TypU16
    else failwith (Printf.sprintf "Integer %d out of range" n)
  | StringLit (_, p) ->
    last_leaf := Some p;
    TypPointer TypU8
  | Ident (name, p) ->
    last_leaf := Some p;
    mark_used name;
    (match lookup_var env name with
    | Some typ -> typ
    | None -> failwith (Printf.sprintf "Undefined variable %s" name))
  | BinOp (op, left, right) ->
    let left_typ = type_of_expr env left in
    let right_typ = type_of_expr env right in
    (match op with
    | Add | Sub | Mul | Div | Mod ->
      (* Integer literals adapt to the other side when they fit it, so
         `i + 1` and `n * 2` just work; anything bigger keeps its
         unsigned type and the normal rules reject genuine mixing. *)
      let adapts t n = match t with
        | TypI8 -> n >= 0 && n <= 127
        | TypI16 -> n >= 0 && n <= 32767
        | TypU8 -> n >= 0 && n <= 255
        | TypU16 -> n >= 0 && n <= 65535
        | _ -> false in
      let lt = match left with
        | IntLit (n, _) when adapts right_typ n -> right_typ | _ -> left_typ
      and rt = match right with
        | IntLit (n, _) when adapts left_typ n -> left_typ | _ -> right_typ in
      arith_result op lt rt
    | And | Or | Xor | Lshift | Rshift ->
      (* Conservative: bitwise results are no longer bounded, so mods
         decay to their plain base here (comparisons still yield bool).
         Bitwise ops are sign-agnostic: same-sign widens, same-width
         cross-sign reinterprets as unsigned (shifts stay logical). *)
      (match mod_base left_typ, mod_base right_typ with
      | TypU8, TypU8 -> TypU8
      | TypU16, TypU16 -> TypU16
      | TypU8, TypU16 -> TypU16
      | TypU16, TypU8 -> TypU16
      | TypI8, TypI8 -> TypI8
      | TypI16, TypI16 -> TypI16
      | TypI8, TypI16 | TypI16, TypI8 -> TypI16
      | TypU8, TypI8 | TypI8, TypU8 -> TypU8
      | TypU16, TypI16 | TypI16, TypU16 -> TypU16
      | TypU8, TypI16 | TypI16, TypU8 -> TypU16
      | TypI8, TypU16 | TypU16, TypI8 -> TypU16
      | _ -> failwith "Invalid operands for bitwise operation")
    | Eq | Neq | Lt | Gt | Le | Ge ->
      if contains_struct left_typ || contains_struct right_typ then
        failwith "cannot compare structs (compare fields)";
      if is_array_value left_typ || is_array_value right_typ then
        failwith "cannot compare whole arrays (compare elements)";
      (* Ordered comparison is meaningless across signs (255 vs -1
         would read equal bitwise); equality is bitwise and stays
         permissive. Literals are exempt — they fit by value and the
         generator folds them correctly (`i < 10` is the common case). *)
      (match op with
       | Lt | Gt | Le | Ge ->
         (match left, right with
          | IntLit _, _ | _, IntLit _ -> ()
          | _ ->
            let sl = is_signed (mod_base left_typ)
            and sr = is_signed (mod_base right_typ) in
            if sl <> sr then
              failwith "cannot compare signed with unsigned (reinterpret one side first)");
       | _ -> ());
      TypBool
    | AndAnd | OrOr ->
      if is_array_value left_typ || is_array_value right_typ then
        failwith "cannot combine whole arrays with && / || (compare elements)";
      TypBool
    | Not ->
      (* Unreachable: the parser only builds Not as UnOp. *)
      failwith "Not is a unary operator")
  | UnOp (op, expr) ->
    let expr_typ = type_of_expr env expr in
    reject_struct_value "unary operator" expr_typ;
    reject_array_value "unary operator" expr_typ;
    (match op with
    | Neg ->
      (match expr with
       (* Negativity comes from unary minus directly on a literal:
          `-5` is i8, `-300` is i16. Anything wider keeps wrapping. *)
       | IntLit (n, _) when n >= 1 && n <= 128 -> TypI8
       | IntLit (n, _) when n >= 129 && n <= 32768 -> TypI16
       | _ -> mod_base expr_typ)
    | NotBit -> mod_base expr_typ
    | Not -> TypBool)
  | Call (func_expr, args) ->
    (* Type check all arguments *)
    List.iter (fun arg -> ignore (type_of_expr env arg)) args;
    (match func_expr with
    | Ident (name, pos) ->
      (match lookup_func env name with
      | Some (params, return_typ, is_event) ->
        (* Point call errors at the callee, not at the last argument
           (args were already checked above). *)
        last_leaf := Some pos;
        (* Vectors never return (they end in BRK), so a JSR into one
           abandons the caller's return address — the frame's stacks
           rot one entry per call. Only `main` may be an event: the
           entry stub JSRs into it once and has nothing to return to. *)
        if is_event && name <> "main" then
          failwith (Printf.sprintf "cannot call event `%s` (vectors never return — factor the body into a plain fn)" name);
        if List.length params <> List.length args then
          failwith (Printf.sprintf "Function %s expects %d arguments, got %d" 
            name (List.length params) (List.length args));
        List.iter2 (fun param arg ->
          let arg_typ = type_of_expr env arg in
          if contains_struct param.typ || contains_struct arg_typ then
            failwith (Printf.sprintf "struct argument `%s` of function `%s` is not supported (pass fields)"
              param.name name);
          if is_array_value arg_typ && not (decays_to_pointer param.typ arg_typ arg) then
            failwith (Printf.sprintf "array argument `%s` of function `%s` needs a matching pointer parameter (index an element)"
              param.name name);
          if not (assign_compat param.typ arg_typ || literal_fits param.typ arg || decays_to_pointer param.typ arg_typ arg) then
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
    | Field _ ->
      (* Foreign/device calls take scalars only (no decay targets). *)
      List.iter (fun arg -> reject_array_value "call argument" (type_of_expr env arg)) args;
      TypVoid
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
    | Ident (base, _) ->
      (match lookup_var env base with
      | Some (TypStruct sname) -> mark_used base; struct_field_of sname
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
      | Ident (aname, _) ->
        (match lookup_var env aname with
        | Some (TypArray (TypStruct sname, _)) ->
          mark_used aname;
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
  | AddrOf (name, p) ->
    last_leaf := Some p;
    mark_used name;
    TypU16
  | RawLit _ -> TypU16
  | Assign (left, right) ->
    (match left with
    | Ident (n, _) ->
      (match resolve_const env n with
      | Some true ->
        failwith (Printf.sprintf "cannot assign to constant `%s`" n)
      | _ -> ())
    | _ -> ());
    let left_typ = type_of_expr env left in
    let right_typ = type_of_expr env right in
    (* v2: same-type struct values copy whole (`a = b` lowers to a
       byte copy), as do same-type/length arrays. Anything else
       holding a struct or array is still an error. *)
    (match left_typ, right_typ with
     | TypStruct s1, TypStruct s2 when s1 = s2 -> left_typ
     | TypArray (e1, n1), TypArray (e2, n2) when e1 = e2 && n1 = n2 ->
       if n1 = 0 then
         failwith "cannot copy zero-length arrays (their size is unknown — index elements instead)";
       left_typ
     | _, _ when decays_to_pointer left_typ right_typ right -> left_typ
     | _ ->
       if contains_struct left_typ || contains_struct right_typ then
         failwith "cannot assign whole structs of different type (same-type struct values copy with `=`)";
       if is_array_value left_typ || is_array_value right_typ then
         failwith "cannot assign arrays of different element type or length (same arrays copy with `=`)";
       if right_typ = TypVoid || assign_compat left_typ right_typ ||
          literal_fits left_typ right ||
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
  | Ident (n, _) ->
    mark_used n;
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
  reset_leaf ();
  match stmt with
  | ExprStmt expr ->
    let t = type_of_expr env expr in
    (* A valued call as a bare statement silently drops the result —
       for getters like scene_pop that usually means a lost update
       (and a leaked stack slot per call). Purely local to the AST,
       so unlike proposal 13's name tracking this warns in raw
       programs too. *)
    (match expr with
     | Call (Ident (name, p), _) ->
       (match lookup_func env name with
        | Some (_, Some _, _) ->
          let s = Token.string_of_pos p in
          let at = if s = "" then "" else " (" ^ s ^ ")" in
          Printf.eprintf "warning: discarded return value of `%s`%s\n" name at
        | _ -> ())
     | _ -> ());
    (match expr, t with
     (* v2: a same-type struct/array copy is a complete statement (the
        Assign case already rejected mixed types). It leaves nothing
        on the stack, so bare `a = b;` is balanced. *)
     | Assign _, TypStruct _ -> ()
     | Assign _, t when is_array_value t -> ()
     | _ ->
       reject_struct_value "expression statement" t;
       reject_array_value "expression statement" t)
  | Return expr ->
    (match expr with
    | Some expr ->
      let t = type_of_expr env expr in
      reject_struct_value "return value" t;
      reject_array_value "return value" t
    | None -> ())
  | BrkStmt -> ()
  | Goto _ -> ()
  | Label _ -> ()
  | RPush expr ->
    let t = type_of_expr env expr in
    reject_struct_value "rpush" t;
    reject_array_value "rpush" t
  | Assert (expr, _) ->
    (* Proposal 11: truthiness like If — the message carries the
       baked location, so no position is needed here. *)
    let cond_typ = type_of_expr env expr in
    if cond_typ <> TypBool && cond_typ <> TypU8 && cond_typ <> TypU16 && cond_typ <> TypI8 && cond_typ <> TypI16 then
      failwith "assert condition must be boolean";
  | RPop -> ()
  | RPeek -> ()
  | Drop e ->
    (* Explicit discard: the value must exist (dropping void means the
       confusion runs the other way — drop the call instead) and must
       be stack-sized (whole structs/arrays never sit on the stack). *)
    let t = type_of_expr env e in
    (match mod_base t with
     | TypVoid -> failwith "cannot discard a void expression (drop the call itself instead)"
     | _ -> ());
    reject_struct_value "discarded value" t;
    reject_array_value "discarded value" t
  | RawStmt _ -> ()
  | If (condition, then_body, elifs, else_body) ->
    let cond_typ = type_of_expr env condition in
    if cond_typ <> TypBool && cond_typ <> TypU8 && cond_typ <> TypU16 && cond_typ <> TypI8 && cond_typ <> TypI16 then
      failwith "Condition must be boolean";
    let then_env = create_env (Some env) in
    List.iter (type_check_stmt then_env) then_body;
    List.iter (fun (cond, body) ->
      let cond_typ = type_of_expr env cond in
      if cond_typ <> TypBool && cond_typ <> TypU8 && cond_typ <> TypU16 && cond_typ <> TypI8 && cond_typ <> TypI16 then
        failwith "Condition must be boolean";
      let elif_env = create_env (Some env) in
      List.iter (type_check_stmt elif_env) body
    ) elifs;
    let else_env = create_env (Some env) in
    List.iter (type_check_stmt else_env) else_body
  | While (condition, body) ->
    let cond_typ = type_of_expr env condition in
    if cond_typ <> TypBool && cond_typ <> TypU8 && cond_typ <> TypU16 && cond_typ <> TypI8 && cond_typ <> TypI16 then
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
    def_name name "local";
    (match init with
    | Some expr ->
      let init_typ = type_of_expr env expr in
      if contains_struct typ || contains_struct init_typ then
        failwith (Printf.sprintf "cannot initialize `%s` with a whole struct (declare bare, then assign fields or copy with `=`)" name);
      if not (assign_compat typ init_typ || literal_fits typ expr || decays_to_pointer typ init_typ expr) then
        failwith (Printf.sprintf "Type mismatch in variable declaration for %s" name)
    | None -> ());
    add_var env name typ
  | InferDecl _ ->
    failwith "internal error: unelaborated `:=` reached the type checker"
  | ConstDecl (name, typopt, expr) ->
    (* Only the stored `: T :` form costs a slot; `::` values are
       free address labels. *)
    (match typopt with Some _ -> def_name name "constant" | None -> ());
    let expr_typ = type_of_expr env expr in
    if contains_struct expr_typ then
      failwith (Printf.sprintf "constant `%s` cannot hold a whole struct" name);
    if is_array_value expr_typ then
      failwith (Printf.sprintf "constant `%s` cannot hold a whole array" name);
    let t =
      match typopt with
      | Some t ->
        validate_type env (Printf.sprintf "constant `%s`" name) t;
        if contains_struct t then
          failwith (Printf.sprintf "constant `%s` cannot be struct-typed" name);
        if is_array_value t then
          failwith (Printf.sprintf "constant `%s` cannot be array-typed" name);
        if assign_compat t expr_typ || literal_fits t expr then t
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
  set_ctx func.name;
  reset_leaf ();
  let func_env = create_env (Some env) in
  List.iter (fun (p: param) ->
    validate_type env (Printf.sprintf "parameter `%s` of `%s`" p.name func.name) p.typ;
    def_name p.name "parameter";
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
  add_func global_env "print" [{ name = "msg"; typ = TypPointer TypU8 }] None false;
  (* Proposal 9: collect every function signature before checking any
     body, so calls are arity- and type-checked order-independently.
     This deliberately does not enable recursion — locals stay static
     (see limitations); it only makes call checking complete. *)
  List.iter (function
    | FuncDecl f -> add_func global_env f.name f.params f.return_typ f.is_event
    | _ -> ()) program;
  List.iter (fun decl ->
    match decl with
    | FuncDecl func -> type_check_func global_env func
    | MacroDecl _ -> ()
    | ImportDecl _ -> ()
    | GlobalVarDecl (name, typ, init) ->
      set_ctx name;
      reset_leaf ();
      def_name ~func:"" name "global";
      validate_type global_env (Printf.sprintf "global `%s`" name) typ;
      (match init with
      | Some expr ->
        let init_typ = type_of_expr global_env expr in
        if contains_struct typ || contains_struct init_typ then
          failwith (Printf.sprintf "cannot initialize `%s` with a whole struct (declare bare, then assign fields or copy with `=`)" name);
        if not (assign_compat typ init_typ || literal_fits typ expr || decays_to_pointer typ init_typ expr) then
          failwith (Printf.sprintf "Type mismatch in global variable declaration for %s" name)
      | None -> ());
      add_var global_env name typ
    | GlobalInferDecl _ ->
      failwith "internal error: unelaborated global `:=` reached the type checker"
    | GlobalConstDecl (name, typopt, expr) ->
      set_ctx name;
      reset_leaf ();
      (match typopt with
       | Some _ -> def_name ~func:"" name "constant"
       | None -> ());
      let expr_typ = type_of_expr global_env expr in
      if contains_struct expr_typ then
        failwith (Printf.sprintf "constant `%s` cannot hold a whole struct" name);
      if is_array_value expr_typ then
        failwith (Printf.sprintf "constant `%s` cannot hold a whole array" name);
      let t =
        match typopt with
        | Some t ->
          validate_type global_env (Printf.sprintf "constant `%s`" name) t;
          if contains_struct t then
            failwith (Printf.sprintf "constant `%s` cannot be struct-typed" name);
          if is_array_value t then
            failwith (Printf.sprintf "constant `%s` cannot be array-typed" name);
          if assign_compat t expr_typ || literal_fits t expr then t
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
      set_ctx device.device_name;
      let ports = List.map (fun p -> (p.port_name, typ_of_size p.port_size)) device.ports in
      let full_ports = ("vector", TypU16) :: ports in
      add_device global_env device.device_name full_ports
    | GroupDecl g ->
      set_ctx g.group_name;
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
    | DataDecl d ->
      set_ctx d.data_name;
      def_name ~func:"" d.data_name "data";
      (* Proposal 10: inline blobs read as u8 arrays (indexable,
         copyable with known size). *)
      add_var global_env d.data_name (TypArray (TypU8, List.length d.data_bytes))
    | AssetDecl a ->
      set_ctx a.asset_name;
      def_name ~func:"" a.asset_name "asset";
      (* File assets read the same way, but their length is known
         only at assembly — indexed access only, never whole-copy. *)
      add_var global_env a.asset_name (TypArray (TypU8, 0))
    | MetaDecl (title, author) ->
      set_ctx "meta";
      let check field v =
        if v = "" then
          failwith (Printf.sprintf "meta `%s` must not be empty" field);
        if String.contains v '\x00' then
          failwith (Printf.sprintf "meta `%s` must not contain NUL" field)
      in
      check "title" title;
      check "author" author
    | BufferDecl b ->
      set_ctx b.buf_name;
      (match b.buf_elem with
      | TypU8 | TypU16 | TypI8 | TypI16 | TypBool -> ()
      | TypMod _ ->
        failwith (Printf.sprintf "buffer `%s` cannot hold mod-typed elements (v1: mod lives on variables only)" b.buf_name)
      | TypStruct n ->
        (match lookup_struct global_env n with
        | Some _ -> ()
        | None -> failwith (Printf.sprintf "buffer `%s`: unknown type `%s`" b.buf_name n))
      | _ -> failwith (Printf.sprintf "buffer `%s` must hold u8/u16/i8/i16/bool" b.buf_name));
      add_var global_env b.buf_name (TypArray (b.buf_elem, b.buf_len))
    | StructDecl s ->
      set_ctx s.struct_name;
      (* v2 fields: scalars, previously-declared structs (nesting),
         and fixed arrays of scalars or structs. Checking is
         single-pass, so only earlier structs resolve — a forward
         reference or cycle is an unknown-type error here, never a
         miscompile downstream. *)
      let rec valid_field fname = function
        | TypU8 | TypU16 | TypI8 | TypI16 | TypBool -> ()
        | TypStruct n ->
          (match lookup_struct global_env n with
           | Some _ -> ()
           | None ->
             failwith (Printf.sprintf "struct `%s` field `%s`: unknown type `%s` (declare it first)" s.struct_name fname n))
        | TypArray (e, n) ->
          if n < 1 then
            failwith (Printf.sprintf "struct `%s` field `%s`: array length must be positive" s.struct_name fname);
          (match e with
           | TypU8 | TypU16 | TypI8 | TypI16 | TypBool -> ()
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
  report_uses program;
  global_env
