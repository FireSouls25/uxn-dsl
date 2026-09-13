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
  | Ast.TypMod (b, _) -> typ_size b
  | Ast.TypStruct _ ->
    failwith "internal error: struct size needs the struct table (use resolve_size)"

type codegen_env = {
  mutable global_vars: (string * var_info) list;
  mutable local_vars: (string * var_info) list;
  mutable next_global_addr: int;
  mutable entry_code: Buffer.t;
  mutable func_code: Buffer.t;
  mutable code: Buffer.t;
  mutable data: Buffer.t;
  mutable strings: (string * string) list;
  mutable in_func: bool;
  mutable in_event: bool;
  mutable func_name: string;
  mutable devices: (string * (string * int) list) list;
  mutable groups: (string * (string * int) list) list;
  (* Structs: name -> [(field, offset, size)]. Offsets derive from
     field sizes at declaration; v1 fields are scalar. *)
  mutable structs: (string * (string * (int * int)) list) list;
  mutable constants: string list;
  mutable zero_order: zero_item list;
  mutable func_sigs: (string * int list) list;
  (* Declared return widths for call-result sizing (proposal 9
     pre-pass fills both tables). *)
  mutable func_rets: (string * int) list;
  mutable func_ret: int option;
  (* Main-RAM buffer region for `buffer` decls: base address plus
     next free address; (name, addr, size) in allocation order. *)
  mutable next_buffer_addr: int;
  mutable buffer_order: (string * int * int) list;
  (* ROM metadata from `meta {}` (title, author), wired at boot. *)
  mutable meta: (string * string) option;
  (* Zero-page bytes reserved so far (globals + spilled locals). *)
  mutable zp_used: int;
}

(* Buffers live in main RAM, clear of code/data (loaded at 0x100). *)
let buffer_region_base = 0x2000

let create_env () = {
  global_vars = [];
  local_vars = [];
  next_global_addr = 0x00;
  entry_code = Buffer.create 1024;
  func_code = Buffer.create 1024;
  code = Buffer.create 1024;
  data = Buffer.create 1024;
  strings = [];
  in_func = false;
  in_event = false;
  func_name = "";
  devices = [];
  groups = [];
  structs = [];
  constants = [];
  zero_order = [];
  func_sigs = [];
  func_rets = [];
  func_ret = None;
  next_buffer_addr = buffer_region_base;
  buffer_order = [];
  meta = None;
  zp_used = 0;
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

(* (offset, size) of field f in struct s; raises Not_found, turned
   into a directed error by callers. *)
let struct_field env sname fname =
  List.assoc fname (List.assoc sname env.structs)

let is_struct_array env name =
  try
    let info =
      try List.assoc name env.local_vars
      with Not_found -> List.assoc name env.global_vars
    in
    (match info.typ with
    | Ast.TypArray (Ast.TypStruct s, _) -> Some s
    | _ -> None)
  with Not_found -> None

let is_struct_var env name =
  try
    let info =
      try List.assoc name env.local_vars
      with Not_found -> List.assoc name env.global_vars
    in
    (match info.typ with
    | Ast.TypStruct s -> Some (s, info)
    | _ -> None)
  with Not_found -> None

(* Size of a type that may name a struct (buffers of structs, struct
   variables). Non-struct types use typ_size as before. *)
let rec resolve_size env = function
  | Ast.TypStruct s ->
    let fields =
      try List.assoc s env.structs
      with Not_found -> failwith (Printf.sprintf "unknown struct `%s`" s)
    in
    List.fold_left (fun acc (_, (_, sz)) -> acc + sz) 0 fields
  | Ast.TypArray (e, n) -> n * resolve_size env e
  | Ast.TypMod (b, _) -> resolve_size env b
  | t -> typ_size t

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
  local_counter := 0

let end_func env =
  env.in_func <- false;
  env.in_event <- false;
  env.func_ret <- None;
  env.local_vars <- []

let add_local_var env name typ =
  (* Locals (and params) live in zero-page under a per-function mangled
     name. Static storage like before (no reentrancy change), but with
     absolute LDZ/STZ access there is no +/-127 relative range limit,
     so functions of any size work. Reservation is recorded in
     zero_order and emitted in the |00 block. *)
  let size = resolve_size env typ in
  let mangled = env.func_name ^ "__" ^ name in
  let info = { name; addr = mangled; is_local = true; typ; size } in
  env.local_vars <- (name, info) :: env.local_vars;
  (* Reserve once per (function, name): repeated declarations share
     the slot, as before. *)
  let already =
    List.exists (function ZVar (n, _) -> n = mangled | _ -> false) env.zero_order
  in
  if not already then begin
    env.zero_order <- ZVar (mangled, size) :: env.zero_order;
    env.zp_used <- env.zp_used + size;
    if env.zp_used > 0x100 then
      failwith (Printf.sprintf "out of zero-page memory (%d bytes used)" env.zp_used);
  end;
  mangled

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
  (* Neg/NotBit preserve operand width (byte in -> byte out). *)
  | UnOp ((Neg | NotBit), e) -> expr_is_u8 env e
  (* A call leaves exactly what the callee declares: byte for `-> u8`
     (or bool), short otherwise. Unknown callees keep the legacy
     short assumption. *)
  | Call (Ident n, _) ->
    (try List.assoc n env.func_rets = 1 with Not_found -> false)
  | Index (Ident n, _) ->
    (try
       let info =
         try List.assoc n env.local_vars
         with Not_found -> List.assoc n env.global_vars
       in
       (match info.typ with
       | Ast.TypArray (elem, _) | Ast.TypPointer elem ->
         (match elem with Ast.TypU8 | Ast.TypBool -> true | _ -> false)
       | _ -> false)
     with Not_found -> false)
  (* A byte struct field leaves exactly one byte (LDA/LDZ). *)
  | Field (Index (Ident arr, _), fname) ->
    (match is_struct_array env arr with
    | Some sname ->
      (match try Some (struct_field env sname fname) with Not_found -> None with
      | Some (_, 1) -> true
      | _ -> false)
    | None -> false)
  | Field (Ident v, fname) ->
    (match is_struct_var env v with
    | Some (sname, _) ->
      (match try Some (struct_field env sname fname) with Not_found -> None with
      | Some (_, 1) -> true
      | _ -> false)
    | None -> false)
  | _ -> false

(* Reduce the on-stack value into [0, m): the existing `%` lowering
   with a constant modulus (DIVk MUL SUB / DIV2k MUL2 SUB2). Anything
   stored into a mod-typed slot passes through this, so the bound
   lives with the variable. Skipped for u8 mod 256 (identity: every
   byte is already in range). *)
let emit_mod_reduce env = function
  | Ast.TypMod (Ast.TypU8, 256) -> ()
  | Ast.TypMod (Ast.TypU8, m) -> emit env " #%02x DIVk MUL SUB" m
  | Ast.TypMod (_, m) -> emit env " #%04x DIV2k MUL2 SUB2" m
  | _ -> ()

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
        (* Locals are zero-page residents under mangled names. *)
        if info.size = 1 then emit env ".%s LDZ" info.addr else emit env ".%s LDZ2" info.addr
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
        (* Real SFT2. Control byte: high nibble = left distance,
           low nibble = right distance (rightward first). Constant
           amounts fold to one literal (masked mod 16); dynamic
           amounts go through the high nibble via #40 SFT. *)
        codegen_rhs env left 2;
        emit env " ";
        (match right with
        | IntLit n ->
          let c = (match op with
            | Lshift -> ((n land 0x0f) lsl 4)
            | _ -> (n land 0x0f)) in
          emit env "#%02x SFT2" c
        | _ ->
          codegen_rhs env right 1;
          (match op with
           | Lshift -> emit env " #40 SFT SFT2"
           | _ -> emit env " SFT2"))
      | AndAnd ->
        (* Total && / ||: each side reduces to one byte first, so
           short comparisons combine without leaking stack bytes.
           Lives OUTSIDE emit_operand below (like shifts): emitting
           operands twice would unbalance the stack. *)
        codegen_cond env left;
        emit env " ";
        codegen_cond env right;
        emit env " AND"
      | OrOr ->
        codegen_cond env left;
        emit env " ";
        codegen_cond env right;
        emit env " ORA"
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
        (* a<=b is !(a>b): the comparison leaves one byte, EQU against
           zero inverts it. (The old GTHk INC EQU shape compared the
           wrong bytes — keep-mode leaves both operands.) *)
        | Le -> if use8 then emit env "GTH #00 EQU" else emit env "GTH2 #00 EQU"
        | Ge -> if use8 then emit env "LTH #00 EQU" else emit env "LTH2 #00 EQU"
        | _ -> ()))
  | UnOp (op, expr) ->
    codegen_expr env expr;
    (* Byte operands need byte-width negation/complement/test —
       and every arm needs its leading space (drifblim reads
       `LDZ#0000` as one bad reference). *)
    let byte = expr_is_u8 env expr in
    (match op with
    | Neg -> if byte then emit env " #00 SWP SUB" else emit env " #0000 SWP2 SUB2"
    | NotBit -> if byte then emit env " #ff EOR" else emit env " #ffff EOR2"
    | Not -> if byte then emit env " #00 EQU" else emit env " #0000 EQU2")
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
      (* Builtin print("...") inlines a string printer and takes over
         arg emission (the literal must not be pushed as a value). *)
      let is_print_lit =
        match func_expr, args with
        | Ident "print", [StringLit _] -> true
        | _ -> false
      in
      if not is_print_lit then
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
      | Ident "print" ->
        (match args with
        | [StringLit s] ->
          (* Inline NUL-terminated string printer:
             ;str &loop LDAk .Console/write DEO INC2 LDAk ?&loop POP2 *)
          let label = make_string_label env s in
          let loop = new_local_label env "print" in
          emit env ";%s &%s LDAk .Console/write DEO INC2 LDAk ?&%s POP2"
            label loop loop
        | _ ->
          (* Args already emitted above; a non-literal print call
             falls through to a (likely undefined) JSR. *)
          emit env ";print JSR2")
      | Ident name ->
        emit env ";%s JSR2" name
      | _ -> failwith "Invalid function expression")
    end
  | Index (arr, index) ->
    let esz = codegen_index_addr env arr index in
    emit env " ";
    if esz = 1 then emit env "LDA" else emit env "LDA2"
  | Field (expr, field) ->
    (match expr with
    | Index (Ident arr, index) ->
      (match is_struct_array env arr with
      | Some sname ->
        (* Buffer/zp row field: absolute base + scaled index + field
           offset, then sized load. *)
        let elemsize = resolve_size env (Ast.TypStruct sname) in
        let off, fsize =
          try struct_field env sname field
          with Not_found ->
            failwith (Printf.sprintf "`%s` has no field `%s`" sname field)
        in
        emit env ";%s" arr;
        emit env " ";
        codegen_rhs env index 2;
        if elemsize <> 1 then emit env " #%04x MUL2" elemsize;
        emit env " ADD2";
        if off <> 0 then emit env " #%04x ADD2" off;
        emit env " ";
        if fsize = 1 then emit env "LDA" else emit env "LDA2"
      | None ->
        (* Legacy fallthrough below handles devices/groups/plain. *)
        codegen_expr env expr)
    | Ident v ->
      (match is_struct_var env v with
      | Some (sname, info) ->
        (* Zero-page row field: slot address + field offset. *)
        let off, fsize =
          try struct_field env sname field
          with Not_found ->
            failwith (Printf.sprintf "`%s` has no field `%s`" sname field)
        in
        let base = if info.is_local then info.addr else v in
        emit env ".%s" base;
        if off <> 0 then emit env " #%02x ADD" off;
        emit env " ";
        if fsize = 1 then emit env "LDZ" else emit env "LDZ2"
      | None when is_device env v ->
        (match lookup_device_port env v field with
        | Some 2 -> emit env ".%s/%s DEI2" v field
        | Some 1 -> emit env ".%s/%s DEI" v field
        | _ -> emit env ".%s/%s DEI" v field)
      | None when is_group env v ->
        (match lookup_group_field env v field with
        | Some 2 -> emit env ".%s/%s LDZ2" v field
        | Some 1 -> emit env ".%s/%s LDZ" v field
        | _ -> emit env ".%s/%s LDZ2" v field)
      | None ->
        codegen_expr env expr)
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
        emit_mod_reduce env info.typ;
        if info.size = 1 then emit env " .%s STZ" info.addr else emit env " .%s STZ2" info.addr
      with Not_found ->
        try
          let info = List.assoc name env.global_vars in
          codegen_rhs env right info.size;
          emit_mod_reduce env info.typ;
          if info.size = 1 then emit env " .%s STZ" info.name else emit env " .%s STZ2" info.name
        with Not_found ->
          codegen_rhs env right 2;
          emit env " .%s STZ2" name)
    | Field (field_expr, field_name) ->
      (match field_expr with
      | Index (Ident arr, index) ->
        (match is_struct_array env arr with
        | Some sname ->
          let elemsize = resolve_size env (Ast.TypStruct sname) in
          let off, fsize =
            try struct_field env sname field_name
            with Not_found ->
              failwith (Printf.sprintf "`%s` has no field `%s`" sname field_name)
          in
          (* STA wants value first, address on top. *)
          codegen_rhs env right fsize;
          emit env " ";
          emit env ";%s" arr;
          emit env " ";
          codegen_rhs env index 2;
          if elemsize <> 1 then emit env " #%04x MUL2" elemsize;
          emit env " ADD2";
          if off <> 0 then emit env " #%04x ADD2" off;
          emit env " ";
          if fsize = 1 then emit env "STA" else emit env "STA2"
        | None ->
          codegen_expr env right;
          emit env " #0000")
      | Ident v ->
        (match is_struct_var env v with
        | Some (sname, info) ->
          let off, fsize =
            try struct_field env sname field_name
            with Not_found ->
              failwith (Printf.sprintf "`%s` has no field `%s`" sname field_name)
          in
          let base = if info.is_local then info.addr else v in
          codegen_rhs env right fsize;
          emit env " .%s" base;
          if off <> 0 then emit env " #%02x ADD" off;
          emit env " ";
          if fsize = 1 then emit env "STZ" else emit env "STZ2"
        | None when is_device env v ->
          let sz = (match lookup_device_port env v field_name with Some s -> s | None -> 2) in
          codegen_rhs env right sz;
          (match lookup_device_port env v field_name with
          | Some 2 -> emit env " .%s/%s DEO2" v field_name
          | Some 1 -> emit env " .%s/%s DEO" v field_name
          | _ -> emit env " .%s/%s DEO2" v field_name)
        | None when is_group env v ->
          let sz = (match lookup_group_field env v field_name with Some s -> s | None -> 2) in
          codegen_rhs env right sz;
          (match lookup_group_field env v field_name with
          | Some 2 -> emit env " .%s/%s STZ2" v field_name
          | Some 1 -> emit env " .%s/%s STZ" v field_name
          | _ -> emit env " .%s/%s STZ2" v field_name)
        | None ->
          codegen_expr env right;
          emit env " #0000")
      | _ ->
        codegen_expr env right;
        emit env " #0000")
    | Index (arr, index) ->
      (* STA expects ( value addr* -- ): value first, address on top. *)
      let esz, _ = index_array_info env arr in
      codegen_rhs env right esz;
      emit env " ";
      ignore (codegen_index_addr env arr index);
      emit env " ";
      if esz = 1 then emit env "STA" else emit env "STA2"
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

(* Element size + addressing mode for arr[index]. Returns
   (elem_size, use_addr_base): named arrays/buffers use `;name`,
   pointers evaluate to an address. Pure: emits nothing. *)
and index_array_info env arr =
  match arr with
  | Ident n ->
    (try
       let info =
         try List.assoc n env.local_vars
         with Not_found -> List.assoc n env.global_vars
       in
        (match info.typ with
        | Ast.TypArray (elem, _) ->
          if info.is_local then
            failwith (Printf.sprintf
              "array `%s` is a local; only global arrays and buffers can be indexed" n);
          (resolve_size env elem, true)
        | Ast.TypPointer elem -> (typ_size elem, false)
        | _ -> failwith (Printf.sprintf "`%s` is not an array" n))
     with Not_found ->
       failwith (Printf.sprintf "undefined array `%s`" n))
  | _ -> (2, false)

(* Emit base-address + scaled index for arr[index], leaving the absolute
   address (short) on the stack. Returns the element size in bytes. *)
and codegen_index_addr env arr index =
  let elem_size, use_addr_base = index_array_info env arr in
  (match arr with
   | Ident n when use_addr_base -> emit env ";%s" n
   | _ -> codegen_expr env arr);
  emit env " ";
  codegen_rhs env index 2;
  (* Scale by element size (bytes need none). Same bytes as before
     for 1- and 2-byte elements; struct rows scale by row size. *)
  if elem_size <> 1 then emit env " #%04x MUL2" elem_size;
  emit env " ADD2";
  elem_size

(* Total conditions (proposal 8): JCI tests one byte, so a short
   condition would test only its low byte and leak the high one. Reduce
   to a single byte unless the expression provably leaves exactly one
   (comparisons, `!`, byte vars/ports/elements). Raw literals have
   unknowable width — left alone. *)
and codegen_cond env = function
  | RawLit _ as e -> codegen_expr env e
  | e ->
    codegen_expr env e;
    if expr_is_u8 env e then () else emit env " #0000 NEQ2"

let rec codegen_stmt env stmt =  match stmt with
  | ExprStmt expr ->
    codegen_expr env expr;
    emit env "\n"
  | Return None ->
    (* Proposal 2: vectors are never JSR-called, so a bare return in an
       event pops a bogus address with JMP2r — BRK hands control back
       to the emulator instead. Plain functions keep JMP2r. *)
    if env.in_event then emit env "BRK\n" else emit env "JMP2r\n"
  | Return (Some expr) ->
    (match env.func_ret with
    | Some sz -> codegen_rhs env expr sz
    | None -> codegen_expr env expr);
    emit env " JMP2r\n"
  | If (condition, then_body, elifs, else_body) ->
    let then_label = new_local_label env "if_then" in
    let else_label = new_local_label env "if_else" in
    let end_label = new_local_label env "if_end" in

    codegen_cond env condition;
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
        codegen_cond env cond;
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
    codegen_cond env condition;
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
    emit env " .%s STZ2\n" addr;
    (* Proposal 14: a syntactically pure end bound (literal, variable,
       constant) is evaluated once into a hidden temp instead of every
       iteration. Anything that could call or store keeps the old
       evaluate-each-time semantics. Note the temp freezes the entry
       value: a body that assigns to the bound variable observes the
       entry value, not the mutation. *)
    let end_load =
      match end_expr with
      | IntLit _ | Ident _ ->
        let tmp = add_local_var env (new_local_label env "for_end") Ast.TypU16 in
        codegen_rhs env end_expr 2;
        emit env " .%s STZ2\n" tmp;
        (fun () -> emit env ".%s LDZ2" tmp)
      | _ -> (fun () -> codegen_rhs env end_expr 2)
    in
    let loop_label = new_local_label env "for" in
    let cont_label = new_local_label env "for_cont" in
    let end_label = new_local_label env "for_end" in
    (* for i in start..end == while(i < end) { body; i++ } *)
    emit env "&%s\n" loop_label;
    emit env ".%s LDZ2 " addr;
    end_load ();
    emit env " LTH2 ?&%s\n" cont_label;
    emit env " !&%s\n" end_label;
    emit env "&%s\n" cont_label;
    List.iter (codegen_stmt env) body;
    emit env ".%s LDZ2 INC2 .%s STZ2\n" addr addr;
    emit env " !&%s\n" loop_label;
    emit env "&%s\n" end_label
  | Block stmts ->
    List.iter (codegen_stmt env) stmts
  | Match _ ->
    failwith "internal error: unexpanded match reached codegen"
  | VarDecl (name, typ, init) ->
    if env.in_func then begin
      (* Local variable - zero-page slot under a mangled name *)
      let addr = add_local_var env name typ in
      match init with
      | Some expr ->
        let size = resolve_size env typ in
        codegen_rhs env expr size;
        emit_mod_reduce env typ;
        if size = 1 then emit env " .%s STZ\n" addr else emit env " .%s STZ2\n" addr
      | None -> ()
    end else begin
      (* Global variable - use zero-page addressing (label form;
         the `$hh` address string below is bookkeeping only). *)
      let size = resolve_size env typ in
      let _addr =
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
        emit_mod_reduce env typ;
        (* Label form, like every other store: raw `$hh` does not
           assemble to a zero-page address in drifblim. *)
        if size = 1 then emit env " .%s STZ\n" name else emit env " .%s STZ2\n" name
      | None -> ()
    end
  | ConstDecl (name, typopt, expr) ->
    (* Storage constant: zero-page slot initialized once (assignments
       are rejected by the checker). An explicit mod type reduces the
       initializer; an inferred type needs no reduction — a mod-typed
       source is already in range, a plain source keeps its value. *)
    let typ = match typopt with Some t -> t | None -> Ast.TypU16 in
    if env.in_func then begin
      let addr = add_local_var env name typ in
      codegen_rhs env expr 2;
      emit_mod_reduce env typ;
      emit env " .%s STZ2\n" addr
    end else begin
      let size = resolve_size env typ in
      let _addr =
        try (List.assoc name env.global_vars).addr
        with Not_found ->
          let addr_val = env.next_global_addr in
          env.next_global_addr <- env.next_global_addr + size;
          let addr_str = sprintf "$%02x" addr_val in
          let info = { name; addr = addr_str; is_local = false; typ; size } in
          env.global_vars <- (name, info) :: env.global_vars;
          addr_str
      in
      codegen_rhs env expr size;
      emit_mod_reduce env typ;
      if size = 1 then emit env " .%s STZ\n" name else emit env " .%s STZ2\n" name
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
      | Field (Index (Ident arr, _), fname) ->
        (match is_struct_array env arr with
        | Some sname ->
          (match try Some (struct_field env sname fname) with Not_found -> None with
          | Some (_, sz) -> sz
          | None -> 2)
        | None -> 2)
      | Field (Ident v, fname) ->
        (match is_struct_var env v with
        | Some (sname, _) ->
          (match try Some (struct_field env sname fname) with Not_found -> None with
          | Some (_, sz) -> sz
          | None -> 2)
        | None -> 2)
      | _ -> 2
    in
    if size = 1 then emit env " STH\n" else emit env " STH2\n"
  | RPop ->
    emit env "STHr\n"
  | RPeek ->
    emit env "STHkr\n"
  | InferDecl _ ->
    failwith "internal error: unelaborated `:=` reached codegen"
  | RawStmt s ->
    emit env "%s\n" s

let codegen_func env (fn_def : Ast.func) =
  Buffer.add_string env.code (sprintf "\n@%s ( -- )\n" fn_def.name);
  start_func env fn_def.name;
  env.in_event <- fn_def.is_event;
  (* Size `return expr` to the declared width so callers read exactly
     what the signature promises (byte callees compose). *)
  env.func_ret <-
    (match fn_def.return_typ with
    | Some t -> Some (resolve_size env t)
    | None -> None);
  (* Handle params: store from stack to zero-page slots. A mod-typed
     param is reduced on entry, so callers may pass plain values. *)
  List.iter (fun (p: Ast.param) ->
    let addr = add_local_var env p.name p.typ in
    let size = resolve_size env p.typ in
    emit_mod_reduce env p.typ;
    if size = 1 then
      Buffer.add_string env.code (sprintf "    .%s STZ\n" addr)
    else
      Buffer.add_string env.code (sprintf "    .%s STZ2\n" addr)
  ) (List.rev fn_def.params);
  List.iter (codegen_stmt env) fn_def.body;
  if fn_def.is_event then emit env "BRK\n" else emit env "JMP2r\n";
  end_func env

(* Read a sprite asset file (.chr = 16 bytes/tile 2bpp planar,
   .icn = 8 bytes/tile 1bpp) into a byte list. The loader resolves
   the path against the declaring file, so it is absolute here. *)
let read_asset_bytes name path =
  let ic =
    try open_in_bin path
    with Sys_error _ ->
      failwith (Printf.sprintf "asset `%s`: cannot read `%s`" name path)
  in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  let ext =
    try
      let dot = String.rindex path '.' in
      String.lowercase_ascii (String.sub path (dot + 1) (String.length path - dot - 1))
    with Not_found -> ""
  in
  let tile =
    match ext with
    | "chr" -> 16
    | "icn" -> 8
    | _ -> failwith (Printf.sprintf
      "asset `%s`: unknown type `%s` (want .chr for 2bpp or .icn for 1bpp)" name path)
  in
  if n mod tile <> 0 then
    failwith (Printf.sprintf
      "asset `%s`: %d bytes is not a multiple of %d (one %s tile)" name n tile ext);
  List.init n (fun i -> Char.code s.[i])

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
  (* Global initializers (emitted below, while processing decls) must
     run BEFORE main is called: they were historically appended after
     HALT and never executed. The call sequence is emitted after the
     decl loop for exactly this reason. *)

  (* Proposal 9: record every signature up front so forward calls get
     argument promotion too — the checker pre-pass makes them valid,
     this makes them correctly sized. Return widths make call results
     composable (a `-> u8` callee leaves one byte, not two). *)
  List.iter (function
    | FuncDecl f ->
      env.func_sigs <- (f.name, List.map (fun (p: Ast.param) -> resolve_size env p.typ) f.params) :: env.func_sigs;
      (match f.return_typ with
      | Some t -> env.func_rets <- (f.name, resolve_size env t) :: env.func_rets
      | None -> ())
    | _ -> ()) program;

  List.iter (fun decl ->
    match decl with
    | FuncDecl f ->
      codegen_func env f
    | MacroDecl _ ->
      (* Unreachable: Expand.expand_program strips macros. *)
      ()
    | ImportDecl _ ->
      ()
    | GlobalInferDecl _ ->
      (* Unreachable: Elab.elaborate_program rewrites `:=` before codegen. *)
      failwith "internal error: unelaborated global `:=` reached codegen"
    | GlobalVarDecl (name, typ, init) ->
      let size = resolve_size env typ in
      let _addr =
        try (List.assoc name env.global_vars).addr
        with Not_found ->
          let addr_val = env.next_global_addr in
          env.next_global_addr <- env.next_global_addr + size;
          env.zp_used <- env.zp_used + size;
          if env.zp_used > 0x100 then
            failwith (Printf.sprintf "out of zero-page memory (%d bytes used)" env.zp_used);
          let addr_str = sprintf "$%02x" addr_val in
          let info = { name; addr = addr_str; is_local = false; typ; size } in
          env.global_vars <- (name, info) :: env.global_vars;
          env.zero_order <- ZVar (name, size) :: env.zero_order;
          addr_str
      in
      (match init with
      | Some expr ->
        codegen_rhs env expr size;
        emit_mod_reduce env typ;
        (* Label form, like every other store: raw `$hh` does not
           assemble to a zero-page address in drifblim. *)
        if size = 1 then emit env " .%s STZ\n" name else emit env " .%s STZ2\n" name
      | None -> ())
    | GlobalConstDecl (name, None, expr) ->
      env.constants <- name :: env.constants;
      (match expr with
      | IntLit n ->
        Buffer.add_string env.func_code (sprintf "|%04x @%s\n" n name)
      | Ident id ->
        Buffer.add_string env.func_code (sprintf "|%s @%s\n" id name)
      | _ ->
        Buffer.add_string env.func_code (sprintf "|0000 @%s\n" name))
    | GlobalConstDecl (name, Some typ, expr) ->
      (* Explicit-type constant: zero-page storage slot initialized
         once (assignments are rejected by the checker), read as a
         normal variable — unlike `::` label constants above. *)
      let size = resolve_size env typ in
      let _addr =
        try (List.assoc name env.global_vars).addr
        with Not_found ->
          let addr_val = env.next_global_addr in
          env.next_global_addr <- env.next_global_addr + size;
          env.zp_used <- env.zp_used + size;
          if env.zp_used > 0x100 then
            failwith (Printf.sprintf "out of zero-page memory (%d bytes used)" env.zp_used);
          let addr_str = sprintf "$%02x" addr_val in
          let info = { name; addr = addr_str; is_local = false; typ; size } in
          env.global_vars <- (name, info) :: env.global_vars;
          env.zero_order <- ZVar (name, size) :: env.zero_order;
          addr_str
      in
      codegen_rhs env expr size;
      emit_mod_reduce env typ;
      (* Label form: raw `$hh` does not assemble to a zero-page
         address in drifblim. *)
      if size = 1 then emit env " .%s STZ\n" name else emit env " .%s STZ2\n" name
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
      let total = ref base_size in
      List.iter (fun (_, sz) ->
        env.next_global_addr <- env.next_global_addr + sz;
        total := !total + sz) field_sizes;
      env.zp_used <- env.zp_used + !total;
      if env.zp_used > 0x100 then
        failwith (Printf.sprintf "out of zero-page memory (%d bytes used)" env.zp_used);
      let base_info = { name = g.group_name; addr = sprintf "$%02x" base_addr; is_local = false; typ = g.base_typ; size = base_size } in begin
        env.zero_order <- ZGroup (g.group_name, base_size, field_sizes) :: env.zero_order;
        env.global_vars <- (g.group_name, base_info) :: env.global_vars
      end
    | DataDecl d ->
      Buffer.add_string env.data (sprintf "@%s [ " d.data_name);      List.iter (fun b -> Buffer.add_string env.data (sprintf "%02x " b)) d.data_bytes;
      Buffer.add_string env.data "]\n"
    | AssetDecl a ->
      let bytes = read_asset_bytes a.asset_name a.asset_path in
      Buffer.add_string env.data (sprintf "@%s [ " a.asset_name);
      List.iter (fun b -> Buffer.add_string env.data (sprintf "%02x " b)) bytes;
      Buffer.add_string env.data "]\n"
    | BufferDecl b ->
      let esz = (match b.buf_elem with
        | Ast.TypU8 | Ast.TypBool -> 1
        | Ast.TypU16 -> 2
        | Ast.TypStruct s -> resolve_size env (Ast.TypStruct s)
        | _ -> failwith (Printf.sprintf "buffer `%s` must hold u8/u16/bool" b.buf_name)) in
      let total = esz * b.buf_len in
      let addr = env.next_buffer_addr in
      if addr + total > 0x10000 then
        failwith (Printf.sprintf "buffer `%s` (%d bytes) exceeds addressable memory" b.buf_name total);
      env.next_buffer_addr <- addr + total;
      env.buffer_order <- env.buffer_order @ [(b.buf_name, addr, total)];
      let info = { name = b.buf_name; addr = sprintf "$%04x" addr;
        is_local = false; typ = Ast.TypArray (b.buf_elem, b.buf_len); size = total } in
      env.global_vars <- (b.buf_name, info) :: env.global_vars
    | MetaDecl (title, author) ->
      (* Recorded; the blob + boot wiring emit after the decl loop
         (needs the final device table state — see below). The loader
         already rejects a second `meta {}` anywhere in the splice. *)
      (match env.meta with
      | Some _ -> failwith "duplicate meta block"
      | None -> env.meta <- Some (title, author))
    | StructDecl s ->
      (* Type-level only: field (offset, size) table for `.field`
         access. The checker validated fields and order; holders were
         already allocated by size. Fields are scalar, so typ_size
         cannot fail here. *)
      let (_, fields) =
        List.fold_left (fun (off, acc) (fname, ftyp) ->
          let sz = typ_size ftyp in
          (off + sz, (fname, (off, sz)) :: acc)
        ) (0, []) s.struct_fields
      in
      env.structs <- (s.struct_name, List.rev fields) :: env.structs
    | RawDecl raw ->
      (* Emitted with the data section (main RAM): raw blocks usually
         define data/tables, which drifblim forbids in zero-page.
         Limitation: tal `%macros` pasted via raw land after their
         use sites — prefer native ETAL `macro` instead. *)
      Buffer.add_string env.data raw;
      Buffer.add_string env.data "\n"
  ) program;

  (* Entry sequence comes last in entry_code so global initializers
     above actually run (see note at `|0100`). *)
  (* ROM metadata (proposal 15): blob in the data section plus a
     boot-time `System/metadata` write, per the Varvara convention
     (`@meta 00 "Title 0a "Author 00`, trailing `$2` reserve). The
     System device table is emitted only if the program didn't declare
     its own System device. *)
  (match env.meta with
  | None -> ()
  | Some (title, author) ->
    if not (List.mem_assoc "System" env.devices) then begin
      Buffer.add_string env.func_code "|00 @System/vector $2 &expansion $2 &wst $1 &rst $1 &metadata $2 &r $2 &g $2 &b $2 &debug $1 &state $1\n";
      env.devices <- ("System",
        ["vector", 2; "expansion", 2; "wst", 1; "rst", 1; "metadata", 2;
         "r", 2; "g", 2; "b", 2; "debug", 1; "state", 1]) :: env.devices
    end;
    let hex_of s =
      let b = Buffer.create (String.length s * 3) in
      String.iter (fun c -> Buffer.add_string b (sprintf "%02x " (Char.code c))) s;
      Buffer.contents b
    in
    Buffer.add_string env.data
      (sprintf "@etal_meta [ 00 %s0a %s00 $2 ]\n" (hex_of title) (hex_of author));
    Buffer.add_string env.entry_code ";etal_meta .System/metadata DEO2\n");
  Buffer.add_string env.entry_code ";main JSR2\n";
  Buffer.add_string env.entry_code "HALT\n";
  Buffer.add_string env.entry_code "BRK\n\n";

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
    let is_buffered name =
      List.exists (fun (n, _, _) -> n = name) env.buffer_order
    in
    List.iter (fun (_, info) ->
      if not (List.mem_assoc info.name env.groups) && not (is_buffered info.name) then
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

  (* Main-RAM buffers at absolute addresses. *)
  if List.length env.buffer_order > 0 then begin
    Buffer.add_string buf "\n";
    List.iter (fun (name, addr, total) ->
      Buffer.add_string buf (sprintf "|%04x @%s $%d\n" addr name total)
    ) env.buffer_order;
  end;

  if List.length env.strings > 0 then begin
    Buffer.add_string buf "\n";
    List.iter (fun (label, s) ->
      Buffer.add_string buf (sprintf "@%s %s\n" label (encode_string s))
    ) env.strings
  end;

  Buffer.contents buf
