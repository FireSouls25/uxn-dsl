(* AST types for Etal *)

type typ =
  | TypU8
  | TypU16
  | TypBool
  | TypVoid
  | TypArray of typ * int
  | TypPointer of typ

type binop =
  | Add | Sub | Mul | Div | Mod
  | And | Or | Xor | Not
  | Lshift | Rshift
  | Eq | Neq | Lt | Gt | Le | Ge
  | AndAnd | OrOr

type unop =
  | Neg | NotBit | Not

type expr =
  | IntLit of int
  | StringLit of string
  | Ident of string
  | BinOp of binop * expr * expr
  | UnOp of unop * expr
  | Call of expr * expr list
  | Index of expr * expr
  | Field of expr * string
  | Assign of expr * expr
  | CompoundLit of string * expr list
  | RawLit of string  (* Raw hex literal like #0a, ;label *)
  | AddrOf of string

type stmt =
  | ExprStmt of expr
  | Return of expr option
  | If of expr * stmt list * (expr * stmt list) list * stmt list
  | While of expr * stmt list
  | For of string * expr * expr * stmt list
  | Block of stmt list
  | VarDecl of string * typ * expr option
  | ConstDecl of string * expr
  | RawStmt of string  (* Raw Uxntal statement *)
  | BrkStmt
  | Goto of string
  | Label of string
  | RPush of expr
  | RPop
  | RPeek

type param = {
  name: string;
  typ: typ;
}

type func = {
  name: string;
  params: param list;
  return_typ: typ option;
  body: stmt list;
  is_event: bool;
}

(* A macro is expanded inline at each call site before type checking.
   Unlike a func (JSR2 call), it costs no jump/return. *)
type macro_decl = {
  macro_name: string;
  macro_params: param list;
  macro_return: typ option;
  macro_body: stmt list;
}

type import = {
  path: string;
}

type device_port = {
  port_name: string;
  port_offset: int;
  port_size: int;
}

type device_decl = {
  device_name: string;
  device_page: int;
  ports: device_port list;
}

type group_decl = {
  group_name: string;
  base_typ: typ;
  fields: (string * typ) list;
}

type data_decl = {
  data_name: string;
  data_bytes: int list;
}

(* An asset embeds a raw sprite file (.chr = 16 bytes/tile 2bpp,
   .icn = 8 bytes/tile 1bpp) as a hex blob at codegen time.
   Declared as `data name = file("path");` with the path resolved
   relative to the file containing the declaration. *)
type asset_decl = {
  asset_name: string;
  asset_path: string;
}

(* A buffer is a fixed-size array in main RAM (absolute addressing).
   Unlike zero-page globals, buffers can hold hundreds of bytes
   (e.g. a screen grid or snake tail ring). *)
type buffer_decl = {
  buf_name: string;
  buf_len: int;
  buf_elem: typ;
}

type decl =
  | FuncDecl of func
  | MacroDecl of macro_decl
  | ImportDecl of import
  | GlobalVarDecl of string * typ * expr option
  | GlobalConstDecl of string * expr
  | DeviceDecl of device_decl
  | GroupDecl of group_decl
  | DataDecl of data_decl
  | AssetDecl of asset_decl
  | BufferDecl of buffer_decl
  | RawDecl of string  (* Raw Uxntal declaration *)

type program = decl list
