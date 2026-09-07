(* Token types for Etal lexer *)

type token =
  (* Literals *)
  | INT_LITERAL of int
  | STRING_LITERAL of string
  | IDENT of string
  
  (* Keywords *)
  | FN
  | EVENT
  | RETURN
  | IF
  | ELIF
  | ELSE
  | WHILE
  | FOR
  | IN
  | MATCH
  | LET
  | CONST
  | IMPORT
  | RAW
  | RAW_BLOCK of string
  | MACRO
  | BUFFER
  | DEVICE
  | GOTO
  | DATA
  | GROUP
  | LABEL
  | RPUSH
  | RPOP
  | RPEEK
  | BRK
  
  (* Types *)
  | U8
  | U16
  | BOOL
  | BYTE
  | SHORT
  
  (* Operators *)
  | PLUS
  | MINUS
  | STAR
  | SLASH
  | PERCENT
  | AMPERSAND
  | PIPE
  | CARET
  | TILDE
  | LSHIFT
  | RSHIFT
  | EQ
  | NEQ
  | LT
  | GT
  | LE
  | GE
  | AND
  | OR
  | NOT
  | ASSIGN
  | PLUS_ASSIGN
  | MINUS_ASSIGN
  | STAR_ASSIGN
  | SLASH_ASSIGN
  | PERCENT_ASSIGN
  | AMP_ASSIGN
  | PIPE_ASSIGN
  | CARET_ASSIGN
  | LSHIFT_ASSIGN
  | RSHIFT_ASSIGN
  
  (* Delimiters *)
  | LPAREN
  | RPAREN
  | LBRACE
  | RBRACE
  | LBRACKET
  | RBRACKET
  | COMMA
  | COLON
  | SEMICOLON
  | DOT
  | ARROW
  | DOUBLE_COLON
  | DOUBLE_DOT
  | PIPE_ARROW
  | UNDERSCORE
  
  (* Special *)
  | EOF

let token_to_string = function
  | INT_LITERAL n -> string_of_int n
  | STRING_LITERAL s -> Printf.sprintf "\"%s\"" s
  | IDENT s -> s
  | FN -> "fn"
  | EVENT -> "event"
  | RETURN -> "return"
  | IF -> "if"
  | ELIF -> "elif"
  | ELSE -> "else"
  | WHILE -> "while"
  | FOR -> "for"
  | IN -> "in"
  | MATCH -> "match"
  | LET -> "let"
  | CONST -> "const"
  | IMPORT -> "import"
  | RAW -> "raw"
  | RAW_BLOCK s -> s
  | MACRO -> "macro"
  | BUFFER -> "buffer"
  | DEVICE -> "device"
  | GOTO -> "goto"
  | DATA -> "data"
  | GROUP -> "group"
  | LABEL -> "label"
  | RPUSH -> "rpush"
  | RPOP -> "rpop"
  | RPEEK -> "rpeek"
  | BRK -> "brk"
  | U8 -> "u8"
  | U16 -> "u16"
  | BOOL -> "bool"
  | BYTE -> "byte"
  | SHORT -> "short"
  | PLUS -> "+"
  | MINUS -> "-"
  | STAR -> "*"
  | SLASH -> "/"
  | PERCENT -> "%"
  | AMPERSAND -> "&"
  | PIPE -> "|"
  | CARET -> "^"
  | TILDE -> "~"
  | LSHIFT -> "<<"
  | RSHIFT -> ">>"
  | EQ -> "=="
  | NEQ -> "!="
  | LT -> "<"
  | GT -> ">"
  | LE -> "<="
  | GE -> ">="
  | AND -> "&&"
  | OR -> "||"
  | NOT -> "!"
  | ASSIGN -> "="
  | PLUS_ASSIGN -> "+="
  | MINUS_ASSIGN -> "-="
  | STAR_ASSIGN -> "*="
  | SLASH_ASSIGN -> "/="
  | PERCENT_ASSIGN -> "%="
  | AMP_ASSIGN -> "&="
  | PIPE_ASSIGN -> "|="
  | CARET_ASSIGN -> "^="
  | LSHIFT_ASSIGN -> "<<="
  | RSHIFT_ASSIGN -> ">>="
  | LPAREN -> "("
  | RPAREN -> ")"
  | LBRACE -> "{"
  | RBRACE -> "}"
  | LBRACKET -> "["
  | RBRACKET -> "]"
  | COMMA -> ","
  | COLON -> ":"
  | SEMICOLON -> ";"
  | DOT -> "."
  | ARROW -> "->"
  | DOUBLE_COLON -> "::"
  | DOUBLE_DOT -> ".."
  | PIPE_ARROW -> "=>"
  | UNDERSCORE -> "_"
  | EOF -> "EOF"
