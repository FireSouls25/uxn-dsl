(* Lexer for Etal *)

open Token

type lexer = {
  source: string;
  mutable pos: int;
  mutable line: int;
  mutable col: int;
}

let create source = {
  source;
  pos = 0;
  line = 1;
  col = 1;
}

let peek lexer =
  if lexer.pos < String.length lexer.source then
    Some lexer.source.[lexer.pos]
  else
    None

let advance lexer =
  if lexer.pos < String.length lexer.source then begin
    let c = lexer.source.[lexer.pos] in
    lexer.pos <- lexer.pos + 1;
    if c = '\n' then begin
      lexer.line <- lexer.line + 1;
      lexer.col <- 1
    end else
      lexer.col <- lexer.col + 1;
    Some c
  end else
    None

let skip_whitespace lexer =
  let rec loop () =
    match peek lexer with
    | Some c when c = ' ' || c = '\t' || c = '\n' || c = '\r' ->
      ignore (advance lexer);
      loop ()
    | _ -> ()
  in
  loop ()

let skip_comment lexer =
  match peek lexer with
  | Some '(' ->
    (* Only treat ( as comment start if preceded by whitespace/start
       AND followed by whitespace. This keeps (expr) grouping and fn()
       calls working: "(10", "(DateTime" are code, "( comment )" is comment. *)
    let is_comment_start =
      lexer.pos = 0 ||
      (lexer.pos > 0 && let c = lexer.source.[lexer.pos - 1] in
       c = ' ' || c = '\t' || c = '\n' || c = '\r')
    in
    let next_is_space =
      lexer.pos + 1 >= String.length lexer.source ||
      (let c = lexer.source.[lexer.pos + 1] in
       c = ' ' || c = '\t' || c = '\n' || c = '\r')
    in
    if not is_comment_start || not next_is_space then false
    else begin
      let saved_pos = lexer.pos in
      let saved_col = lexer.col in
      ignore (advance lexer);
      (match peek lexer with
      | Some ')' ->
        ignore (advance lexer);
        lexer.pos <- saved_pos;
        lexer.col <- saved_col;
        false
      | _ ->
        let rec loop depth =
          match peek lexer with
          | Some '(' -> 
            ignore (advance lexer);
            loop (depth + 1)
          | Some ')' ->
            ignore (advance lexer);
            if depth > 1 then loop (depth - 1)
          | Some _ ->
            ignore (advance lexer);
            loop depth
          | None -> ()
        in
        loop 1;
        true)
    end
  | Some '/' ->
    (* `//` starts a line comment; a lone `/` is the division operator
       and must NOT consume input. Peek the second char first. *)
    let is_line_comment =
      lexer.pos + 1 < String.length lexer.source &&
      lexer.source.[lexer.pos + 1] = '/'
    in
    if not is_line_comment then false
    else begin
      ignore (advance lexer);
      ignore (advance lexer);
      let rec loop () =
        match peek lexer with
        | Some c when c <> '\n' ->
          ignore (advance lexer);
          loop ()
        | _ -> ()
      in
      loop ();
      true
    end
  | _ -> false
  | _ -> false

let skip_whitespace_and_comments lexer =
  let rec loop () =
    skip_whitespace lexer;
    if skip_comment lexer then
      loop ()
  in
  loop ()

let read_string lexer =
  let buf = Buffer.create 16 in
  let rec loop () =
    match peek lexer with
    | Some '"' ->
      ignore (advance lexer); (* skip closing quote *)
      Buffer.contents buf
    | Some '\\' ->
      ignore (advance lexer);
      (match peek lexer with
      | Some 'n' -> Buffer.add_char buf '\n'; ignore (advance lexer); loop ()
      | Some 't' -> Buffer.add_char buf '\t'; ignore (advance lexer); loop ()
      | Some '\\' -> Buffer.add_char buf '\\'; ignore (advance lexer); loop ()
      | Some '"' -> Buffer.add_char buf '"'; ignore (advance lexer); loop ()
      | Some c -> Buffer.add_char buf c; ignore (advance lexer); loop ()
      | None -> Buffer.contents buf)
    | Some c ->
      Buffer.add_char buf c;
      ignore (advance lexer);
      loop ()
    | None -> Buffer.contents buf
  in
  loop ()

let read_number lexer =
  let start = lexer.pos in
  if lexer.pos + 1 < String.length lexer.source &&
     lexer.source.[lexer.pos] = '0' &&
     (lexer.source.[lexer.pos + 1] = 'x' || lexer.source.[lexer.pos + 1] = 'X') then begin
    lexer.pos <- lexer.pos + 2;
    lexer.col <- lexer.col + 2;
    let hex_start = lexer.pos in
    let rec loop () =
      match peek lexer with
      | Some c when (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') ->
        ignore (advance lexer);
        loop ()
      | _ -> ()
    in
    loop ();
    let len = lexer.pos - hex_start in
    let s = String.sub lexer.source hex_start len in
    int_of_string ("0x" ^ s)
  end else begin
    let rec loop () =
      match peek lexer with
      | Some c when c >= '0' && c <= '9' ->
        ignore (advance lexer);
        loop ()
      | _ -> lexer.pos - start
    in
    let len = loop () in
    int_of_string (String.sub lexer.source start len)
  end

let read_identifier lexer =
  let start = lexer.pos in
  let rec loop () =
    match peek lexer with
    | Some c when (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_' ->
      ignore (advance lexer);
      loop ()
    | _ -> lexer.pos - start
  in
  let len = loop () in
  String.sub lexer.source start len

let keyword_or_ident s =
  match s with
  | "fn" -> FN
  | "event" -> EVENT
  | "return" -> RETURN
  | "if" -> IF
  | "elif" -> ELIF
  | "else" -> ELSE
  | "while" -> WHILE
  | "for" -> FOR
  | "in" -> IN
  | "match" -> MATCH
  | "let" -> LET
  | "const" -> CONST
  | "import" -> IMPORT
  | "raw" -> RAW
  | "macro" -> MACRO
  | "buffer" -> BUFFER
  | "device" -> DEVICE
  | "goto" -> GOTO
  | "data" -> DATA
  | "group" -> GROUP
  | "label" -> LABEL
  | "rpush" -> RPUSH
  | "rpop" -> RPOP
  | "rpeek" -> RPEEK
  | "brk" -> BRK
  | "u8" -> U8
  | "u16" -> U16
  | "bool" -> BOOL
  | "byte" -> BYTE
  | "short" -> SHORT
  | "true" -> INT_LITERAL 1
  | "false" -> INT_LITERAL 0
  | _ -> IDENT s

(* Look at the next non-whitespace character without consuming input. *)
let peek_after_whitespace lexer =
  let i = ref lexer.pos in
  let len = String.length lexer.source in
  while !i < len &&
        (let c = lexer.source.[!i] in
         c = ' ' || c = '\t' || c = '\n' || c = '\r') do
    incr i
  done;
  if !i < len then Some lexer.source.[!i] else None

(* Capture a balanced { ... } slice from source, returning the inner text.
   Braces inside "..." strings and (...) comments don't affect nesting.
   Leaves the lexer positioned after the closing brace. *)
let read_raw_block lexer =
  skip_whitespace lexer;
  (match peek lexer with
  | Some '{' -> ignore (advance lexer)
  | _ -> failwith "Expected { after raw");
  let start = lexer.pos in
  let depth = ref 1 in
  let rec skip_string () =
    match peek lexer with
    | None -> failwith "Unterminated raw block (missing })"
    | Some '\\' -> ignore (advance lexer); ignore (advance lexer); skip_string ()
    | Some '"' -> ignore (advance lexer)
    | Some _ -> ignore (advance lexer); skip_string ()
  in
  let rec skip_paren_comment cdepth =
    match peek lexer with
    | None -> failwith "Unterminated raw block (missing })"
    | Some '(' -> ignore (advance lexer); skip_paren_comment (cdepth + 1)
    | Some ')' ->
      ignore (advance lexer);
      if cdepth > 1 then skip_paren_comment (cdepth - 1)
    | Some '"' -> ignore (advance lexer); skip_string (); skip_paren_comment cdepth
    | Some _ -> ignore (advance lexer); skip_paren_comment cdepth
  in
  let rec loop () =
    match peek lexer with
    | None -> failwith "Unterminated raw block (missing })"
    | Some '{' -> ignore (advance lexer); incr depth; loop ()
    | Some '}' ->
      ignore (advance lexer);
      decr depth;
      if !depth > 0 then loop ()
    | Some '"' -> ignore (advance lexer); skip_string (); loop ()
    | Some '(' -> ignore (advance lexer); skip_paren_comment 1; loop ()
    | Some _ -> ignore (advance lexer); loop ()
  in
  loop ();
  String.sub lexer.source start (lexer.pos - 1 - start)

let next_token lexer =
  skip_whitespace_and_comments lexer;
  match peek lexer with
  | None -> EOF
  | Some c ->
    ignore (advance lexer);
    match c with
    | '+' -> (match peek lexer with
      | Some '=' -> ignore (advance lexer); PLUS_ASSIGN
      | _ -> PLUS)
    | '-' -> (match peek lexer with
      | Some '>' -> ignore (advance lexer); ARROW
      | Some '=' -> ignore (advance lexer); MINUS_ASSIGN
      | _ -> MINUS)
    | '*' -> (match peek lexer with
      | Some '=' -> ignore (advance lexer); STAR_ASSIGN
      | _ -> STAR)
    | '/' -> (match peek lexer with
      | Some '=' -> ignore (advance lexer); SLASH_ASSIGN
      | _ -> SLASH)
    | '%' -> (match peek lexer with
      | Some '=' -> ignore (advance lexer); PERCENT_ASSIGN
      | _ -> PERCENT)
    | '&' -> (match peek lexer with
      | Some '&' -> ignore (advance lexer); AND
      | Some '=' -> ignore (advance lexer); AMP_ASSIGN
      | _ -> AMPERSAND)
    | '|' -> (match peek lexer with
      | Some '|' -> ignore (advance lexer); OR
      | Some '=' -> ignore (advance lexer); PIPE_ASSIGN
      | Some '>' -> ignore (advance lexer); PIPE_ARROW
      | _ -> PIPE)
    | '^' -> (match peek lexer with
      | Some '=' -> ignore (advance lexer); CARET_ASSIGN
      | _ -> CARET)
    | '~' -> TILDE
    | '<' -> (match peek lexer with
      | Some '<' -> ignore (advance lexer); (match peek lexer with
        | Some '=' -> ignore (advance lexer); LSHIFT_ASSIGN
        | _ -> LSHIFT)
      | Some '=' -> ignore (advance lexer); LE
      | _ -> LT)
    | '>' -> (match peek lexer with
      | Some '>' -> ignore (advance lexer); (match peek lexer with
        | Some '=' -> ignore (advance lexer); RSHIFT_ASSIGN
        | _ -> RSHIFT)
      | Some '=' -> ignore (advance lexer); GE
      | _ -> GT)
    | '=' -> (match peek lexer with
      | Some '=' -> ignore (advance lexer); EQ
      | _ -> ASSIGN)
    | '!' -> (match peek lexer with
      | Some '=' -> ignore (advance lexer); NEQ
      | _ -> NOT)
    | '(' -> LPAREN
    | ')' -> RPAREN
    | '{' -> LBRACE
    | '}' -> RBRACE
    | '[' -> LBRACKET
    | ']' -> RBRACKET
    | ',' -> COMMA
    | ':' -> (match peek lexer with
      | Some ':' -> ignore (advance lexer); DOUBLE_COLON
      | _ -> COLON)
    | ';' -> SEMICOLON
    | '.' -> (match peek lexer with
      | Some '.' -> ignore (advance lexer); DOUBLE_DOT
      | _ -> DOT)
    | '_' -> UNDERSCORE
    | '"' -> STRING_LITERAL (read_string lexer)
    | c when c >= '0' && c <= '9' ->
      lexer.pos <- lexer.pos - 1;
      lexer.col <- lexer.col - 1;
      INT_LITERAL (read_number lexer)
    | c when (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_' ->
      lexer.pos <- lexer.pos - 1;
      lexer.col <- lexer.col - 1;
      let word = read_identifier lexer in
      if word = "raw" then
        (match peek_after_whitespace lexer with
        | Some '{' -> RAW_BLOCK (read_raw_block lexer)
        | _ -> RAW)
      else
        keyword_or_ident word
    | _ -> failwith (Printf.sprintf "Unexpected character '%c' at line %d, col %d" c lexer.line lexer.col)

let tokenize source =
  let lexer = create source in
  let tokens = ref [] in
  let rec loop () =
    let token = next_token lexer in
    tokens := token :: !tokens;
    if token <> EOF then loop ()
  in
  loop ();
  List.rev !tokens
