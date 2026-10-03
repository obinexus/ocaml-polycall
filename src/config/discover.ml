(* Compiler and linker flags for libpolycall, from `pkg-config polycall`
   (polycall >= 1.1.0, binding ABI v1). POLYCALL_CFLAGS / POLYCALL_LIBS
   override pkg-config when both are set. *)
module C = Configurator.V1

let split s = String.split_on_char ' ' s |> List.filter (fun x -> x <> "")

let () =
  C.main ~name:"polycall" (fun c ->
      let cflags, libs =
        match (Sys.getenv_opt "POLYCALL_CFLAGS", Sys.getenv_opt "POLYCALL_LIBS") with
        | Some cflags, Some libs -> (split cflags, split libs)
        | _ -> (
            let query =
              match C.Pkg_config.get c with
              | None -> Error "pkg-config is not installed"
              | Some pc ->
                  C.Pkg_config.query_expr_err pc ~package:"polycall" ~expr:"polycall >= 1.1.0"
            in
            match query with
            | Ok conf -> (conf.C.Pkg_config.cflags, conf.C.Pkg_config.libs)
            | Error why ->
                C.die
                  "libpolycall >= 1.1.0 not found by pkg-config (package 'polycall': %s); \
                   install the Polycall core, set PKG_CONFIG_PATH, or set POLYCALL_CFLAGS \
                   and POLYCALL_LIBS"
                  why)
      in
      C.Flags.write_sexp "c_flags.sexp" cflags;
      C.Flags.write_sexp "c_library_flags.sexp" libs)
