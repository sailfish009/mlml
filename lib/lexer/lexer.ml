module Fmt = Tree.Format_string

type token =
  | IntLiteral of int
  | BoolLiteral of bool
  | StringLiteral of string
  | FormatStringLiteral of Fmt.kind list
  | CharLiteral of char
  | CapitalIdent of string
  | LowerIdent of string
  | InfixSymbol of string
  | Plus
  | Minus
  | Star
  | Slash
  | Mod
  | DoubleAnd
  | Let
  | Rec
  | In
  | And
  | Equal
  | NotEqual
  | Lt
  | Gt
  | If
  | Then
  | Else
  | Type
  | Vertical
  | DoubleVertical
  | Excl
  | Of
  | Match
  | With
  | When
  | Fun
  | Arrow
  | Function
  | Comma
  | Semicolon
  | DoubleSemicolon
  | Colon
  | DoubleColon
  | LParen
  | RParen
  | LBracket
  | RBracket
  | LBrace
  | RBrace
  | Dot
  | DoubleDot
  | Apostrophe
  | Module
  | Struct
  | End
  | Open
  | External

let to_digit c = int_of_char c - int_of_char '0'

let string_of_chars chars =
  let buf = Buffer.create 8 in
  List.iter (Buffer.add_char buf) chars;
  Buffer.contents buf
;;

let rec read_int acc rest =
  match rest with
  | h :: t ->
    (match h with '0' .. '9' -> read_int ((acc * 10) + to_digit h) t | _ -> rest, acc)
  | _ -> [], acc
;;

let read_one_char = function
  | '\\' :: t ->
    (match t with
    | '\\' :: rest -> rest, '\\'
    | '"' :: rest -> rest, '"'
    | '\'' :: rest -> rest, '\''
    | 'n' :: rest -> rest, '\n'
    | 'r' :: rest -> rest, '\r'
    | 't' :: rest -> rest, '\t'
    | 'b' :: rest -> rest, '\b'
    | ' ' :: rest -> rest, ' '
    | _ ->
      failwith "Invalid escape sequence" (* TODO: Implement ASCII escape sequences *))
  | c :: rest -> rest, c
  | [] -> failwith "attempt to read a char from empty input"
;;

let rec read_string acc rest =
  let rest, c = read_one_char rest in
  match c with
  | '"' -> rest, acc
  | c ->
    let rest, acc = read_string acc rest in
    rest, c :: acc
;;

let try_read_char tokens =
  let rest, c = read_one_char tokens in
  match rest with '\'' :: rest -> rest, Some c | _ -> tokens, None
;;

let read_char tokens =
  match try_read_char tokens with
  | rest, Some c -> rest, c
  | _, None -> failwith "invalid char literal"
;;

let rec read_ident acc rest =
  match rest with
  | h :: t ->
    (match h with
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' ->
      let rest, ident = read_ident acc t in
      rest, h :: ident
    | _ -> rest, acc)
  | _ -> [], acc
;;

let is_operator_char = function
  | '!' | '$' | '%' | '&' | '*' | '+' | '-' | '.' | '/' | ':' | '<' | '=' | '>' | '?'
  | '@' | '^' | '|' | '~' -> true
  | _ -> false
;;

let rec read_infix_symbol acc = function
  | h :: t when is_operator_char h ->
    let rest, ident = read_infix_symbol acc t in
    rest, h :: ident
  | rest -> rest, acc
;;

let rec tokenize_aux acc rest =
  match rest with
  | [] -> acc
  | '(' :: '*' :: rest ->
    let rec consume_comment level = function
      | '(' :: '*' :: rest -> consume_comment (level + 1) rest
      | '*' :: ')' :: rest when level = 0 -> rest
      | '*' :: ')' :: rest -> consume_comment (level - 1) rest
      | _ :: t -> consume_comment level t
      | [] -> failwith "comment does not end"
    in
    consume_comment 0 rest |> tokenize_aux acc
  | h :: t ->
    (match h with
    | ' ' | '\t' | '\n' -> tokenize_aux acc t
    | '0' .. '9' ->
      let rest, num = read_int 0 rest in
      tokenize_aux (IntLiteral num :: acc) rest
    | '"' ->
      let rest, str = read_string [] t in
      let str_str = string_of_chars str in
      tokenize_aux (StringLiteral str_str :: acc) rest
    | '\'' ->
      (match try_read_char t with
      | rest, Some ch -> tokenize_aux (CharLiteral ch :: acc) rest
      | rest, None -> tokenize_aux (Apostrophe :: acc) rest)
    | 'a' .. 'z' | 'A' .. 'Z' | '_' ->
      let rest, ident = read_ident [] rest in
      let ident_str = string_of_chars ident in
      (match ident_str with
      | "mod" -> tokenize_aux (Mod :: acc) rest
      | "let" -> tokenize_aux (Let :: acc) rest
      | "rec" -> tokenize_aux (Rec :: acc) rest
      | "in" -> tokenize_aux (In :: acc) rest
      | "and" -> tokenize_aux (And :: acc) rest
      | "true" -> tokenize_aux (BoolLiteral true :: acc) rest
      | "false" -> tokenize_aux (BoolLiteral false :: acc) rest
      | "if" -> tokenize_aux (If :: acc) rest
      | "then" -> tokenize_aux (Then :: acc) rest
      | "else" -> tokenize_aux (Else :: acc) rest
      | "type" -> tokenize_aux (Type :: acc) rest
      | "of" -> tokenize_aux (Of :: acc) rest
      | "match" -> tokenize_aux (Match :: acc) rest
      | "with" -> tokenize_aux (With :: acc) rest
      | "when" -> tokenize_aux (When :: acc) rest
      | "fun" -> tokenize_aux (Fun :: acc) rest
      | "function" -> tokenize_aux (Function :: acc) rest
      | "module" -> tokenize_aux (Module :: acc) rest
      | "struct" -> tokenize_aux (Struct :: acc) rest
      | "end" -> tokenize_aux (End :: acc) rest
      | "open" -> tokenize_aux (Open :: acc) rest
      | "external" -> tokenize_aux (External :: acc) rest
      | _ ->
        (match ident_str.[0] with
        | 'A' .. 'Z' -> tokenize_aux (CapitalIdent ident_str :: acc) rest
        | _ -> tokenize_aux (LowerIdent ident_str :: acc) rest))
    | ',' -> tokenize_aux (Comma :: acc) t
    | '(' -> tokenize_aux (LParen :: acc) t
    | ')' -> tokenize_aux (RParen :: acc) t
    | '[' -> tokenize_aux (LBracket :: acc) t
    | ']' -> tokenize_aux (RBracket :: acc) t
    | '{' -> tokenize_aux (LBrace :: acc) t
    | '}' -> tokenize_aux (RBrace :: acc) t
    | '.' ->
      (match t with
      | '.' :: t -> tokenize_aux (DoubleDot :: acc) t
      | _ -> tokenize_aux (Dot :: acc) t)
    | ';' ->
      (match t with
      | ';' :: t -> tokenize_aux (DoubleSemicolon :: acc) t
      | _ -> tokenize_aux (Semicolon :: acc) t)
    | ':' ->
      (match t with
      | ':' :: t -> tokenize_aux (DoubleColon :: acc) t
      | _ -> tokenize_aux (Colon :: acc) t)
    | '!' ->
      (match t with
      | '=' :: t -> tokenize_aux (NotEqual :: acc) t
      | _ -> tokenize_aux (Excl :: acc) t)
    | '=' | '<' | '>' | '@' | '^' | '|' | '&' | '+' | '-' | '*' | '/' | '$' | '%' ->
      let rest, sym = read_infix_symbol [] t in
      let sym_str = string_of_chars (h :: sym) in
      let token =
        match sym_str with
        | "+" -> Plus
        | "-" -> Minus
        | "->" -> Arrow
        | "*" -> Star
        | "/" -> Slash
        | "=" -> Equal
        | "<" -> Lt
        | ">" -> Gt
        | "|" -> Vertical
        | "||" -> DoubleVertical
        | "&&" -> DoubleAnd
        | _ -> InfixSymbol sym_str
      in
      tokenize_aux (token :: acc) rest
    | _ -> failwith @@ Printf.sprintf "unexpected character: '%c'" h)
;;

let string_of_token = function
  | IntLiteral num -> string_of_int num
  | BoolLiteral b -> string_of_bool b
  | StringLiteral str -> Printf.sprintf "\"%s\"" str
  | FormatStringLiteral f -> Printf.sprintf "\"%s\"" (Fmt.string_of_format_string f)
  | CharLiteral ch -> Printf.sprintf "'%c'" ch
  | CapitalIdent ident | LowerIdent ident -> ident
  | InfixSymbol sym -> sym
  | Plus -> "+"
  | Minus -> "-"
  | Star -> "*"
  | Slash -> "/"
  | DoubleAnd -> "&&"
  | Mod -> "mod"
  | Let -> "let"
  | Rec -> "rec"
  | In -> "in"
  | And -> "and"
  | Equal -> "="
  | NotEqual -> "!="
  | Lt -> "<"
  | Gt -> ">"
  | If -> "if"
  | Then -> "then"
  | Else -> "else"
  | Type -> "type"
  | Vertical -> "|"
  | DoubleVertical -> "||"
  | Excl -> "!"
  | Of -> "of"
  | Match -> "match"
  | With -> "with"
  | When -> "when"
  | Fun -> "fun"
  | Arrow -> "->"
  | Function -> "function"
  | Comma -> ","
  | Semicolon -> ";"
  | DoubleSemicolon -> ";;"
  | Colon -> ":"
  | DoubleColon -> "::"
  | LParen -> "("
  | RParen -> ")"
  | LBracket -> "["
  | RBracket -> "]"
  | LBrace -> "{"
  | RBrace -> "}"
  | Dot -> "."
  | DoubleDot -> ".."
  | Apostrophe -> "'"
  | Module -> "module"
  | Struct -> "struct"
  | End -> "end"
  | Open -> "open"
  | External -> "external"
;;

let string_of_tokens tokens =
  let aux acc t = string_of_token t ^ ", " ^ acc in
  List.fold_left aux "" @@ List.rev tokens
;;

let explode s =
  let rec exp i l = if i < 0 then l else exp (i - 1) (s.[i] :: l) in
  exp (String.length s - 1) []
;;

let f source = explode source |> tokenize_aux [] |> List.rev
