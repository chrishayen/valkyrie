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

        s2n-tls-static = (pkgs.s2n-tls.override {
          openssl = openssl-static;
        }).overrideAttrs (oldAttrs: {
          cmakeFlags = (oldAttrs.cmakeFlags or []) ++ [
            "-DBUILD_SHARED_LIBS=OFF"
          ];
        });
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            odin
            s2n-tls-static
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
