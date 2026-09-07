# Nix distribution of the etal compiler (optional).
#
# The canonical build stays native opam/dune (`opam install --deps-only .`
# then `dune build @all`); this flake is a convenience wrapper so Nix users
# can `nix build` / `nix run` / `nix develop` without provisioning an opam
# switch. Same flake covers Linux and macOS (x86_64 + aarch64, including
# Apple Silicon) via flake-utils.eachDefaultSystem. Windows is served
# through WSL: install Nix inside WSL and use this same flake there —
# Nix has no native Windows support.
{
  inputs = {
    opam-nix.url = "github:tweag/opam-nix";
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.follows = "opam-nix/nixpkgs";
    # Fresh opam-repository: opam-nix pins a snapshot that predates dune 3.24
    # (which etal.opam requires), so track upstream here instead. Pinned by
    # flake.lock like everything else, so builds stay reproducible.
    opam-repository = {
      url = "github:ocaml/opam-repository";
      flake = false;
    };
  };

  outputs =
    {
      self,
      flake-utils,
      opam-nix,
      nixpkgs,
      opam-repository,
    }:
    let
      package = "etal";
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        on = opam-nix.lib.${system};
        # ocaml-system takes the compiler from nixpkgs (fast, binary-cached)
        # instead of compiling ocaml-base-compiler from source.
        query = {
          ocaml-system = "*";
        };
        scope = on.buildOpamProject' { repos = [ opam-repository ]; } ./. query;
        overlay = final: prev: {
          ${package} = prev.${package}.overrideAttrs (_: {
            # Prevent the ocaml dependencies from leaking into dependent environments
            doNixSupport = false;
          });
        };
        scope' = scope.overrideScope overlay;
        # The main package containing the executable
        main = scope'.${package};
      in
      {
        packages.default = main;

        apps.default = {
          type = "app";
          program = "${main}/bin/etal";
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ main ];
        };
      }
    );
}
