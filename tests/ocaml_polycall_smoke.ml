let expect_equal actual expected message =
  if actual <> expected then begin
    Printf.eprintf "%s: expected %d, got %d\n" message expected actual;
    exit 1
  end

let () =
  expect_equal (Polycall.run_config ~config_path:"explicit-polycallrc" ()) 0
    "explicit path";
  expect_equal (Polycall.run_config ()) 0 "default path";
  expect_equal (Polycall.run_config ~config_path:"__status_37__" ()) 37
    "status preservation";

  begin
    match Polycall.run_config_or_error ~config_path:"__status_37__" () with
    | () ->
        prerr_endline "expected Polycall.Error";
        exit 1
    | exception Polycall.Error 37 -> ()
    | exception Polycall.Error status ->
        Printf.eprintf "expected status 37, got %d\n" status;
        exit 1
  end;

  print_endline "ocaml-polycall OCaml/C smoke test: PASS"
