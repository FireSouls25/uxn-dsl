open Token
open Lexer

let () =
  let tokens = tokenize {|"Hello, World!\n"|} in
  List.iter (fun tok ->
    Printf.printf "%s\n" (token_to_string tok)
  ) tokens
