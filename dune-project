(lang dune 3.8)

(name ocaml-polycall)

(version 1.0.0)

(generate_opam_files true)

(source
 (github obinexus/ocaml-polycall))

(homepage "https://github.com/obinexus/ocaml-polycall")

(bug_reports "https://github.com/obinexus/ocaml-polycall/issues")

(license MIT)

(authors "Nnamdi Michael Okpala <okpalan@protonmail.com>")

(maintainers "Nnamdi Michael Okpala <okpalan@protonmail.com>")

(package
 (name ocaml-polycall)
 (synopsis "OCaml binding for the Polycall C library (binding ABI v1)")
 (description
  "C stubs over libpolycall (https://github.com/obinexus/polycall, polycall >= 1.1.0): library/ABI check, configuration validation, polycall_rpc calls and peer nodes. Blocking calls release the OCaml runtime lock. Links libpolycall through pkg-config.")
 (depends
  (ocaml
   (>= 4.14))
  dune-configurator
  conf-pkg-config))
