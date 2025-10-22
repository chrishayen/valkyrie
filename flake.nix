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

        # Custom wolfSSL with required features, built with static library support
        wolfssl-static = pkgs.wolfssl.overrideAttrs (oldAttrs: {
          configureFlags = (oldAttrs.configureFlags or []) ++ [
            "--enable-alpn"
            "--enable-tls13"
            "--enable-session-ticket"
            "--enable-static"
            "--disable-examples"
            "--disable-crypttests"
          ];
          dontDisableStatic = true;
          doCheck = false;  # Skip tests
          doInstallCheck = false;  # Skip install checks
        });
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            odin
            wolfssl-static
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
