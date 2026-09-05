(* Parser for Etal *)

open Token
open Ast

type parser_state = {
  tokens: token list;
  mutable pos: int;
}

let create_parser tokens = {
  tokens;
  pos = 0;
}

let peek parser =
  if parser.pos < List.length parser.tokens then
    List.nth parser.tokens parser.pos
  else
    EOF

let advance parser =
  if parser.pos < List.length parser.tokens then begin
    let token = List.nth parser.tokens parser.pos in
    parser.pos <- parser.pos + 1;
    token
  end else
    EOF

let expect parser expected =
  let token = advance parser in
  if token <> expected then
    failwith (Printf.sprintf "Expected %s, got %s" (token_to_string expected) (token_to_string token))

let expect_ident parser =
  match advance parser with
  | IDENT s -> s
  | t -> failwith (Printf.sprintf "Expected identifier, got %s" (token_to_string t))

let expect_int parser =
  match advance parser with
  | INT_LITERAL n -> n
  | t -> failwith (Printf.sprintf "Expected integer, got %s" (token_to_string t))

let rec parse_typ parser =
  match peek parser with
  | U8 -> ignore (advance parser); TypU8
  | U16 -> ignore (advance parser); TypU16
  | BOOL -> ignore (advance parser); TypBool
  | LBRACKET ->
    ignore (advance parser);
    let size = expect_int parser in
    expect parser RBRACKET;
    let elem_typ = parse_typ parser in
    TypArray (elem_typ, size)
  | AMPERSAND ->
    ignore (advance parser);
    let elem_typ = parse_typ parser in
    TypPointer elem_typ
  | t -> failwith (Printf.sprintf "Expected type, got %s" (token_to_string t))

and parse_primary parser =
  match peek parser with
  | INT_LITERAL n ->
    ignore (advance parser);
    IntLit n
  | STRING_LITERAL s ->
    ignore (advance parser);
    StringLit s
  | IDENT s ->
    ignore (advance parser);
    Ident s
  | LPAREN ->
    ignore (advance parser);
    let expr = parse_expr parser in
    expect parser RPAREN;
    expr
  | t -> failwith (Printf.sprintf "Expected expression, got %s" (token_to_string t))

and parse_expr parser =
  parse_or parser

and parse_or parser =
  let left = parse_and parser in
  let rec loop left =
    match peek parser with
    | OR ->
      ignore (advance parser);
      let right = parse_and parser in
      loop (BinOp (OrOr, left, right))
    | _ -> left
  in
  loop left

and parse_and parser =
  let left = parse_comparison parser in
  let rec loop left =
    match peek parser with
    | AND ->
      ignore (advance parser);
      let right = parse_comparison parser in
      loop (BinOp (AndAnd, left, right))
    | _ -> left
  in
  loop left

and parse_comparison parser =
  let left = parse_bitwise_or parser in
  match peek parser with
  | EQ -> ignore (advance parser); BinOp (Eq, left, parse_bitwise_or parser)
  | NEQ -> ignore (advance parser); BinOp (Neq, left, parse_bitwise_or parser)
  | LT -> ignore (advance parser); BinOp (Lt, left, parse_bitwise_or parser)
  | GT -> ignore (advance parser); BinOp (Gt, left, parse_bitwise_or parser)
  | LE -> ignore (advance parser); BinOp (Le, left, parse_bitwise_or parser)
  | GE -> ignore (advance parser); BinOp (Ge, left, parse_bitwise_or parser)
  | _ -> left

and parse_bitwise_or parser =
  let left = parse_bitwise_xor parser in
  let rec loop left =
    match peek parser with
    | PIPE ->
      ignore (advance parser);
      let right = parse_bitwise_xor parser in
      loop (BinOp (Or, left, right))
    | _ -> left
  in
  loop left

and parse_bitwise_xor parser =
  let left = parse_bitwise_and parser in
  let rec loop left =
    match peek parser with
    | CARET ->
      ignore (advance parser);
      let right = parse_bitwise_and parser in
      loop (BinOp (Xor, left, right))
    | _ -> left
  in
  loop left

and parse_bitwise_and parser =
  let left = parse_shift parser in
  let rec loop left =
    match peek parser with
    | AMPERSAND ->
      ignore (advance parser);
      let right = parse_shift parser in
      loop (BinOp (And, left, right))
    | _ -> left
  in
  loop left

and parse_shift parser =
  let left = parse_add_sub parser in
  let rec loop left =
    match peek parser with
    | LSHIFT ->
      ignore (advance parser);
      let right = parse_add_sub parser in
      loop (BinOp (Lshift, left, right))
    | RSHIFT ->
      ignore (advance parser);
      let right = parse_add_sub parser in
      loop (BinOp (Rshift, left, right))
    | _ -> left
  in
  loop left

and parse_add_sub parser =
  let left = parse_mul_div parser in
  let rec loop left =
    match peek parser with
    | PLUS ->
      ignore (advance parser);
      let right = parse_mul_div parser in
      loop (BinOp (Add, left, right))
    | MINUS ->
      ignore (advance parser);
      let right = parse_mul_div parser in
      loop (BinOp (Sub, left, right))
    | _ -> left
  in
  loop left

and parse_mul_div parser =
  let left = parse_unary parser in
  let rec loop left =
    match peek parser with
    | STAR ->
      ignore (advance parser);
      let right = parse_unary parser in
      loop (BinOp (Mul, left, right))
    | SLASH ->
      ignore (advance parser);
      let right = parse_unary parser in
      loop (BinOp (Div, left, right))
    | PERCENT ->
      ignore (advance parser);
      let right = parse_unary parser in
      loop (BinOp (Mod, left, right))
    | _ -> left
  in
  loop left

and parse_unary parser =
  match peek parser with
  | AMPERSAND ->
    ignore (advance parser);
    (match peek parser with
    | IDENT s ->
      ignore (advance parser);
      AddrOf s
    | _ -> failwith "Expected identifier after &")
  | MINUS ->
    ignore (advance parser);
    let expr = parse_unary parser in
    UnOp (Neg, expr)
  | TILDE ->
    ignore (advance parser);
    let expr = parse_unary parser in
    UnOp (NotBit, expr)
  | NOT ->
    ignore (advance parser);
    let expr = parse_unary parser in
    UnOp (Not, expr)
  | _ -> parse_postfix parser

and parse_postfix parser =
  let left = parse_primary parser in
  let rec loop left =
    match peek parser with
    | LPAREN ->
      ignore (advance parser);
      let args = parse_args parser in
      expect parser RPAREN;
      loop (Call (left, args))
    | LBRACKET ->
      ignore (advance parser);
      let index = parse_expr parser in
      expect parser RBRACKET;
      loop (Index (left, index))
    | DOT ->
      ignore (advance parser);
      let field = expect_ident parser in
      loop (Field (left, field))
    | _ -> left
  in
  loop left

and parse_args parser =
  match peek parser with
  | RPAREN -> []
  | _ ->
    let arg = parse_expr parser in
    let rec loop args =
      match peek parser with
      | COMMA ->
        ignore (advance parser);
        let arg = parse_expr parser in
        loop (arg :: args)
      | _ -> List.rev args
    in
    loop [arg]

let rec parse_stmts parser =
  let rec loop stmts =
    match peek parser with
    | RBRACE | EOF -> List.rev stmts
    | _ ->
      let stmt = parse_stmt parser in
      loop (stmt :: stmts)
  in
  loop []

and parse_stmt parser =
  match peek parser with
  | RETURN ->
    ignore (advance parser);
    (match peek parser with
    | SEMICOLON -> ignore (advance parser); Return None
    | _ ->
      let expr = parse_expr parser in
      expect parser SEMICOLON;
      Return (Some expr))
  | IF ->
    ignore (advance parser);
    let condition = parse_expr parser in
    expect parser LBRACE;
    let then_body = parse_stmts parser in
    expect parser RBRACE;
    let rec parse_elifs () =
      match peek parser with
      | ELIF ->
        ignore (advance parser);
        let elif_cond = parse_expr parser in
        expect parser LBRACE;
        let elif_body = parse_stmts parser in
        expect parser RBRACE;
        (elif_cond, elif_body) :: parse_elifs ()
      | _ -> []
    in
    let elifs = parse_elifs () in
    let else_body =
      match peek parser with
      | ELSE ->
        ignore (advance parser);
        expect parser LBRACE;
        let body = parse_stmts parser in
        expect parser RBRACE;
        body
      | _ -> []
    in
    If (condition, then_body, elifs, else_body)
  | WHILE ->
    ignore (advance parser);
    let condition = parse_expr parser in
    expect parser LBRACE;
    let body = parse_stmts parser in
    expect parser RBRACE;
    While (condition, body)
  | FOR ->
    ignore (advance parser);
    let var_name = expect_ident parser in
    expect parser IN;
    let start_expr = parse_expr parser in
    expect parser DOUBLE_DOT;
    let end_expr = parse_expr parser in
    expect parser LBRACE;
    let body = parse_stmts parser in
    expect parser RBRACE;
    For (var_name, start_expr, end_expr, body)
  | BRK ->
    ignore (advance parser);
    expect parser SEMICOLON;
    BrkStmt
  | GOTO ->
    ignore (advance parser);
    let lbl = expect_ident parser in
    expect parser SEMICOLON;
    Goto lbl
  | LABEL ->
    ignore (advance parser);
    let lbl = expect_ident parser in
    (match peek parser with
    | COLON -> ignore (advance parser)
    | SEMICOLON -> ignore (advance parser)
    | _ -> ());
    Label lbl
  | RPUSH ->
    ignore (advance parser);
    let expr = parse_expr parser in
    expect parser SEMICOLON;
    RPush expr
  | RPOP ->
    ignore (advance parser);
    expect parser SEMICOLON;
    RPop
  | RPEEK ->
    ignore (advance parser);
    expect parser SEMICOLON;
    RPeek
  | LBRACE ->
    ignore (advance parser);
    let body = parse_stmts parser in
    expect parser RBRACE;
    Block body
  | IDENT _ ->
    let saved_pos = parser.pos in
    let name = expect_ident parser in
    let left = ref (Ident name) in
    let rec parse_field_chain () =
      match peek parser with
      | DOT ->
        ignore (advance parser);
        let f = expect_ident parser in
        left := Field (!left, f);
        parse_field_chain ()
      | _ -> ()
    in
    parse_field_chain ();
    (match peek parser with
    | COLON ->
      (match !left with
      | Ident id ->
        ignore (advance parser);
        let typ = parse_typ parser in
        let init =
          match peek parser with
          | ASSIGN ->
            ignore (advance parser);
            Some (parse_expr parser)
          | _ -> None
        in
        expect parser SEMICOLON;
        VarDecl (id, typ, init)
      | _ ->
        parser.pos <- saved_pos;
        let expr = parse_expr parser in
        expect parser SEMICOLON;
        ExprStmt expr)
    | ASSIGN ->
      ignore (advance parser);
      let value = parse_expr parser in
      expect parser SEMICOLON;
      ExprStmt (Assign (!left, value))
    | PLUS_ASSIGN | MINUS_ASSIGN | STAR_ASSIGN | SLASH_ASSIGN | PERCENT_ASSIGN |
      AMP_ASSIGN | PIPE_ASSIGN | CARET_ASSIGN | LSHIFT_ASSIGN | RSHIFT_ASSIGN ->
      let op = advance parser in
      let value = parse_expr parser in
      expect parser SEMICOLON;
      let binop = match op with
        | PLUS_ASSIGN -> Add
        | MINUS_ASSIGN -> Sub
        | STAR_ASSIGN -> Mul
        | SLASH_ASSIGN -> Div
        | PERCENT_ASSIGN -> Mod
        | AMP_ASSIGN -> And
        | PIPE_ASSIGN -> Or
        | CARET_ASSIGN -> Xor
        | LSHIFT_ASSIGN -> Lshift
        | RSHIFT_ASSIGN -> Rshift
        | _ -> failwith "Invalid assignment operator"
      in
      ExprStmt (Assign (!left, BinOp (binop, !left, value)))
    | _ ->
      parser.pos <- saved_pos;
      let expr = parse_expr parser in
      expect parser SEMICOLON;
      ExprStmt expr)
  | _ ->
    let expr = parse_expr parser in
    expect parser SEMICOLON;
    ExprStmt expr

let parse_param parser =
  let name = expect_ident parser in
  expect parser COLON;
  let typ = parse_typ parser in
  { name; typ }

let parse_params parser =
  match peek parser with
  | RPAREN -> []
  | _ ->
    let param = parse_param parser in
    let rec loop params =
      match peek parser with
      | COMMA ->
        ignore (advance parser);
        let param = parse_param parser in
        loop (param :: params)
      | _ -> List.rev params
    in
    loop [param]

let parse_func parser name is_event =
  expect parser LPAREN;
  let params = parse_params parser in
  expect parser RPAREN;
  let return_typ =
    match peek parser with
    | ARROW ->
      ignore (advance parser);
      Some (parse_typ parser)
    | _ -> None
  in
  expect parser LBRACE;
  let body = parse_stmts parser in
  expect parser RBRACE;
  FuncDecl {
    name;
    params;
    return_typ;
    body;
    is_event;
  }

let parse_decl parser =
  match peek parser with
  | MACRO ->
    ignore (advance parser);
    let name = expect_ident parser in
    expect parser LPAREN;
    let params = parse_params parser in
    expect parser RPAREN;
    let return_typ =
      match peek parser with
      | ARROW ->
        ignore (advance parser);
        Some (parse_typ parser)
      | _ -> None
    in
    expect parser LBRACE;
    let body = parse_stmts parser in
    expect parser RBRACE;
    MacroDecl {
      macro_name = name;
      macro_params = params;
      macro_return = return_typ;
      macro_body = body;
    }
  | IMPORT ->
    ignore (advance parser);
    let path =
      match advance parser with
      | STRING_LITERAL s -> s
      | t -> failwith (Printf.sprintf "Expected string literal, got %s" (token_to_string t))
    in
    (match peek parser with
    | SEMICOLON -> ignore (advance parser)
    | _ -> ());
    ImportDecl { path }
  | RAW_BLOCK s ->
    ignore (advance parser);
    RawDecl s
  | RAW ->
    ignore (advance parser);
    (* Legacy form: reads everything until EOF (must be last in file).
       Prefer `raw { ... }`, which captures one balanced block. *)
    let buf = Buffer.create 256 in
    let rec read_raw () =
      match peek parser with
      | EOF -> ()
      | _ ->
        (* For now, just read the next expression as raw text *)
        let tok = advance parser in
        Buffer.add_string buf (token_to_string tok);
        Buffer.add_char buf ' ';
        read_raw ()
    in
    read_raw ();
    RawDecl (Buffer.contents buf)
  | DEVICE ->
    ignore (advance parser);
    let device_name = expect_ident parser in
    let device_page =
      match advance parser with
      | INT_LITERAL n -> n
      | t -> failwith (Printf.sprintf "Expected page number, got %s" (token_to_string t))
    in
    expect parser LBRACE;
    let ports = ref [] in
    let rec parse_ports () =
      match peek parser with
      | RBRACE -> ignore (advance parser)
      | IDENT name ->
        ignore (advance parser);
        expect parser COLON;
        let size =
          match advance parser with
          | INT_LITERAL n -> n
          | t -> failwith (Printf.sprintf "Expected port size, got %s" (token_to_string t))
        in
        ports := { port_name = name; port_offset = 0; port_size = size } :: !ports;
        parse_ports ()
      | _ -> failwith (Printf.sprintf "Expected port or }, got %s" (token_to_string (peek parser)))
    in
    parse_ports ();
    DeviceDecl { device_name; device_page; ports = List.rev !ports }
  | GROUP ->
    ignore (advance parser);
    let group_name = expect_ident parser in
    expect parser COLON;
    let base_typ = parse_typ parser in
    expect parser LBRACE;
    let fields = ref [] in
    let rec parse_fields () =
      match peek parser with
      | RBRACE -> ignore (advance parser)
      | IDENT fname ->
        ignore (advance parser);
        expect parser COLON;
        let ftyp = parse_typ parser in
        fields := (fname, ftyp) :: !fields;
        (match peek parser with
        | COMMA -> ignore (advance parser)
        | SEMICOLON -> ignore (advance parser)
        | _ -> ());
        parse_fields ()
      | _ -> failwith (Printf.sprintf "Expected field or }, got %s" (token_to_string (peek parser)))
    in
    parse_fields ();
    GroupDecl { group_name; base_typ; fields = List.rev !fields }
  | DATA ->
    ignore (advance parser);
    let data_name = expect_ident parser in
    (match peek parser with
    | ASSIGN -> ignore (advance parser)
    | _ -> ());
    expect parser LBRACKET;
    let bytes = ref [] in
    let rec parse_bytes () =
      match peek parser with
      | RBRACKET -> ignore (advance parser)
      | INT_LITERAL n ->
        ignore (advance parser);
        bytes := n :: !bytes;
        (match peek parser with
        | COMMA -> ignore (advance parser)
        | _ -> ());
        parse_bytes ()
      | _ -> failwith (Printf.sprintf "Expected byte or ], got %s" (token_to_string (peek parser)))
    in
    parse_bytes ();
    (match peek parser with
    | SEMICOLON -> ignore (advance parser)
    | _ -> ());
    DataDecl { data_name; data_bytes = List.rev !bytes }
  | IDENT name ->
    ignore (advance parser);
    (match peek parser with
    | DOUBLE_COLON ->
      ignore (advance parser);
      (match peek parser with
      | FN -> ignore (advance parser); parse_func parser name false
      | EVENT -> ignore (advance parser); parse_func parser name true
      | _ ->
        let value = parse_expr parser in
        expect parser SEMICOLON;
        GlobalConstDecl (name, value))
    | COLON ->
      ignore (advance parser);
      let typ = parse_typ parser in
      let init =
        match peek parser with
        | ASSIGN ->
          ignore (advance parser);
          Some (parse_expr parser)
        | _ -> None
      in
      expect parser SEMICOLON;
      GlobalVarDecl (name, typ, init)
    | _ -> failwith (Printf.sprintf "Unexpected token after identifier %s" name))
  | _ -> failwith (Printf.sprintf "Expected declaration, got %s" (token_to_string (peek parser)))

let parse_program parser =
  let rec loop decls =
    match peek parser with
    | EOF -> List.rev decls
    | _ ->
      let decl = parse_decl parser in
      loop (decl :: decls)
  in
  loop []

let parse tokens =
  let parser = create_parser tokens in
  parse_program parser
