{
  description = "Development shell for rules_move";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/56c02bc00adcf003215cc4bd996d6efaf4cff188";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
    in {
      # Bazel 7.6 for the e2e check's older-Bazel run (see the README).
      packages = nixpkgs.lib.genAttrs systems (system: {
        bazel_7 = (import nixpkgs { inherit system; }).bazel_7;
      });

      devShells = nixpkgs.lib.genAttrs systems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = [ pkgs.bazel_8 pkgs.git ];
            # The official Sui release is an unpatched glibc binary; the rules
            # run it through this pinned loader and these libraries, so no FHS
            # loader (or nix-ld) is needed. See the README.
            MOVE_SUI_LOADER = pkgs.stdenv.cc.bintools.dynamicLinker;
            MOVE_SUI_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.libc pkgs.stdenv.cc.cc.lib ];
          };
        });
    };
}
