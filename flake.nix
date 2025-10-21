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

        # Architecture-specific wolfSSL builds
        wolfssl-static = pkgs.wolfssl.overrideAttrs (oldAttrs: {
          configureFlags = [
            "--enable-static"
            "--disable-shared"
            "--enable-tls13"
            "--enable-alpn"
            "--enable-session-ticket"
            "--enable-harden"
            "--enable-extended-master"
          ] ++ (if pkgs.stdenv.isAarch64 then [
            "--enable-armasm"
          ] else if pkgs.stdenv.isx86_64 then [
            "--enable-sp"
            "--enable-sp-asm"
            "--enable-intelasm"
            "--enable-aesni"
          ] else []);
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
