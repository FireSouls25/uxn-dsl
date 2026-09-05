open Token
open Lexer
open Parser

let () =
  let source = {|main :: fn() { }|} in
  let tokens = tokenize source in
  Printf.printf "Tokens:\n";
  List.iter (fun tok ->
    Printf.printf "  %s\n" (token_to_string tok)
  ) tokens;
  Printf.printf "\nParsing...\n";
  let program = parse tokens in
  Printf.printf "Parsed %d declarations\n" (List.length program)
