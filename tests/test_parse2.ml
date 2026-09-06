open Token
open Lexer
open Parser

let () =
  let source = {|varvara.console.write("Hello, World!\n")|} in
  let tokens = tokenize source in
  Printf.printf "Tokens:\n";
  List.iter (fun tok ->
    Printf.printf "  %s\n" (token_to_string tok)
  ) tokens;
  Printf.printf "\nParsing statements...\n";
  let p = create_parser tokens in
  let stmts = parse_stmts p in
  Printf.printf "Parsed %d statements\n" (List.length stmts)
