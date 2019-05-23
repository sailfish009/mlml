let () =
  Tester.expr "if true then 43 else 10";
  Tester.expr "if false then 10 else 40 + 3";
  Tester.expr
    {|
    if 1 = 2
    then 4
    else (
      let a = 10 in
      if a * 2 = 20
      then 43
      else 0
    )
  |};
  Tester.f {|
if false
then print_endline "true";
print_endline "outer!"
  |}
;;
