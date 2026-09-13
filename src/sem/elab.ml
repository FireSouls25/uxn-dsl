(* Inference elaboration for Etal.
 *
 * Rewrites `:=` declarations (InferDecl/GlobalInferDecl) into explicit
 * VarDecl/GlobalVarDecl by resolving the initializer's type with the
 * type checker. Runs after macro expansion (call sites are concrete,
 * so inferred initializers never see unexpanded macro calls) and
 * before type checking; the checker then sees only explicit nodes.
 *
 * Only the new `:=` syntax is rewritten — every other node passes
 * through untouched, so existing programs elaborate to themselves.
 * Like the checker, this pass is order-dependent (proposal 9 would
 * lift that for both at once): a name must be declared before an
 * inferred initializer can reference it. *)

open Ast

let rec elab_stmts env = function
  | [] -> []
  | s :: rest ->
    let s' =
      match s with
      | InferDecl (n, e) ->
        let t = Types.type_of_expr env e in
        (match t with
        | TypVoid ->
          failwith (Printf.sprintf "cannot infer type of `%s`: void initializer" n)
        | _ -> ());
        Types.add_var env n t;
        VarDecl (n, t, Some e)
      | VarDecl (n, t, _) as v ->
        Types.add_var env n t;
        v
      | ConstDecl (n, typopt, e) as c ->
        (* Register for later inference; the checker validates. *)
        let t =
          match typopt with
          | Some t -> t
          | None -> Types.type_of_expr env e
        in
        Types.add_var env n t;
        c
      | If (c, t, elifs, e) ->
        let child bodies = elab_stmts (Types.create_env (Some env)) bodies in
        If (c, child t,
            List.map (fun (c, b) -> (c, child b)) elifs, child e)
      | While (c, b) ->
        While (c, elab_stmts (Types.create_env (Some env)) b)
      | For (v, s, e, b) ->
        let benv = Types.create_env (Some env) in
        Types.add_var benv v TypU16;
        For (v, s, e, elab_stmts benv b)
      | Block ss -> Block (elab_stmts (Types.create_env (Some env)) ss)
      | _ as s -> s
    in
    s' :: elab_stmts env rest

let elaborate_program program =
  let global_env = Types.create_env None in
  Types.add_func global_env "print"
    [{ name = "msg"; typ = TypPointer TypU8 }] None;
  List.map (function
    | FuncDecl f as d ->
      Types.add_func global_env f.name f.params f.return_typ;
      let fenv = Types.create_env (Some global_env) in
      List.iter (fun (p : param) -> Types.add_var fenv p.name p.typ) f.params;
      (match d with
      | FuncDecl _ -> FuncDecl { f with body = elab_stmts fenv f.body }
      | _ -> assert false)
    | MacroDecl _ as d -> d
    | GlobalInferDecl (n, e) ->
      let t = Types.type_of_expr global_env e in
      (match t with
      | TypVoid ->
        failwith (Printf.sprintf "cannot infer type of `%s`: void initializer" n)
      | _ -> ());
      Types.add_var global_env n t;
      GlobalVarDecl (n, t, Some e)
    | GlobalVarDecl (n, t, _) as d ->
      Types.add_var global_env n t;
      d
    | GlobalConstDecl (n, typopt, e) as d ->
      let t =
        match typopt with
        | Some t -> t
        | None -> Types.type_of_expr global_env e
      in
      Types.add_var global_env n t;
      d
    | DeviceDecl dev as d ->
      let ports = List.map (fun p -> (p.port_name, Types.typ_of_size p.port_size)) dev.ports in
      Types.add_device global_env dev.device_name (("vector", TypU16) :: ports);
      d
    | GroupDecl g as d ->
      Types.add_var global_env g.group_name g.base_typ;
      d
    | BufferDecl b as d ->
      Types.add_var global_env b.buf_name (TypArray (b.buf_elem, b.buf_len));
      d
    | _ as d -> d
  ) program
