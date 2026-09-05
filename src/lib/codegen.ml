(* Code generator for Etal - Uxntal compliant *)

open Ast
open Printf

type var_info = {
  name: string;
  addr: string;
  is_local: bool;
  typ: Ast.typ;
  size: int;
}

type zero_item =
  | ZVar of string * int
  | ZGroup of string * int * (string * int) list

let rec typ_size = function
  | Ast.TypU8 -> 1
  | Ast.TypU16 -> 2
  | Ast.TypBool -> 1
  | Ast.TypVoid -> 0
  | Ast.TypArray (t, n) -> n * (typ_size t)
  | Ast.TypPointer _ -> 2

type codegen_env = {
  mutable global_vars: (string * var_info) list;
  mutable local_vars: (string * var_info) list;
  mutable next_global_addr: int;
  mutable next_local_offset: int;
  mutable entry_code: Buffer.t;
  mutable func_code: Buffer.t;
  mutable code: Buffer.t;
  mutable data: Buffer.t;
  mutable strings: (string * string) list;
  mutable in_func: bool;
  mutable func_name: string;
  mutable devices: (string * (string * int) list) list;
  mutable groups: (string * (string * int) list) list;
  mutable constants: string list;
  mutable zero_order: zero_item list;
  mutable func_sigs: (string * int list) list;
}

let create_env () = {
  global_vars = [];
  local_vars = [];
  next_global_addr = 0x00;
  next_local_offset = 0;
  entry_code = Buffer.create 1024;
  func_code = Buffer.create 1024;
  code = Buffer.create 1024;
  data = Buffer.create 1024;
  strings = [];
  in_func = false;
  func_name = "";
  devices = [];
  groups = [];
  constants = [];
  zero_order = [];
  func_sigs = [];
}

let lookup_device_port env device port =
  try Some (List.assoc port (List.assoc device env.devices))
  with Not_found -> None

let is_device env name =
  List.mem_assoc name env.devices

let lookup_group_field env group field =
  try Some (List.assoc field (List.assoc group env.groups))
  with Not_found -> None

let is_group env name =
  List.mem_assoc name env.groups

let emit env fmt =
  let buf = if env.in_func then env.code else env.entry_code in
  Printf.ksprintf (Buffer.add_string buf) fmt

let get_var_info env name =
  try List.assoc name env.local_vars
  with Not_found ->
    try List.assoc name env.global_vars
    with Not_found -> raise Not_found

let get_var_addr env name =
  try
    let info = List.assoc name env.local_vars in
    (info.addr, info.is_local, info.typ, info.size)
  with Not_found ->
    try
      let info = List.assoc name env.global_vars in
      (info.addr, info.is_local, info.typ, info.size)
    with Not_found ->
      (* Create new global variable *)
      let addr = env.next_global_addr in
      env.next_global_addr <- env.next_global_addr + 2;
      let addr_str = sprintf "$%02x" addr in
      let info = { name; addr = addr_str; is_local = false; typ = Ast.TypU16; size = 2 } in
      env.global_vars <- (name, info) :: env.global_vars;
      (addr_str, false, Ast.TypU16, 2)

let make_string_label env s =
  let label = sprintf "str_%d" (List.length env.strings) in
  env.strings <- env.strings @ [(label, s)];
  label

let local_counter = ref 0

let new_local_label env prefix =
  incr local_counter;
  sprintf "%s_%d" prefix !local_counter

let start_func env name =
  env.in_func <- true;
  env.func_name <- name;
  env.local_vars <- [];
  env.next_local_offset <- 0;
  local_counter := 0

let end_func env =
  env.in_func <- false;
  env.local_vars <- []

let add_local_var env name typ =
  let size = typ_size typ in
  let offset = env.next_local_offset in
  env.next_local_offset <- env.next_local_offset + size;
  let addr_str = sprintf ",&%s" name in
  let info = { name; addr = addr_str; is_local = true; typ; size } in
  env.local_vars <- (name, info) :: env.local_vars;
  addr_str

let rec field_path expr =
  match expr with
  | Ident name -> name
  | Field (outer, field) -> (field_path outer) ^ "." ^ field
  | _ -> "unknown"

(* Emit expr, promoting to dest_size bytes when dest is a short.
   - IntLit <=255 -> #xxxx when dest_size=2
   - u8 var/field (1 byte) -> <load> #00 SWP (zero-extend) when dest_size=2 *)
let rec expr_is_u8 env expr =
  (* True iff codegen_expr leaves exactly 1 byte on the stack. *)
  match expr with
  | IntLit n when n >= 0 && n <= 255 -> true
  | Ident n ->
    (try (try List.assoc n env.local_vars with Not_found -> List.assoc n env.global_vars).size = 1
     with Not_found -> false)
  | Field (Ident b, f) when is_device env b ->
    (match lookup_device_port env b f with Some 1 -> true | _ -> false)
  | Field (Ident b, f) when is_group env b ->
    (match lookup_group_field env b f with Some 1 -> true | _ -> false)
  | BinOp (Eq, _, _) | BinOp (Neq, _, _) | BinOp (Lt, _, _)
  | BinOp (Gt, _, _) | BinOp (Le, _, _) | BinOp (Ge, _, _)
  | BinOp (AndAnd, _, _) | BinOp (OrOr, _, _) -> true (* bool byte *)
  | UnOp (Not, _) -> true (* bool byte *)
  | _ -> false

let rec codegen_expr env expr =
  match expr with
  | IntLit n ->
    if n >= 0 && n <= 255 then
      emit env "#%02x" n
    else if n >= 0 && n <= 65535 then
      emit env "#%04x" n
    else
      failwith (sprintf "Integer %d out of range" n)
  | StringLit s ->
    let label = make_string_label env s in
    emit env ";%s" label
  | Ident name ->
    if List.mem name env.constants then
      emit env ";%s" name
    else
      (try
        let info = List.assoc name env.local_vars in
        if info.size = 1 then emit env "%s LDR" info.addr else emit env "%s LDR2" info.addr
      with Not_found ->
        try
          let info = List.assoc name env.global_vars in
          if info.size = 1 then emit env ".%s LDZ" info.name else emit env ".%s LDZ2" info.name
        with Not_found ->
          emit env ".%s LDZ2" name)
  | BinOp (op, left, right) ->
    let is_eq = match op with Eq | Neq | Lt | Gt | Le | Ge -> true | _ -> false in
    let left_is_u8 =
      match left with
      | Ident n -> (try (try List.assoc n env.local_vars with Not_found -> List.assoc n env.global_vars).size = 1 with Not_found -> false)
      | Field (Ident b, f) when is_device env b -> (match lookup_device_port env b f with Some 1 -> true | _ -> false)
      | Field (Ident b, f) when is_group env b -> (match lookup_group_field env b f with Some 1 -> true | _ -> false)
      | IntLit n when n <= 255 -> true
      | _ -> false
    in
    let right_is_u8 =
      match right with
      | IntLit n when n <= 255 -> true
      | Ident n -> (try (try List.assoc n env.local_vars with Not_found -> List.assoc n env.global_vars).size = 1 with Not_found -> false)
      | Field (Ident b, f) when is_device env b -> (match lookup_device_port env b f with Some 1 -> true | _ -> false)
      | _ -> false
    in
    let use8 = is_eq && left_is_u8 && right_is_u8 in
    let emit_operand e =
      if use8 then codegen_expr env e
      else
        (* 16-bit op: both operands must be shorts *)
        match e with
        | IntLit n when n >= 0 && n <= 255 -> emit env "#%04x" n
        | _ when expr_is_u8 env e -> codegen_expr env e; emit env " #00 SWP"
        | _ -> codegen_expr env e
    in
    (match op with
     | Lshift | Rshift ->
       codegen_rhs env left 2;
       emit env " ";
       codegen_rhs env right 2;
       emit env " ";
       (match op with Lshift -> emit env "#02 MUL2" | Rshift -> emit env "#02 DIV2" | _ -> ())
     | _ ->
       emit_operand left;
       emit env " ";
       emit_operand right;
       emit env " ";
       (match op with
       | Add -> if use8 then emit env "ADD" else emit env "ADD2"
       | Sub -> if use8 then emit env "SUB" else emit env "SUB2"
       | Mul -> if use8 then emit env "MUL" else emit env "MUL2"
       | Div -> if use8 then emit env "DIV" else emit env "DIV2"
       | Mod -> if use8 then emit env "DIVk MUL SUB" else emit env "DIV2k MUL2 SUB2"
       | And -> if use8 then emit env "AND" else emit env "AND2"
       | Or -> if use8 then emit env "ORA" else emit env "ORA2"
       | Xor -> if use8 then emit env "EOR" else emit env "EOR2"
       | Eq -> if use8 then emit env "EQU" else emit env "EQU2"
       | Neq -> if use8 then emit env "NEQ" else emit env "NEQ2"
       | Lt -> if use8 then emit env "LTH" else emit env "LTH2"
       | Gt -> if use8 then emit env "GTH" else emit env "GTH2"
       | Le -> if use8 then emit env "GTHk INC EQU" else emit env "GTH2k INC2 EQU"
       | Ge -> if use8 then emit env "LTHk INC EQU" else emit env "LTH2k INC2 EQU"
       | AndAnd -> emit env "AND"
       | OrOr -> emit env "ORA"
       | _ -> ()))
  | UnOp (op, expr) ->
    codegen_expr env expr;
    (match op with
    | Neg -> emit env "#0000 SWP2 SUB2"
    | NotBit -> emit env "#ffff EOR2"
    | Not -> emit env "#0000 EQU2")
  | Call (func_expr, args) ->
    (* Check if this is a foreign function call *)
    let is_foreign_call = match func_expr with
      | Field _ -> true
      | _ -> false
    in
    if is_foreign_call then begin
      (* Handle foreign function calls *)
      match func_expr with
      | Field (outer, method_name) ->
        let full_path = field_path func_expr in
        if full_path = "varvara.console.write" then begin
          (* Write byte to console: value Console/write DEO.
             Truncate u16 arg to low byte via NIP. *)
          List.iter (fun arg ->
            codegen_expr env arg;
            if not (expr_is_u8 env arg) then emit env " NIP";
            emit env " "
          ) args;
          emit env ".Console/write DEO"
        end else if full_path = "varvara.console.read" then begin
          (* Read byte from console: Console/read DEI *)
          emit env ".Console/read DEI"
        end else if full_path = "varvara.console.error" then begin
          (* Write to error: value Console/error DEO *)
          List.iter (fun arg ->
            codegen_expr env arg;
            if not (expr_is_u8 env arg) then emit env " NIP";
            emit env " "
          ) args;
          emit env ".Console/error DEO"
        end else begin
          (* Unknown foreign call - skip *)
          emit env "#0000"
        end
      | _ ->
        (* Unknown outer expression - skip *)
        emit env "#0000"
    end else begin
      (* Regular function call: promote args to param sizes when known. *)
      let param_sizes =
        match func_expr with
        | Ident name -> (try Some (List.assoc name env.func_sigs) with Not_found -> None)
        | _ -> None
      in
      (match param_sizes with
       | Some sizes ->
         List.iter2 (fun arg sz ->
           codegen_rhs env arg sz;
           emit env " "
         ) args sizes
       | None ->
         List.iter (fun arg ->
           codegen_expr env arg;
           emit env " "
         ) args);
      (match func_expr with
      | Ident name ->
        emit env ";%s JSR2" name
      | _ -> failwith "Invalid function expression")
    end
  | Index (arr, index) ->
    codegen_expr env arr;
    emit env " ";
    codegen_expr env index;
    emit env "ADD2 LDA2"
  | Field (expr, field) ->
    (match expr with
    | Ident base when is_device env base ->
      (match lookup_device_port env base field with
      | Some 2 -> emit env ".%s/%s DEI2" base field
      | Some 1 -> emit env ".%s/%s DEI" base field
      | _ -> emit env ".%s/%s DEI" base field)
    | Ident base when is_group env base ->
      (match lookup_group_field env base field with
      | Some 2 -> emit env ".%s/%s LDZ2" base field
      | Some 1 -> emit env ".%s/%s LDZ" base field
      | _ -> emit env ".%s/%s LDZ2" base field)
    | _ ->
      codegen_expr env expr)
  | AddrOf name ->
    emit env ";%s" name
  | RawLit s ->
    emit env "%s" s
  | Assign (left, right) ->
    (match left with
    | Ident name ->
      (try
        let info = List.assoc name env.local_vars in
        codegen_rhs env right info.size;
        if info.size = 1 then emit env " %s STR" info.addr else emit env " %s STR2" info.addr
      with Not_found ->
        try
          let info = List.assoc name env.global_vars in
          codegen_rhs env right info.size;
          if info.size = 1 then emit env " .%s STZ" info.name else emit env " .%s STZ2" info.name
        with Not_found ->
          codegen_rhs env right 2;
          emit env " .%s STZ2" name)
    | Field (field_expr, field_name) ->
      (match field_expr with
      | Ident base when is_device env base ->
        let sz = (match lookup_device_port env base field_name with Some s -> s | None -> 2) in
        codegen_rhs env right sz;
        (match lookup_device_port env base field_name with
        | Some 2 -> emit env " .%s/%s DEO2" base field_name
        | Some 1 -> emit env " .%s/%s DEO" base field_name
        | _ -> emit env " .%s/%s DEO2" base field_name)
      | Ident base when is_group env base ->
        let sz = (match lookup_group_field env base field_name with Some s -> s | None -> 2) in
        codegen_rhs env right sz;
        (match lookup_group_field env base field_name with
        | Some 2 -> emit env " .%s/%s STZ2" base field_name
        | Some 1 -> emit env " .%s/%s STZ" base field_name
        | _ -> emit env " .%s/%s STZ2" base field_name)
      | _ ->
        codegen_expr env right;
        emit env " #0000")
    | _ -> failwith "Invalid assignment target")
  | CompoundLit (name, fields) ->
    emit env ";%s" name

(* Emit RHS sized to dest_size bytes:
   - dest 2, expr 1 byte -> zero-extend (#00 SWP) or short literal
   - dest 1, expr 2 bytes -> truncate low byte (NIP)
   - else direct. *)
and codegen_rhs env expr dest_size =
  if dest_size = 2 then
    match expr with
    | IntLit n when n >= 0 && n <= 255 -> emit env "#%04x" n
    | _ when expr_is_u8 env expr -> codegen_expr env expr; emit env " #00 SWP"
    | _ -> codegen_expr env expr
  else if dest_size = 1 then
    match expr with
    | IntLit n when n >= 0 && n <= 255 -> emit env "#%02x" n
    | _ when expr_is_u8 env expr -> codegen_expr env expr
    | _ -> codegen_expr env expr; emit env " NIP"
  else
    codegen_expr env expr

let rec codegen_stmt env stmt =
  match stmt with
  | ExprStmt expr ->
    codegen_expr env expr;
    emit env "\n"
  | Return None ->
    emit env "JMP2r\n"
  | Return (Some expr) ->
    codegen_expr env expr;
    emit env " JMP2r\n"
  | If (condition, then_body, elifs, else_body) ->
    let then_label = new_local_label env "if_then" in
    let else_label = new_local_label env "if_else" in
    let end_label = new_local_label env "if_end" in

    codegen_expr env condition;
    emit env " ?&%s\n" then_label;
    if List.length elifs > 0 || List.length else_body > 0 then
      emit env " !&%s\n" else_label
    else
      emit env " !&%s\n" end_label;
    emit env "&%s\n" then_label;
    List.iter (codegen_stmt env) then_body;
    if List.length elifs > 0 || List.length else_body > 0 then begin
      emit env " !&%s\n" end_label;
      emit env "&%s\n" else_label;
      List.iter (fun (cond, body) ->
        let elif_then = new_local_label env "elif_then" in
        let elif_else = new_local_label env "elif_else" in
        codegen_expr env cond;
        emit env " ?&%s\n" elif_then;
        emit env " !&%s\n" elif_else;
        emit env "&%s\n" elif_then;
        List.iter (codegen_stmt env) body;
        emit env " !&%s\n" end_label;
        emit env "&%s\n" elif_else;
      ) elifs;
      if List.length else_body > 0 then
        List.iter (codegen_stmt env) else_body;
      emit env "&%s\n" end_label
    end else begin
      emit env "&%s\n" end_label
    end
  | While (condition, body) ->
    let loop_label = new_local_label env "while" in
    let cont_label = new_local_label env "while_cont" in
    let end_label = new_local_label env "while_end" in
    (* while(cond){body} ->
       &loop <cond> ?&cont !&end &cont <body> !&loop &end
       (JCI pops bool; true -> body, false -> end) *)
    emit env "&%s\n" loop_label;
    codegen_expr env condition;
    emit env " ?&%s\n" cont_label;
    emit env " !&%s\n" end_label;
    emit env "&%s\n" cont_label;
    List.iter (codegen_stmt env) body;
    emit env " !&%s\n" loop_label;
    emit env "&%s\n" end_label
  | For (var_name, start_expr, end_expr, body) ->
    let addr = add_local_var env var_name Ast.TypU16 in
    (* init var to start (promote to short) *)
    codegen_rhs env start_expr 2;
    emit env " %s STR2\n" addr;
    let loop_label = new_local_label env "for" in
    let cont_label = new_local_label env "for_cont" in
    let end_label = new_local_label env "for_end" in
    (* for i in start..end == while(i < end) { body; i++ } *)
    emit env "&%s\n" loop_label;
    emit env "%s LDR2 " addr;
    codegen_rhs env end_expr 2;
    emit env " LTH2 ?&%s\n" cont_label;
    emit env " !&%s\n" end_label;
    emit env "&%s\n" cont_label;
    List.iter (codegen_stmt env) body;
    emit env "%s LDR2 INC2 %s STR2\n" addr addr;
    emit env " !&%s\n" loop_label;
    emit env "&%s\n" end_label
  | Block stmts ->
    List.iter (codegen_stmt env) stmts
  | VarDecl (name, typ, init) ->
    if env.in_func then begin
      (* Local variable - use relative addressing *)
      let addr = add_local_var env name typ in
      match init with
      | Some expr ->
        let size = typ_size typ in
        codegen_rhs env expr size;
        if size = 1 then emit env " %s STR\n" addr else emit env " %s STR2\n" addr
      | None -> ()
    end else begin
      (* Global variable - use zero-page addressing *)
      let size = typ_size typ in
      let addr =
        try (List.assoc name env.global_vars).addr
        with Not_found ->
          let addr_val = env.next_global_addr in
          env.next_global_addr <- env.next_global_addr + size;
          let addr_str = sprintf "$%02x" addr_val in
          let info = { name; addr = addr_str; is_local = false; typ; size } in
          env.global_vars <- (name, info) :: env.global_vars;
          addr_str
      in
      match init with
      | Some expr ->
        codegen_rhs env expr size;
        if size = 1 then emit env " %s STZ\n" addr else emit env " %s STZ2\n" addr
      | None -> ()
    end
  | ConstDecl (name, expr) ->
    if env.in_func then begin
      let addr = add_local_var env name Ast.TypU16 in
      codegen_rhs env expr 2;
      emit env " %s STR2\n" addr
    end else begin
      let addr =
        try (List.assoc name env.global_vars).addr
        with Not_found ->
          let addr_val = env.next_global_addr in
          env.next_global_addr <- env.next_global_addr + 2;
          let addr_str = sprintf "$%02x" addr_val in
          let info = { name; addr = addr_str; is_local = false; typ = Ast.TypU16; size = 2 } in
          env.global_vars <- (name, info) :: env.global_vars;
          addr_str
      in
      codegen_rhs env expr 2;
      emit env " %s STZ2\n" addr
    end
  | BrkStmt ->
    emit env "BRK\n"
  | Goto lbl ->
    emit env "!&%s\n" lbl
  | Label lbl ->
    emit env "&%s\n" lbl
  | RPush expr ->
    codegen_expr env expr;
    (* Determine size for STH *)
    let size =
      match expr with
      | Ident name ->
        (try (try List.assoc name env.local_vars with Not_found -> List.assoc name env.global_vars).size
         with Not_found -> 2)
      | IntLit n -> if n <= 255 then 1 else 2
      | _ -> 2
    in
    if size = 1 then emit env " STH\n" else emit env " STH2\n"
  | RPop ->
    emit env "STHr\n"
  | RPeek ->
    emit env "STHkr\n"
  | RawStmt s ->
    emit env "%s\n" s

let collect_local_vars fn_def =
  let vars = Hashtbl.create 16 in
  let rec collect_stmt stmt =
    match stmt with
    | VarDecl (name, typ, _) -> Hashtbl.replace vars name (typ_size typ)
    | ConstDecl (name, _) -> Hashtbl.replace vars name 2
    | Block stmts -> List.iter collect_stmt stmts
    | If (_, then_body, elifs, else_body) ->
      List.iter collect_stmt then_body;
      List.iter (fun (_, body) -> List.iter collect_stmt body) elifs;
      List.iter collect_stmt else_body
    | While (_, body) -> List.iter collect_stmt body
    | For (var_name, _, _, body) -> Hashtbl.replace vars var_name 2; List.iter collect_stmt body
    | _ -> ()
  in
  List.iter collect_stmt fn_def.body;
  vars

let codegen_func env (fn_def : Ast.func) =
  let local_vars = collect_local_vars fn_def in
  (* Add params to local vars for reservaion *)
  List.iter (fun (p: Ast.param) -> Hashtbl.replace local_vars p.name (typ_size p.typ)) fn_def.params;
  (* Record signature for call-site arg promotion (u8 literal -> short). *)
  env.func_sigs <- (fn_def.name, List.map (fun (p: Ast.param) -> typ_size p.typ) fn_def.params) :: env.func_sigs;
  Buffer.add_string env.code (sprintf "\n@%s ( -- )\n" fn_def.name);
  start_func env fn_def.name;
  (* Handle params: store from stack to locals *)
  List.iter (fun (p: Ast.param) ->
    let addr = add_local_var env p.name p.typ in
    let size = typ_size p.typ in
    if size = 1 then
      Buffer.add_string env.code (sprintf "    %s STR\n" addr)
    else
      Buffer.add_string env.code (sprintf "    %s STR2\n" addr)
  ) (List.rev fn_def.params);
  List.iter (codegen_stmt env) fn_def.body;
  if fn_def.is_event then emit env "BRK\n" else emit env "JMP2r\n";
  (* Reserve locals AFTER return so they are not executed.
     Relative ,&var uses reach them forward/backward. *)
  Hashtbl.iter (fun name size ->
    Buffer.add_string env.code (sprintf "    &%s $%d\n" name size)
  ) local_vars;
  end_func env

let encode_string s =
  let buf = Buffer.create 64 in
  String.iter (fun c ->
    if c = ' ' then Buffer.add_string buf "\\s "
    else if c = '\n' then Buffer.add_string buf "\\n "
    else if c = '\t' then Buffer.add_string buf "\\09 "
    else if c = '\\' then Buffer.add_string buf "\\5c "
    else if c = '"' then Buffer.add_string buf "\\22 "
    else if c = '\000' then Buffer.add_string buf "\\0 "
    else Buffer.add_string buf (sprintf "\"%c " c)
  ) s;
  Buffer.add_string buf "\\0";
  Buffer.contents buf

let codegen_program program =
  let env = create_env () in
  Buffer.add_string env.func_code "%RTN { JMP2r }\n";
  Buffer.add_string env.func_code "%EMIT { #18 DEO }\n";
  Buffer.add_string env.func_code "%HALT { #010f DEO }\n";
  Buffer.add_string env.func_code "%\\0 { 00 }\n";
  Buffer.add_string env.func_code "%\\s { 20 }\n";
  Buffer.add_string env.func_code "%\\n { 0a }\n\n";

  (* Add Console device port declaration *)
  Buffer.add_string env.func_code "|10 @Console/vector $2 &read $1 &pad $4 &type $1 &write $1 &error $1\n\n";
  env.devices <- ("Console", [("vector",2);("read",1);("pad",4);("type",1);("write",1);("error",1)]) :: env.devices;

  Buffer.add_string env.entry_code "|0100\n";
  Buffer.add_string env.entry_code ";main JSR2\n";
  Buffer.add_string env.entry_code "HALT\n";
  Buffer.add_string env.entry_code "BRK\n\n";

  List.iter (fun decl ->
    match decl with
    | FuncDecl f ->
      codegen_func env f
    | MacroDecl _ ->
      (* Unreachable: Expand.expand_program strips macros. *)
      ()
    | ImportDecl _ ->
      ()
    | GlobalVarDecl (name, typ, init) ->
      let size = typ_size typ in
      let addr =
        try (List.assoc name env.global_vars).addr
        with Not_found ->
          let addr_val = env.next_global_addr in
          env.next_global_addr <- env.next_global_addr + size;
          let addr_str = sprintf "$%02x" addr_val in
          let info = { name; addr = addr_str; is_local = false; typ; size } in
          env.global_vars <- (name, info) :: env.global_vars;
          env.zero_order <- ZVar (name, size) :: env.zero_order;
          addr_str
      in
      (match init with
      | Some expr ->
        codegen_rhs env expr size;
        if size = 1 then emit env " %s STZ\n" addr else emit env " %s STZ2\n" addr
      | None -> ())
    | GlobalConstDecl (name, expr) ->
      env.constants <- name :: env.constants;
      (match expr with
      | IntLit n ->
        Buffer.add_string env.func_code (sprintf "|%04x @%s\n" n name)
      | Ident id ->
        Buffer.add_string env.func_code (sprintf "|%s @%s\n" id name)
      | _ ->
        Buffer.add_string env.func_code (sprintf "|0000 @%s\n" name))
    | DeviceDecl device ->
      (* Store device for later lookups *)
      let has_vector = List.exists (fun p -> p.port_name = "vector") device.ports in
      let port_list = List.map (fun p -> (p.port_name, p.port_size)) device.ports in
      let full_ports = if has_vector then port_list else ("vector",2) :: port_list in
      env.devices <- (device.device_name, full_ports) :: env.devices;
      (* Emit device port declaration *)
      if has_vector then begin
        Buffer.add_string env.func_code (sprintf "|%x @%s" device.device_page device.device_name);
        List.iter (fun port ->
          Buffer.add_string env.func_code (sprintf " &%s $%d" port.port_name port.port_size)
        ) device.ports;
      end else begin
        Buffer.add_string env.func_code (sprintf "|%x @%s/vector $2" device.device_page device.device_name);
        List.iter (fun port ->
          Buffer.add_string env.func_code (sprintf " &%s $%d" port.port_name port.port_size)
        ) device.ports;
      end;
      Buffer.add_string env.func_code "\n"
    | GroupDecl g ->
      let base_size = typ_size g.base_typ in
      let field_sizes = List.map (fun (fname, ftyp) -> (fname, typ_size ftyp)) g.fields in
      env.groups <- (g.group_name, field_sizes) :: env.groups;
      let base_addr = env.next_global_addr in
      env.next_global_addr <- env.next_global_addr + base_size;
      List.iter (fun (_, sz) -> env.next_global_addr <- env.next_global_addr + sz) field_sizes;
      let base_info = { name = g.group_name; addr = sprintf "$%02x" base_addr; is_local = false; typ = g.base_typ; size = base_size } in begin
        env.zero_order <- ZGroup (g.group_name, base_size, field_sizes) :: env.zero_order;
        env.global_vars <- (g.group_name, base_info) :: env.global_vars
      end
    | DataDecl d ->
      Buffer.add_string env.data (sprintf "@%s [ " d.data_name);
      List.iter (fun b -> Buffer.add_string env.data (sprintf "%02x " b)) d.data_bytes;
      Buffer.add_string env.data "]\n"
    | RawDecl raw ->
      (* Emitted with the data section (main RAM): raw blocks usually
         define data/tables, which drifblim forbids in zero-page.
         Limitation: tal `%macros` pasted via raw land after their
         use sites — prefer native ETAL `macro` instead. *)
      Buffer.add_string env.data raw;
      Buffer.add_string env.data "\n"
  ) program;

  let buf = Buffer.create 1024 in

  (* Add zero-page variable declarations *)
  if List.length env.zero_order > 0 then begin
    Buffer.add_string buf "|00\n";
    List.iter (fun item ->
      match item with
      | ZVar (name, size) ->
        Buffer.add_string buf (sprintf "    @%s $%d\n" name size)
      | ZGroup (gname, base_size, fields) ->
        Buffer.add_string buf (sprintf "    @%s $%d" gname base_size);
        List.iter (fun (fname, fsize) ->
          Buffer.add_string buf (sprintf " &%s $%d" fname fsize)
        ) fields;
        Buffer.add_string buf "\n"
    ) (List.rev env.zero_order);
    Buffer.add_string buf "\n"
  end else if List.length env.global_vars > 0 then begin
    Buffer.add_string buf "|00\n";
    List.iter (fun (_, info) ->
      if not (List.mem_assoc info.name env.groups) then
        Buffer.add_string buf (sprintf "    @%s $%d\n" info.name info.size)
    ) (List.rev env.global_vars);
    Buffer.add_string buf "\n"
  end;

  Buffer.add_string buf (Buffer.contents env.func_code);
  Buffer.add_string buf "\n";
  Buffer.add_string buf (Buffer.contents env.entry_code);
  Buffer.add_string buf "\n";
  Buffer.add_string buf (Buffer.contents env.code);
  Buffer.add_string buf "\n";
  Buffer.add_string buf (Buffer.contents env.data);

  if List.length env.strings > 0 then begin
    Buffer.add_string buf "\n";
    List.iter (fun (label, s) ->
      Buffer.add_string buf (sprintf "@%s %s\n" label (encode_string s))
    ) env.strings
  end;

  Buffer.contents buf
