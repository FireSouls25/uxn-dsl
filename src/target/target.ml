(* Target backends for etal bundles.
 *
 * Code generation is fully host-independent: the front-end produces
 * ROM bytes, and a backend only wraps them in a per-platform carrier.
 * Adding a platform = a new module matching TARGET (plus, for native
 * targets, a row selecting its VM); src/main.ml dispatches on it and
 * never changes per platform. *)

(** A bundle backend: wrap already-assembled ROM bytes into an
    executable artifact for its platform. *)
module type S = sig
  val name : string
  val bundle : verbose:bool -> rom_path:string -> output_file:string -> unit
end

(* Candidate vendor/ directories for a running etal binary: next to
   the exe, then walking up (covers build/<platform>/etal.exe,
   _build/.../main.exe, and legacy layouts). *)
let vendor_candidates () =
  let exe_dir = Filename.dirname Sys.executable_name in
  let up n =
    let rec go acc d = if d = 0 then acc else go (Filename.concat acc "..") (d - 1) in
    go exe_dir n
  in
  List.map (fun n -> Filename.concat (up n) "vendor") [0; 1; 2; 3]

(* Resolve a vendored/dev tool path. Prefers the vendor/ directory next
   to the etal executable, falls back to the uxn2 checkout. *)
let resolve_tool filename =
  let candidates =
    List.map (fun v -> Filename.concat v filename) (vendor_candidates ())
    @ [
      Filename.concat (Filename.dirname Sys.executable_name) filename;
      Filename.concat (Filename.concat (Filename.dirname Sys.executable_name) "../uxn2/bin") filename;
      Filename.concat "uxn2/bin" filename;
      Filename.concat (Filename.concat "vendor" "shared") filename;
    ]
  in
  let rec find = function
    | [] -> Filename.concat "uxn2/bin" filename
    | p :: ps -> if Sys.file_exists p then p else find ps
  in
  find candidates

(* Resolve a vendored directory (e.g. uxn5). Prefers vendor/ next to
   the etal executable, falls back to the checkout layout. *)
let resolve_vendor_dir dirname =
  let candidates =
    List.map (fun v -> Filename.concat v dirname) (vendor_candidates ())
    @ [Filename.concat "vendor" dirname]
  in
  let rec find = function
    | [] -> Filename.concat "vendor" dirname
    | p :: ps -> if Sys.file_exists p && Sys.is_directory p then p else find ps
  in
  find candidates

let copy_file src dst =
  let ic = open_in_bin src in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  let oc = open_out_bin dst in
  output_string oc s;
  close_out oc

let read_file_bin path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s
