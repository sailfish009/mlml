open Builder
module P = Parser
module Expr = P.Expression
module Def = P.Definition
module Item = P.Module_item

let rec codegen_expr ctx buf = function
  | Expr.Int num -> make_marked_const num
  | Expr.Add (lhs, rhs) ->
    (* make(a) + make(b)     *)
    (* = (2a + 1) + (2b + 1) *)
    (* = 2(a + b) + 2        *)
    (* = make(a + b) + 1     *)
    let lhs = codegen_expr ctx buf lhs in
    let rhs, free = codegen_expr ctx buf rhs |> turn_into_register ctx buf in
    emit_instruction buf
    @@ Printf.sprintf "addq %s, %s" (string_of_value lhs) (string_of_register rhs);
    emit_instruction buf @@ Printf.sprintf "decq %s" (string_of_register rhs);
    let s = turn_into_stack ctx buf (RegisterValue rhs) in
    free ctx;
    StackValue s
  | Expr.Sub (lhs, rhs) ->
    (* make(a) - make(b)     *)
    (* = (2a + 1) - (2b + 1) *)
    (* = 2(a - b) *)
    (* = make(a - b) - 1 *)
    let rhs = codegen_expr ctx buf rhs in
    let lhs, free = codegen_expr ctx buf lhs |> turn_into_register ctx buf in
    emit_instruction buf
    @@ Printf.sprintf "subq %s, %s" (string_of_value rhs) (string_of_register lhs);
    emit_instruction buf @@ Printf.sprintf "incq %s" (string_of_register lhs);
    let s = turn_into_stack ctx buf (RegisterValue lhs) in
    free ctx;
    StackValue s
  | Expr.Mul (lhs, rhs) ->
    (* make(a*b)                           *)
    (* = 1/2 * (make(a) - 1) * make(b) + 1 *)
    let lhs, free_l = codegen_expr ctx buf lhs |> turn_into_register ctx buf in
    let rhs, free_r = codegen_expr ctx buf rhs |> turn_into_register ctx buf in
    emit_instruction buf @@ Printf.sprintf "sarq $1, %s" (string_of_register lhs);
    emit_instruction buf @@ Printf.sprintf "decq %s" (string_of_register rhs);
    emit_instruction buf
    @@ Printf.sprintf "imulq %s, %s" (string_of_register lhs) (string_of_register rhs);
    free_l ctx;
    emit_instruction buf @@ Printf.sprintf "incq %s" (string_of_register rhs);
    let s = turn_into_stack ctx buf (RegisterValue rhs) in
    free_r ctx;
    StackValue s
  | Expr.Follow (lhs, rhs) ->
    let _ = codegen_expr ctx buf lhs in
    codegen_expr ctx buf rhs
  | Expr.Var ident ->
    (match ident with
    | "print_int" -> function_ptr ctx buf print_int_label
    | _ -> StackValue (get_variable ctx ident))
  | Expr.LetAnd (is_rec, l, rhs) ->
    let pats, values = emit_let_binding_values ctx buf is_rec l in
    let def (name, ptr) = define_variable ctx buf name ptr in
    let undef (name, _) = undef_variable ctx name in
    List.iter def values;
    let rhs = codegen_expr ctx buf rhs in
    List.iter undef values;
    List.iter (undef_variable_pattern ctx) pats;
    rhs
  | Expr.Lambda (param, body) -> emit_function_value ctx buf false "_lambda" param body
  | Expr.App (lhs, rhs) ->
    let lhs = codegen_expr ctx buf lhs in
    let rhs = codegen_expr ctx buf rhs in
    let ret = safe_call ctx buf (Printf.sprintf "*%s" (string_of_value lhs)) [rhs] in
    StackValue (turn_into_stack ctx buf (RegisterValue ret))
  | Expr.IfThenElse (cond, then_, else_) ->
    let cond = codegen_expr ctx buf cond in
    let eval_stack = push_to_stack ctx buf (ConstantValue 0) in
    let else_label = new_unnamed_label ctx in
    let join_label = new_unnamed_label ctx in
    branch_if_falsy ctx buf cond else_label;
    (* then block *)
    let then_ = codegen_expr ctx buf then_ in
    assign_to_stack ctx buf then_ eval_stack;
    emit_instruction buf @@ Printf.sprintf "jmp %s" (string_of_label join_label);
    (* else block *)
    start_label buf else_label;
    let else_ = codegen_expr ctx buf else_ in
    assign_to_stack ctx buf else_ eval_stack;
    start_label buf join_label;
    StackValue eval_stack
  | Expr.PhysicalEqual (lhs, rhs) ->
    let lhs = codegen_expr ctx buf lhs in
    let rhs = codegen_expr ctx buf rhs in
    comparison_to_value ctx buf Eq lhs rhs
  | Expr.NotPhysicalEqual (lhs, rhs) ->
    let lhs = codegen_expr ctx buf lhs in
    let rhs = codegen_expr ctx buf rhs in
    comparison_to_value ctx buf Ne lhs rhs
  | Expr.Equal (lhs, rhs) ->
    let lhs = codegen_expr ctx buf lhs in
    let rhs = codegen_expr ctx buf rhs in
    let ret = safe_call ctx buf "_mlml_equal" [lhs; rhs] in
    StackValue (turn_into_stack ctx buf (RegisterValue ret))
  | Expr.NotEqual (lhs, rhs) ->
    let lhs = codegen_expr ctx buf lhs in
    let rhs = codegen_expr ctx buf rhs in
    let ret = safe_call ctx buf "_mlml_equal" [lhs; rhs] in
    (* marked bool inversion *)
    (* 11 -> 01              *)
    (* 01 -> 11              *)
    emit_instruction buf @@ Printf.sprintf "xorq $2, %s" (string_of_register ret);
    StackValue (turn_into_stack ctx buf (RegisterValue ret))
  | Expr.Tuple values ->
    let size = List.length values in
    let reg = alloc_register ctx in
    let reg_value = RegisterValue reg in
    alloc_heap_ptr_constsize ctx buf ((size + 1) * 8) reg_value;
    let values = List.map (codegen_expr ctx buf) values in
    assign_to_address ctx buf (ConstantValue (size * 8)) reg_value 0;
    List.iteri (fun i x -> assign_to_address ctx buf x reg_value (-(i + 1) * 8)) values;
    let s = StackValue (turn_into_stack ctx buf reg_value) in
    free_register reg ctx;
    s
  | Expr.Ctor (name, value) ->
    let value =
      match value with
      | Some value -> codegen_expr ctx buf value
      (* TODO: Better representation of ctor without parameters *)
      | None -> make_marked_const 0
    in
    let idx = get_ctor_index ctx name in
    let reg = alloc_register ctx in
    let reg_value = RegisterValue reg in
    (* three 64-bit values -> 24 *)
    alloc_heap_ptr_constsize ctx buf 24 reg_value;
    (* size of data (2 * 8) *)
    assign_to_address ctx buf (ConstantValue 16) reg_value 0;
    (* ctor index *)
    assign_to_address ctx buf (make_marked_const idx) reg_value (-8);
    (* the value *)
    assign_to_address ctx buf value reg_value (-16);
    let s = StackValue (turn_into_stack ctx buf reg_value) in
    free_register reg ctx;
    s
  | Expr.Match (v, arms) ->
    let v = codegen_expr ctx buf v in
    let join_label = new_unnamed_label ctx in
    let eval_stack = push_to_stack ctx buf (ConstantValue 0) in
    let save_stack_c = ctx.current_env.current_stack in
    let rec aux = function
      | (pat, when_, rhs) :: t ->
        (ctx.current_env).current_stack <- save_stack_c;
        let next_label = new_unnamed_label ctx in
        pattern_match ctx buf pat v next_label;
        (match when_ with
        | Some cond ->
          let cond = codegen_expr ctx buf cond in
          branch_if_falsy ctx buf cond next_label
        | None -> ());
        let rhs = codegen_expr ctx buf rhs in
        assign_to_stack ctx buf rhs eval_stack;
        emit_instruction buf @@ Printf.sprintf "jmp %s" (string_of_label join_label);
        start_label buf next_label;
        aux t
      | [] ->
        emit_instruction buf
        @@ Printf.sprintf "jmp %s" (string_of_label match_fail_label);
        start_label buf join_label;
        StackValue eval_stack
    in
    aux arms

and codegen_definition ctx buf = function
  | Def.LetVar (pat, lhs) ->
    let lhs = codegen_expr ctx buf lhs in
    pattern_match ctx buf pat lhs match_fail_label
  | Def.LetFun (is_rec, ident, param, lhs) ->
    let lhs = emit_function_value ctx buf is_rec ident param lhs in
    define_variable ctx buf ident lhs
  | Def.Variant (_, variants) ->
    let aux i (ctor, _) = define_ctor ctx ctor i in
    List.iteri aux variants

and codegen_module_item ctx buf = function
  | Item.Definition def -> codegen_definition ctx buf def
  | Item.Expression expr ->
    let _ = codegen_expr ctx buf expr in
    ()

and codegen_module ctx buf = List.iter (codegen_module_item ctx buf)

and emit_function_with ctx main_buf label fn =
  let old_env = use_env ctx @@ new_local_env () in
  let buf = Buffer.create 100 in
  let ret_label = new_unnamed_label ctx in
  start_global_label buf label;
  emit_instruction buf "pushq %rbp";
  emit_instruction buf "movq %rsp, %rbp";
  emit_instruction buf @@ Printf.sprintf "$replace_with_subq_%s" (string_of_label label);
  (* save registers (non-volatile registers) *)
  let exclude_rbp_rsp = function
    | Register "%rbp" | Register "%rsp" -> false
    | _ -> true
  in
  let saver r = r, turn_into_stack ctx buf (RegisterValue r) in
  let saved_stacks =
    non_volatile_registers |> RS.filter exclude_rbp_rsp |> RS.elements |> List.map saver
  in
  fn ctx buf label ret_label;
  start_label buf ret_label;
  let stack_used = ctx.current_env.current_stack in
  let restore (r, s) = assign_to_register buf (StackValue s) r in
  List.iter restore saved_stacks;
  emit_instruction buf "movq %rbp, %rsp";
  emit_instruction buf "popq %rbp";
  emit_instruction buf "ret";
  let _ = use_env ctx old_env in
  (* TODO: Use more effective and sufficient way to prepend to the buffer *)
  Buffer.add_buffer buf main_buf;
  Buffer.reset main_buf;
  (* TODO: Use more effective way to insert subq instruction *)
  let replace x =
    let s = Printf.sprintf "replace_with_subq_%s" (string_of_label label) in
    if x = s then Printf.sprintf "subq $%d, %%rsp" (-stack_used + 8) else "$" ^ x
  in
  Buffer.add_substitute main_buf replace (Buffer.contents buf)

and emit_let_bindings ctx buf is_rec l =
  (* TODO: remove `failwith "unreachable"` *)
  let part = function Expr.FunBind _ -> true | Expr.VarBind _ -> false in
  let funs, vars = List.partition part l in
  let make_convenient_data = function
    | Expr.FunBind (name, param, body) ->
      let label = new_label ctx name in
      (name, label), (label, param, body)
    | _ -> failwith "unreachable"
  in
  let labels, funs = List.map make_convenient_data funs |> List.split in
  let emit param ast ctx buf _label _ =
    let arg = nth_arg_stack ctx buf 0 in
    pattern_match ctx buf param (StackValue arg) match_fail_label;
    (if is_rec
    then
      (* forward definition of functions *)
      let aux (name, label) =
        let ptr = function_ptr ctx buf label in
        define_variable ctx buf name ptr
      in
      List.iter aux labels);
    let value = codegen_expr ctx buf ast in
    assign_to_register buf value ret_register
  in
  let aux_vars = function
    | Expr.VarBind (pat, body) ->
      let body = codegen_expr ctx buf body in
      pattern_match ctx buf pat body match_fail_label;
      pat
    | _ -> failwith "unreachable"
  in
  let aux_funs (label, param, body) =
    emit_function_with ctx buf label (emit param body)
  in
  (* emit variables first. *)
  (* functions can be forward reference, whereas variables can't. *)
  let pats = List.map aux_vars vars in
  List.iter aux_funs funs;
  pats, labels

and emit_function ctx main_buf is_rec name param ast =
  emit_let_bindings ctx main_buf is_rec [Expr.FunBind (name, param, ast)]
  |> snd
  |> List.hd
  |> snd

and emit_let_binding_values ctx buf is_rec l =
  let pats, labels = emit_let_bindings ctx buf is_rec l in
  let conv (name, label) = name, function_ptr ctx buf label in
  pats, List.map conv labels

and emit_function_value ctx buf is_rec name param ast =
  let label = emit_function ctx buf is_rec name param ast in
  function_ptr ctx buf label

and emit_module ctx buf label items =
  let emit ctx buf _label _ =
    codegen_module ctx buf items;
    assign_to_register buf (ConstantValue 0) ret_register
  in
  emit_function_with ctx buf label emit
;;

let f ast =
  let buf = Buffer.create 100 in
  let ctx = new_context () in
  emit_module ctx buf (Label "main") ast;
  emit_print_int_function buf;
  emit_match_fail buf;
  let _ = emit_function_with ctx buf (Label "_mlml_equal") emit_equal_function in
  Buffer.contents buf
;;
