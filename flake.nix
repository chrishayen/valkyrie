{
  description = "Valkyrie HTTP/2 server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        openssl-static = pkgs.openssl.override { static = true; };

        wolfssl-static = pkgs.wolfssl.overrideAttrs (oldAttrs: {
          configureFlags = (oldAttrs.configureFlags or []) ++ [
            "--enable-static"
            "--disable-shared"
            "--enable-tls13"
            "--enable-alpn"
            "--enable-session-ticket"
            "--enable-harden"
            "--enable-extended-master"
            "--enable-sp-math"
          ];
          NIX_CFLAGS_COMPILE = "-march=armv8-a+crypto -O3";
        });
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            odin
            wolfssl-static
            openssl-static
            gnumake
            glibc.static
          ];

          shellHook = ''
            echo "Valkyrie development environment"
            echo "Odin version: $(odin version)"
            echo ""
            echo "Available commands:"
            echo "  make build      - Build the project"
            echo "  make test       - Run tests"
            echo "  make build-arm64 - Cross-compile for ARM64"
          '';
        };
      }
    );
}
