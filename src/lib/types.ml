(* Type checker for Etal *)

open Ast

type type_env = {
  mutable vars: (string * typ) list;
  mutable funcs: (string * (param list * typ option)) list;
  mutable devices: (string * (string * typ) list) list;
  mutable groups: (string * (string * typ) list) list;
  parent: type_env option;
}

let create_env parent = {
  vars = [];
  funcs = [];
  devices = [];
  groups = [];
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
    | Add | Sub | Mul | Div | Mod ->
      (match left_typ, right_typ with
      | TypU8, TypU8 -> TypU8
      | TypU16, TypU16 -> TypU16
      | TypU8, TypU16 -> TypU16
      | TypU16, TypU8 -> TypU16
      | _ -> failwith "Invalid operands for arithmetic operation")
    | And | Or | Xor | Lshift | Rshift ->
      (match left_typ, right_typ with
      | TypU8, TypU8 -> TypU8
      | TypU16, TypU16 -> TypU16
      | TypU8, TypU16 -> TypU16
      | TypU16, TypU8 -> TypU16
      | _ -> failwith "Invalid operands for bitwise operation")
    | Eq | Neq | Lt | Gt | Le | Ge ->
      TypBool
    | AndAnd | OrOr ->
      TypBool)
  | UnOp (op, expr) ->
    let expr_typ = type_of_expr env expr in
    (match op with
    | Neg -> expr_typ
    | NotBit -> expr_typ
    | Not -> TypBool
    | _ -> expr_typ)
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
          let compatible = param.typ = arg_typ ||
            (param.typ = TypU16 && arg_typ = TypU8) in
          if not compatible then
            failwith (Printf.sprintf "Type mismatch for argument %s of function %s"
              param.name name)
        ) params args;
        (match return_typ with
        | Some typ -> typ
        | None -> TypVoid)
      | None -> TypVoid)
    | Field _ -> TypVoid
    | _ -> failwith "Invalid function call")
  | Index (arr, index) ->
    let arr_typ = type_of_expr env arr in
    let index_typ = type_of_expr env index in
    (match index_typ with
    | TypU8 | TypU16 -> ()
    | _ -> failwith "Array index must be u8 or u16");
    (match arr_typ with
    | TypArray (elem_typ, _) -> elem_typ
    | TypPointer elem_typ -> elem_typ
    | _ -> failwith "Cannot index non-array type")
  | Field (expr, field) ->
    (match expr with
    | Ident base ->
      (match lookup_device_port env base field with
      | Some typ -> typ
      | None ->
        (match lookup_group_field env base field with
        | Some typ -> typ
        | None ->
          let expr_typ = type_of_expr env expr in
          (match expr_typ with
          | TypU16 -> TypU16
          | TypVoid -> TypU8
          | _ -> TypU8)))
    | _ ->
      let expr_typ = type_of_expr env expr in
      (match expr_typ with
      | TypU16 -> TypU16
      | TypVoid -> TypU8
      | _ -> TypU8))
  | AddrOf _ -> TypU16
  | RawLit _ -> TypU16
  | Assign (left, right) ->
    let left_typ = type_of_expr env left in
    let right_typ = type_of_expr env right in
    if right_typ = TypVoid || left_typ = right_typ ||
       (left_typ = TypU16 && right_typ = TypU8) ||
       (match left with Field _ -> true | _ -> false) then
      left_typ
    else
      failwith "Type mismatch in assignment"
  | CompoundLit (name, fields) ->
    TypU16

let rec type_check_stmt env stmt =
  match stmt with
  | ExprStmt expr ->
    ignore (type_of_expr env expr)
  | Return expr ->
    (match expr with
    | Some expr -> ignore (type_of_expr env expr)
    | None -> ())
  | BrkStmt -> ()
  | Goto _ -> ()
  | Label _ -> ()
  | RPush expr -> ignore (type_of_expr env expr)
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
    (match start_typ with TypU8 | TypU16 -> () | _ -> failwith "For loop start must be u8 or u16");
    (match end_typ with TypU8 | TypU16 -> () | _ -> failwith "For loop end must be u8 or u16");
    let body_env = create_env (Some env) in
    add_var body_env var_name TypU16;
    List.iter (type_check_stmt body_env) body
  | Block stmts ->
    let block_env = create_env (Some env) in
    List.iter (type_check_stmt block_env) stmts
  | VarDecl (name, typ, init) ->
    (match init with
    | Some expr ->
      let init_typ = type_of_expr env expr in
      (* Allow implicit widening from u8 to u16 *)
      let compatible = typ = init_typ ||
        (typ = TypU16 && init_typ = TypU8) in
      if not compatible then
        failwith (Printf.sprintf "Type mismatch in variable declaration for %s" name)
    | None -> ());
    add_var env name typ
  | ConstDecl (name, expr) ->
    let expr_typ = type_of_expr env expr in
    add_var env name expr_typ

let type_check_func env (func: func) =
  let func_env = create_env (Some env) in
  List.iter (fun (p: param) ->
    add_var func_env p.name p.typ
  ) func.params;
  add_func env func.name func.params func.return_typ;
  List.iter (type_check_stmt func_env) func.body

let typ_of_size size =
  if size = 1 then TypU8 else if size = 2 then TypU16 else TypU8

let type_check_program program =
  let global_env = create_env None in
  (* Add built-in functions *)
  add_func global_env "print" [{ name = "msg"; typ = TypPointer TypU8 }] None;
  List.iter (fun decl ->
    match decl with
    | FuncDecl func -> type_check_func global_env func
    | MacroDecl _ -> ()
    | ImportDecl _ -> ()
    | GlobalVarDecl (name, typ, init) ->
      (match init with
      | Some expr ->
        let init_typ = type_of_expr global_env expr in
        if typ <> init_typ && not (typ = TypU16 && init_typ = TypU8) then
          failwith (Printf.sprintf "Type mismatch in global variable declaration for %s" name)
      | None -> ());
      add_var global_env name typ
    | GlobalConstDecl (name, expr) ->
      let expr_typ = type_of_expr global_env expr in
      add_var global_env name expr_typ
    | DeviceDecl device ->
      let ports = List.map (fun p -> (p.port_name, typ_of_size p.port_size)) device.ports in
      let full_ports = ("vector", TypU16) :: ports in
      add_device global_env device.device_name full_ports
    | GroupDecl g ->
      let base_size = g.base_typ in
      add_var global_env g.group_name base_size;
      let fields = List.map (fun (fname, ftyp) -> (fname, ftyp)) g.fields in
      add_group global_env g.group_name fields
    | DataDecl _ -> ()
    | RawDecl _ -> ()
  ) program;
  global_env
