open Token
open Lexer

let () =
  let source = "\"Hello, World!\\n\"" in
  Printf.printf "Source: %s\n" source;
  let tokens = tokenize source in
  List.iter (fun tok ->
    Printf.printf "  %s\n" (token_to_string tok)
  ) tokens
