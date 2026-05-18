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
            # `zig build install` writes the host binary to $out/bin
            # and each wasm plugin's artifact to $out/bin/*.wasm. The
            # bundled plugin directories (plugin.json + entry
            # artifact) need to be assembled separately so they land
            # under the conventional `<prefix>/lib/stem/plugins/<name>/`
            # layout that the editor's install.sh produces.
            mkdir -p $out/lib/stem/plugins
            install_plugin_dir() {
              local name="$1"
              local artifact="$2"
              local src="bundled/plugins/$name"
              [ -d "$src" ] || return 0
              local dest="$out/lib/stem/plugins/$name"
              mkdir -p "$dest"
              cp "$src/plugin.json" "$dest/"
              if [ -f "$out/bin/$artifact" ]; then
                cp "$out/bin/$artifact" "$dest/"
              fi
            }
            install_plugin_dir echo                echo.wasm
            install_plugin_dir git-wasm            git-wasm.wasm
            install_plugin_dir plugin-manager-wasm plugin-manager-wasm.wasm
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
