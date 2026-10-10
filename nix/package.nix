{ pkgs }:
let
  inherit (pkgs) lib;
  version = "0.1.0";
  # Recent nixpkgs expose `overrideScope` on the beam scope and make `extend`
  # a throwing alias; before autumn 2026 it was `extend` only. Prefer
  # overrideScope so both this flake's pin and a consumer's `follows` build.
  beam = (pkgs.beamPackages.overrideScope or pkgs.beamPackages.extend) (
    _final: prev: {
      elixir = prev.elixir_1_20;
    }
  );

  # Only source files enter the build. Local profiles, Mix caches, and binaries
  # mustn't become part of the package or affect its dependency hash.
  serviceSource = lib.fileset.toSource {
    root = ../symd;
    fileset = lib.fileset.unions [
      ../symd/lib
      ../symd/test
      ../symd/mix.exs
      ../symd/mix.lock
    ];
  };
  client = (pkgs.buildGoModule.override { go = pkgs.go_1_27; }) {
    pname = "sym-cli";
    inherit version;
    src = lib.fileset.toSource {
      root = ../cli;
      fileset = lib.fileset.fileFilter
        (file: file.hasExt "go" || file.name == "go.mod" || file.name == "go.sum")
        ../cli;
    };
    vendorHash = null;
    __darwinAllowLocalNetworking = true;
  };
  service = beam.mixRelease {
    pname = "symd";
    inherit version;
    src = serviceSource;
    mixFodDeps = beam.fetchMixDeps {
      pname = "symd-deps";
      inherit version;
      src = serviceSource;
      hash = "sha256-MZlj5PNaeDdT83qVsIfLtrli1PKihaQKgGloFoZf+kY=";
    };
    escriptBinName = "../bin/symd";
    preBuild = "mkdir -p ../bin";
    postInstall = ''
      mkdir -p "$out/libexec"
      mv "$out/bin/symd" "$out/libexec/symd.escript"
      makeWrapper ${beam.erlang}/bin/escript "$out/bin/symd" \
        --add-flags "$out/libexec/symd.escript"
    '';
  };
in
pkgs.runCommand "sym-${version}" {
  meta = {
    description = "CLI and service for semantic code queries through language servers";
    mainProgram = "sym";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
} ''
  mkdir -p "$out/bin" "$out/share/sym"
  # Copy the Go binary: os.Executable must find the adjacent symd in this
  # combined output, even when sym itself is reached through a profile symlink.
  cp ${client}/bin/cli "$out/bin/sym"
  ln -s ${service}/bin/symd "$out/bin/symd"
  # Reference material for declarative setups: the agent skill file and an
  # example global config (~/.config/sym/sym.toml).
  cp ${../skills/sym/SKILL.md} "$out/share/sym/SKILL.md"
  cp ${../examples/sym.toml} "$out/share/sym/sym.toml"
''
