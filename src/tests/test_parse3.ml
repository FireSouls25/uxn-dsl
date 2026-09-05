open Token
open Lexer
open Parser

let () =
  let ic = open_in "../examples/hello.ux" in
  let source = really_input_string ic (in_channel_length ic) in
  close_in ic;
  Printf.printf "Source:\n%s\n---\n" source;
  let tokens = tokenize source in
  Printf.printf "Tokens (%d):\n" (List.length tokens);
  List.iter (fun tok ->
    Printf.printf "  %s\n" (token_to_string tok)
  ) tokens;
  Printf.printf "\nParsing...\n";
  let program = parse tokens in
  Printf.printf "Parsed %d declarations\n" (List.length program)
