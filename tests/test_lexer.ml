open Token
open Lexer

let () =
  let source = {|import "varvara"|} in
  let tokens = tokenize source in
  List.iter (fun tok ->
    Printf.printf "%s\n" (token_to_string tok)
  ) tokens
