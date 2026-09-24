(* Buffer storage must follow every emitted byte, even for ROMs >8KB. *)
open Ast

let find text needle =
  let rec loop i =
    if i + String.length needle > String.length text then
      failwith ("missing output: " ^ needle)
    else if String.sub text i (String.length needle) = needle then i
    else loop (i + 1)
  in loop 0

let () =
  let tal = Codegen.codegen_program [
    BufferDecl { buf_name = "cells"; buf_len = 16; buf_elem = TypU8 };
    BufferDecl { buf_name = "nextbuf"; buf_len = 12; buf_elem = TypU16 };
    FuncDecl { name = "main"; params = []; return_typ = None;
      is_event = false;
      body = [ExprStmt (Call (Ident ("print", Token.nopos),
        [StringLit ("layout", Token.nopos)]))] };
    DataDecl { data_name = "large_asset";
      data_bytes = List.init 9000 (fun _ -> 1) };
  ] in
  let asset = find tal "@large_asset" in
  let text = find tal "@str_0" in
  let cells = find tal "@cells $10\n" in
  let next = find tal "@nextbuf $18\n" in
  assert (asset < text && text < cells && cells < next);
  let has_fixed_origin =
    try ignore (find tal "|2000"); true with Failure _ -> false in
  assert (not has_fixed_origin);
  print_endline "buffer layout OK"
