(lang dune 3.24)

(name etal)

(package
 (name etal)
 (synopsis "ETAL: a small typed DSL compiling to Uxntal for the Uxn VM")
 (description "ETAL is a typed language with functions, events, devices and sprites that compiles to Uxntal (.tal), assembles to ROMs via the vendored uxn toolchain, and bundles single-file native executables or web pages.")
 (depends
  (ocaml (>= 5.0))
  (dune (>= 3.24)))
 (tags ("uxn" "uxntal" "dsl" "compiler")))
