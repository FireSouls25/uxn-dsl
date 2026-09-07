(* Path unit tests: OS-independent forward-slash logic, including
   Windows drive/backslash inputs on any host. Run via dune runtest. *)
open Loader

let check name got want =
  if got <> want then begin
    Printf.printf "FAIL %s: got %S want %S\n" name got want;
    exit 1
  end

let () =
  (* separators + drives *)
  check "fwd" (normalize_path "a\\b/c") "a/b/c";
  check "drive" (normalize_path "d:\\a\\b\\x.ux") "D:/a/b/x.ux";
  check "drive-slash" (normalize_path "D:/a/./b") "D:/a/b";
  check "drive-dotdot" (normalize_path "D:/a/../b") "D:/b";
  check "drive-noescape" (normalize_path "D:/../b") "D:/b";
  check "drive-rel" (normalize_path "D:rel/x") "D:/rel/x";
  check "drive-case" (normalize_path "d:/A") "D:/A";
  (* posix *)
  check "abs" (normalize_path "/a/./b//c") "/a/b/c";
  check "abs-noescape" (normalize_path "/../x") "/x";
  check "rel" (normalize_path "a/./b") "a/b";
  check "rel-dotdot" (normalize_path "a/../../b") "../b";
  check "lead-dotdot" (normalize_path "../shared/lib.ux") "../shared/lib.ux";
  check "trail-slash" (normalize_path "a/b/") "a/b";
  (* predicates + join *)
  check "isabs-posix" (string_of_bool (is_absolute_path "/a")) "true";
  check "isabs-drive" (string_of_bool (is_absolute_path "D:\\a")) "true";
  check "isabs-rel" (string_of_bool (is_absolute_path "a/b")) "false";
  check "concat" (concat_fwd "D:\\a\\b" "c.ux") "D:/a/b/c.ux";
  check "concat-abs" (concat_fwd "D:/a" "E:/b") "E:/b";
  check "concat-dotdot" (concat_fwd "/a/b" "../c.ux") "/a/c.ux";
  check "dirname" (dirname_fwd "D:/a/b/c.ux") "D:/a/b";
  Printf.printf "loader paths OK\n"
