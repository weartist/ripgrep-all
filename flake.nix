{
  description =
    "ripgrep, but also search in PDFs, E-Books, Office documents, zip, tar.gz, etc.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };

    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
  };

  outputs = { self, nixpkgs, crane, flake-utils, rust-overlay, advisory-db
    , pre-commit-hooks }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };
        inherit (pkgs) lib;

        craneLib = crane.lib.${system};
        src = craneLib.cleanCargoSource ./.;

        buildInputs = with pkgs;
          [ ffmpeg imagemagick pandoc poppler_utils ripgrep tesseract ]
          ++ lib.optionals pkgs.stdenv.isDarwin [
            # Additional darwin specific inputs can be set here
            pkgs.libiconv
          ];

        # Build *just* the cargo dependencies, so we can reuse
        # all of that work (e.g. via cachix) when running in CI
        cargoArtifacts = craneLib.buildDepsOnly { inherit src buildInputs; };

        # Build the actual crate itself, reusing the dependency
        # artifacts from above.
        rga = craneLib.buildPackage {
          inherit cargoArtifacts src buildInputs;
          doCheck = false;
        };

        pre-commit = pre-commit-hooks.lib."${system}".run;
      in {
        # `nix flake check`
        checks = {
          # Build the crate as part of `nix flake check` for convenience
          inherit rga;

          # Run clippy (and deny all warnings) on the crate source,
          # again, resuing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          rga-clippy = craneLib.cargoClippy {
            inherit cargoArtifacts src buildInputs;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          };

          rga-doc = craneLib.cargoDoc { inherit cargoArtifacts src; };

          # Check formatting
          rga-fmt = craneLib.cargoFmt { inherit src; };

          # Audit dependencies
          rga-audit = craneLib.cargoAudit { inherit src advisory-db; };

          # Run tests with cargo-nextest.
          rga-nextest = craneLib.cargoNextest {
            inherit cargoArtifacts src buildInputs;
            partitions = 1;
            partitionType = "count";
          };

          pre-commit = pre-commit {
            src = ./.;
            hooks = {
              nixfmt.enable = true;
              rustfmt.enable = true;
              cargo-check.enable = true;
            };
          };
        } // lib.optionalAttrs (system == "x86_64-linux") {
          # NB: cargo-tarpaulin only supports x86_64 systems
          # Check code coverage (note: this will not upload coverage anywhere)
          rga-coverage =
            craneLib.cargoTarpaulin { inherit cargoArtifacts src; };
        };

        # `nix build`
        packages.default = rga;

        # `nix run`
        apps.default = flake-utils.lib.mkApp { drv = rga; };

        # `nix develop`
        devShells.default = pkgs.mkShell {
          inherit (self.checks.${system}.pre-commit) shellHook;
          inputsFrom = builtins.attrValues self.checks;
          buildInputs = buildInputs
            ++ (with pkgs; [ cargo nixfmt rustc rustfmt ]);
        };
      });
}
