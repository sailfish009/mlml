module Pat = Tree.Pattern
module Expr = Tree.Expression
module Item = Tree.Module_item

let make_name = Printf.sprintf "%s%d"

let rename env s =
  let idx =
    match Hashtbl.find_opt env s with
    | Some c ->
      Hashtbl.replace env s (c + 1);
      c
    | None ->
      Hashtbl.add env s 1;
      0
  in
  make_name s idx
;;

let find env s =
  let idx = Hashtbl.find env s in
  make_name s idx
;;

let copy_env env = Hashtbl.copy env

let rec replace_pattern env p =
  match p with
  | Pat.Var name -> Pat.Var (rename env name)
  | Pat.Wildcard | Pat.Int _ | Pat.String _ | Pat.Nil | Pat.Range _ -> p
  | Pat.Tuple l ->
    let l = List.map (replace_pattern env) l in
    Pat.Tuple l
  | Pat.Ctor (_name, None) -> p
  | Pat.Ctor (name, Some param) ->
    let param = replace_pattern env param in
    Pat.Ctor (name, Some param)
  | Pat.Or (a, b) ->
    let a = replace_pattern env a in
    let b = replace_pattern env b in
    Pat.Or (a, b)
  | Pat.Cons (a, b) ->
    let a = replace_pattern env a in
    let b = replace_pattern env b in
    Pat.Or (a, b)
  | Pat.Record l ->
    let aux (field, pat) =
      let pat = replace_pattern env pat in
      field, pat
    in
    let l = List.map aux l in
    Pat.Record l
;;

let rec convert_expr env e =
  match e with
  | Expr.LetAnd (is_rec, l, in_) ->
    let aux env = function
      | Expr.VarBind (p, body) ->
        let body = convert_expr env body in
        let p = replace_pattern env p in
        Expr.VarBind (p, body)
      | Expr.FunBind (name, p, body) ->
        let name = rename env name in
        let inner_env = copy_env env in
        let p = replace_pattern inner_env p in
        let body = convert_expr inner_env body in
        Expr.FunBind (name, p, body)
    in
    let new_env = copy_env env in
    let l = List.map (aux new_env) l in
    let in_ = convert_expr new_env in_ in
    Expr.LetAnd (is_rec, l, in_)
  | Expr.Var name -> Expr.Var (find env name)
  | Expr.Lambda (p, body) ->
    let new_env = copy_env env in
    let p = replace_pattern new_env p in
    let body = convert_expr new_env body in
    Expr.Lambda (p, body)
  | Expr.Match (expr, l) ->
    let aux (p, when_, arm) =
      let new_env = copy_env env in
      let p = replace_pattern new_env p in
      let when_ =
        match when_ with Some when_ -> Some (convert_expr new_env when_) | None -> None
      in
      let arm = convert_expr new_env arm in
      p, when_, arm
    in
    let expr = convert_expr env expr in
    let l = List.map aux l in
    Expr.Match (expr, l)
  | Expr.Nil | Expr.Int _ | Expr.String _ -> e
  | Expr.Tuple l -> Expr.Tuple (List.map (convert_expr env) l)
  | Expr.BinOp (op, l, r) -> Expr.BinOp (op, convert_expr env l, convert_expr env r)
  | Expr.IfThenElse (cond, then_, else_) ->
    Expr.IfThenElse
      (convert_expr env cond, convert_expr env then_, convert_expr env else_)
  | Expr.App (l, r) -> Expr.App (convert_expr env l, convert_expr env r)
  | Expr.Ctor (_name, None) -> e
  | Expr.Ctor (name, Some param) -> Expr.Ctor (name, Some (convert_expr env param))
  | Expr.Record fields ->
    let aux' (name, expr) = name, convert_expr env expr in
    Expr.Record (List.map aux' fields)
  | Expr.RecordField (v, field) -> Expr.RecordField (convert_expr env v, field)
  | Expr.RecordUpdate (e, fields) ->
    let aux' (name, expr) = name, convert_expr env expr in
    Expr.RecordUpdate (convert_expr env e, List.map aux' fields)
;;

let convert_module_item env = function
  | Item.Expression expr -> Item.Expression (convert_expr env expr)
  | Item.Definition _defn -> failwith "unimplemented"
;;

let f = List.map (convert_module_item @@ Hashtbl.create 32)
