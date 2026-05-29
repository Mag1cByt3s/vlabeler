{
  description = "vLabeler - voice labeling application";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Gradle 7.3.3 (pinned by the wrapper) only supports up to JDK 17, so
        # the Gradle daemon must use OpenJDK 17.
        buildJdk = pkgs.jdk17;

        # JetBrains Runtime — used to actually launch vLabeler. We bypass
        # compose-jb's `run` task because injecting our own `executable` into
        # it never reliably stuck. Instead we read the run task's classpath,
        # mainClass, and system properties via an init script and then
        # exec JBR ourselves.
        runtimeJdk = pkgs.jetbrains.jdk;
        jbrJava = "${runtimeJdk}/lib/openjdk/bin/java";

        # Default HiDPI scale. Override at run time:
        #   VLABELER_UI_SCALE=1.5 nix run
        defaultUiScale = "1.5";

        runtimeLibs = with pkgs; [
          # Compose Desktop / Skiko
          libGL fontconfig freetype stdenv.cc.cc.lib
          # X11 (also used under XWayland)
          libx11 libxrender libxtst libxi libxext libxxf86vm libxcursor libxrandr
          # VLC for vlcj
          vlc
          # GTK for lwjgl-nfd (native file dialog)
          gtk3 glib
          # Audio
          alsa-lib
        ];

        libraryPath = pkgs.lib.makeLibraryPath runtimeLibs;

        # GLib aborts (SIGABRT, exit 134) when it can't find its compiled
        # GSettings schemas — this is what kills vLabeler when the GTK file
        # picker opens. Point XDG_DATA_DIRS at the schema dirs.
        schemaDataDirs = with pkgs; pkgs.lib.concatStringsSep ":" [
          "${gsettings-desktop-schemas}/share/gsettings-schemas/${gsettings-desktop-schemas.name}"
          "${gtk3}/share/gsettings-schemas/${gtk3.name}"
        ];

        # Gradle init script: register a task that dumps the run task's
        # classpath, mainClass, and full JVM args (system properties + jvmArgs +
        # locale defaults — everything Gradle would normally pass) to files
        # we can pick up from the shell wrapper.
        dumpInitScript = pkgs.writeText "vlabeler-dump-init.gradle" ''
          allprojects {
              afterEvaluate {
                  tasks.register("vlabelerDumpRunConfig") {
                      dependsOn("jvmJar", "prepareAppResources")
                      doLast {
                          def run = tasks.findByName("run")
                          if (!(run instanceof JavaExec)) {
                              throw new GradleException("expected 'run' to be JavaExec, got: " + (run == null ? "null" : run.getClass().name))
                          }
                          def outDir = new File(System.getenv("VLABELER_CONFIG_DIR"))
                          new File(outDir, "cp.txt").text   = run.classpath.asPath
                          new File(outDir, "main.txt").text = run.mainClass.get()
                          new File(outDir, "args.txt").text = run.allJvmArgs.join("\n")
                      }
                  }
              }
          }
        '';

        # Source patch: adds LocalDensity override to Main.kt so our
        # -Dvlabeler.uiScale=N takes effect. Kept as a separate file so the
        # project source stays unmodified in git — the wrapper applies it
        # before each build and reverts it on exit (including Ctrl-C).
        uiScalePatch = ./nix/main-kt-uiscale.patch;

        vlabelerRun = pkgs.writeShellScript "vlabeler-run" ''
          set -euo pipefail

          # Clear JVM env-var overrides so a stray JAVA_TOOL_OPTIONS in the
          # caller's shell (e.g. "-Dsun.java2d.uiScale=1.5" left over from
          # debugging) can't shadow our -D flags. JAVA_TOOL_OPTIONS is parsed
          # *after* the command line and wins on duplicate -D properties.
          unset JAVA_TOOL_OPTIONS _JAVA_OPTIONS JDK_JAVA_OPTIONS

          export JAVA_HOME=${buildJdk}/lib/openjdk
          export PATH=${buildJdk}/bin:${pkgs.git}/bin:$PATH
          export LD_LIBRARY_PATH=${libraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
          export XDG_DATA_DIRS=${schemaDataDirs}''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}

          SCALE="''${VLABELER_UI_SCALE:-${defaultUiScale}}"

          # Stage 0: apply the uiScale patch to Main.kt. Tracked so we only
          # revert what we applied (the user may already have it applied, in
          # which case we leave the tree as we found it).
          PATCH=${uiScalePatch}
          PATCHED_BY_US=0
          if git apply --reverse --check "$PATCH" 2>/dev/null; then
              # Patch is already applied; leave the tree as-is on exit.
              :
          elif git apply --check "$PATCH" 2>/dev/null; then
              git apply "$PATCH"
              PATCHED_BY_US=1
          else
              echo "Error: nix/main-kt-uiscale.patch can neither be applied nor is already applied." >&2
              echo "Resolve any local edits to Main.kt and retry." >&2
              exit 1
          fi

          CONFIG_DIR=$(mktemp -d)
          cleanup() {
              rm -rf "$CONFIG_DIR"
              if [ "$PATCHED_BY_US" = "1" ]; then
                  git apply --reverse "$PATCH" 2>/dev/null || \
                      echo "Warning: failed to revert nix/main-kt-uiscale.patch — check 'git diff'." >&2
              fi
          }
          trap cleanup EXIT INT TERM
          export VLABELER_CONFIG_DIR="$CONFIG_DIR"

          # Stage 1: build vLabeler and extract the run task's exact configuration.
          # Gradle daemon uses OpenJDK 17 (compatible with gradle 7.3.3).
          echo ">>> vlabeler-run: building (using gradle 7.3.3 + OpenJDK 17)..."
          ./gradlew --init-script ${dumpInitScript} vlabelerDumpRunConfig

          CP=$(< "$CONFIG_DIR/cp.txt")
          MAIN=$(< "$CONFIG_DIR/main.txt")

          # Stage 2: replay the full JVM arg list (compose system properties,
          # -Xmx2G, locale defaults, ...) against JBR, then append our uiScale
          # override last so it wins.
          ARGS=()
          while IFS= read -r line; do
              [[ -n "$line" ]] && ARGS+=("$line")
          done < "$CONFIG_DIR/args.txt"
          # vlabeler.uiScale is what the patched Main.kt reads — JBR's Wayland
          # support overwrites sun.java2d.uiScale during AWT init, but it
          # leaves our custom property alone. We still pass sun.java2d.uiScale
          # for any non-Wayland / non-JBR runtime where it does take effect.
          ARGS+=("-Dvlabeler.uiScale=$SCALE")
          ARGS+=("-Dsun.java2d.uiScale=$SCALE")

          # Don't `exec` — we need the trap to fire so the patch is reverted.
          echo ">>> vlabeler-run: launching JBR ${runtimeJdk.version} with uiScale=$SCALE"
          ${jbrJava} "''${ARGS[@]}" -cp "$CP" "$MAIN"
        '';
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            buildJdk
            (pkgs.writeShellScriptBin "vlabeler-run" ''exec ${vlabelerRun} "$@"'')
          ];

          JAVA_HOME = "${buildJdk}/lib/openjdk";
          LD_LIBRARY_PATH = libraryPath;

          shellHook = ''
            export XDG_DATA_DIRS="${schemaDataDirs}''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"

            echo "vLabeler dev shell"
            echo "  Build JDK:  $(java -version 2>&1 | head -1)"
            echo "  Runtime:    JBR ${runtimeJdk.version} (used to launch the app, supports HiDPI)"
            echo ""
            echo "  vlabeler-run                # launch with HiDPI scale ${defaultUiScale}"
            echo "  VLABELER_UI_SCALE=1.5 vlabeler-run"
            echo "  ./gradlew packageDistributionForCurrentOS"
          '';
        };

        apps.default = {
          type = "app";
          program = toString vlabelerRun;
        };
      });
}
