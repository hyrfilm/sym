{
  description = "sym: semantic code queries for agents — Go CLI, Elixir daemon, LSP underneath";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        package = import ./nix/package.nix { inherit pkgs; };
      in {
        packages.default = package;
        packages.sym = package;
        apps.default = {
          type = "app";
          program = "${package}/bin/sym";
        };
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.just
            pkgs.go_1_27
            pkgs.beamPackages.elixir_1_20
            pkgs.beamPackages.erlang
          ];
        };
      });
}
