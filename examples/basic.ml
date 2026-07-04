let () =
  let config_path =
    if Array.length Sys.argv > 1 then Sys.argv.(1)
    else Polycall.default_config
  in
  try
    Polycall.run_config_or_error ~config_path ();
    print_endline "libpolycall completed successfully"
  with
  | Polycall.Error status ->
      Printf.eprintf "libpolycall failed with status %d\n" status;
      exit status
