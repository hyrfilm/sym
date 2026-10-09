{
  description = "sym: CLI (Go) and symd service (Elixir) development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
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
