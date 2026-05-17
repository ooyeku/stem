{
  description = "stem — modern modal terminal editor in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, zig }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zigPkg = zig.packages.${system}."0.16.0" or zig.packages.${system}.master;
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "stem";
          version = "0.6.0-dev";

          src = ./.;

          nativeBuildInputs = [ zigPkg ];

          # `zig build` fetches its own deps into the Zig cache; we need a
          # writable HOME so the cache can be created during the build.
          configurePhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
          '';

          buildPhase = ''
            zig build -Doptimize=ReleaseFast --prefix $out
          '';

          installPhase = ''
            # `zig build install` already wrote to $out/bin and $out/lib
            mkdir -p $out/lib/stem/plugins
            cp -r $out/lib/*.dylib $out/lib/*.so $out/lib/stem/plugins/ 2>/dev/null || true
          '';

          meta = with pkgs.lib; {
            description = "Modern, approachable modal text editor for the terminal";
            homepage = "https://github.com/ooyeku/stem";
            license = licenses.mit;
            platforms = platforms.unix;
            mainProgram = "stem";
          };
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/stem";
        };

        devShells.default = pkgs.mkShell {
          packages = [ zigPkg pkgs.git ];
        };
      });
}
