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

        # Shared wolfSSL configuration flags
        wolfssl-base-flags = [
          "--enable-static"
          "--disable-shared"
          "--enable-tls13"
          "--enable-alpn"
          "--enable-session-ticket"
          "--enable-harden"
          "--enable-extended-master"
          "--enable-sp"
          "--enable-sp-asm"
          "--enable-aesgcm=table"
          "--enable-context-extra-user-data"
        ];

        # Architecture-specific wolfSSL builds
        wolfssl-static = pkgs.wolfssl.overrideAttrs (oldAttrs: {
          configureFlags = (oldAttrs.configureFlags or []) ++ wolfssl-base-flags ++
            (if pkgs.stdenv.isAarch64 then [
              "--enable-armasm"
            ] else if pkgs.stdenv.isx86_64 then [
              "--enable-intelasm"
              "--enable-aesni"
            ] else []);
          env = (oldAttrs.env or {}) // {
            NIX_CFLAGS_COMPILE = (oldAttrs.env.NIX_CFLAGS_COMPILE or "") + " " +
              (if pkgs.stdenv.isAarch64
                then "-march=armv8-a+crypto -O3 -DTFM_TIMING_RESISTANT"
                else "-march=native -O3 -DTFM_TIMING_RESISTANT");
          };
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
