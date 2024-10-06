{
  description = "A Zig project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };
        zigpkgs = pkgs.zigpkgs;
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zigpkgs.master
            zls
          ];

          shellHook = ''
            echo "Zig development environment"
            echo "Zig version: $(zig version)"
          '';
        };

        packages.default = pkgs.stdenv.mkDerivation {
          name = "zig-project";
          src = ./.;
          nativeBuildInputs = [ zigpkgs.master ];
          buildPhase = "zig build";
        };
      }
    );
}
