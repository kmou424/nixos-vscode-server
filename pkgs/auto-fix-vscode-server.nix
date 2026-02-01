{
  lib,
  buildFHSEnv,
  runtimeShell,
  writeShellScript,
  writeShellApplication,
  coreutils,
  findutils,
  inotify-tools,
  patchelf,
  stdenv,
  curl,
  icu,
  libunwind,
  libuuid,
  lttng-ust,
  openssl,
  zlib,
  krb5,
  enableFHS ? false,
  nodejsPackage ? null,
  extraRuntimeDependencies ? [ ],
  installPath ? [
    "$HOME/.vscode-server"
    "$HOME/.cursor-server"
  ],
  postPatch ? "",
}:
let
  inherit (lib) makeBinPath makeLibraryPath optionalString;

  # Based on: https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/applications/editors/vscode/generic.nix
  runtimeDependencies = [
    stdenv.cc.libc
    stdenv.cc.cc

    # dotnet
    curl
    icu
    libunwind
    libuuid
    lttng-ust
    openssl
    zlib

    # mono
    krb5
  ]
  ++ extraRuntimeDependencies;

  nodejs = nodejsPackage;
  nodejsFHS = buildFHSEnv {
    name = "node";
    targetPkgs = _: runtimeDependencies;
    extraBuildCommands = ''
      if [[ -d /usr/lib/wsl ]]; then
        # Recursively symlink the lib files necessary for WSL
        # to properly function under the FHS compatible environment.
        # The -s stands for symbolic link.
        cp -rsHf /usr/lib/wsl usr/lib/wsl
      fi
    '';
    runScript = "${nodejs}/bin/node";
    meta = {
      description = ''
        Wrapped variant of Node.js which launches in an FHS compatible envrionment,
        which should allow for easy usage of extensions without Nix-specific modifications.
      '';
    };
  };

  patchELFScript = writeShellApplication {
    name = "patchelf-vscode-server";
    runtimeInputs = [
      coreutils
      findutils
      patchelf
    ];
    text = ''
      bin_dir="$1"
      patched_file="$bin_dir/.nixos-patched"

      # NOTE: We don't log here because it won't show up in the output of the user service.

      # Check if the installation is already full patched.
      if [[ ! -e $patched_file ]] || (( $(< "$patched_file") )); then
        exit 0
      fi

      ${optionalString (!enableFHS) ''
        INTERP=$(< ${stdenv.cc}/nix-support/dynamic-linker)
        RPATH=${makeLibraryPath runtimeDependencies}

        patch_elf () {
          local elf=$1 interp

          # Check if binary is patchable, e.g. not a statically-linked or non-ELF binary.
          if ! interp=$(patchelf --print-interpreter "$elf" 2>/dev/null); then
            return
          fi

          # Check if it is not already patched for Nix.
          if [[ $interp == "$INTERP" ]]; then
            return
          fi

          # Patch the binary based on the binary of Node.js,
          # which should include all dependencies they might need.
          patchelf --set-interpreter "$INTERP" --set-rpath "$RPATH" "$elf"

          # The actual dependencies are probably less than that of Node.js,
          # so shrink the RPATH to only keep those that are actually needed.
          patchelf --shrink-rpath "$elf"
        }

        while read -rd ''' elf; do
          patch_elf "$elf"
        done < <(find "$bin_dir" -type f -perm -100 -printf '%p\0')
      ''}

      # Fix up home-manager session variables sourcing.
      find "$bin_dir/bin" -type f \( -name "code-server*" -o -name "cursor-server" \) -exec sed -i '$i unset __HM_SESS_VARS_SOURCED\n' {} \;

      # Mark the bin directory as being fully patched.
      echo 1 > "$patched_file"

      ${optionalString (
        postPatch != ""
      ) ''${writeShellScript "post-patchelf-vscode-server" postPatch} "$bin_dir"''}
    '';
  };

  autoFixScript = writeShellApplication {
    name = "auto-fix-vscode-server";
    runtimeInputs = [
      coreutils
      findutils
      inotify-tools
    ];
    text = ''
      # Convert installPath list to an array
      IFS=':' read -r -a installPaths <<< "${lib.concatStringsSep ":" installPath}"

      patch_bin () {
        local actual_dir="$1"
        local current_install_path="$2"
        local patched_file="$actual_dir/.nixos-patched"

        if [[ ! -e "$actual_dir/node" ]]; then
          return 0
        fi

        if [[ -e $patched_file ]]; then
          return 0
        fi

        # Backwards compatibility with previous versions of nixos-vscode-server.
        local old_patched_file
        old_patched_file="$(basename "$actual_dir")"
        if [[ $old_patched_file == "server" ]]; then
          old_patched_file="$(basename "$(dirname "$actual_dir")")"
          old_patched_file="$current_install_path/.''${old_patched_file%%.*}.patched"
        else
          old_patched_file="$current_install_path/.''${old_patched_file%%-*}.patched"
        fi
        if [[ -e $old_patched_file ]]; then
          echo "Migrating old nixos-vscode-server patch marker file to new location in $actual_dir." >&2
          cp "$old_patched_file" "$patched_file"
          return 0
        fi

        echo "Patching Node.js of VS Code server installation in $actual_dir..." >&2

        mv "$actual_dir/node" "$actual_dir/node.patched"

        ${optionalString (enableFHS) ''
          ln -sfT ${nodejsFHS}/bin/node "$actual_dir/node"
        ''}

        ${optionalString (!enableFHS || postPatch != "") ''
          cat <<EOF > "$actual_dir/node"
          #!${runtimeShell}

          # The core utilities are missing in the case of WSL, but required by Node.js.
          PATH="\''${PATH:+\''${PATH}:}${makeBinPath [ coreutils ]}"

          # We leave the rest up to the Bash script
          # to keep having to deal with 'sh' compatibility to a minimum.
          ${patchELFScript}/bin/patchelf-vscode-server \$(dirname "\$0")

          # Let Node.js take over as if this script never existed.
          ${
            let
              nodePath = (
                if (nodejs != null) then
                  "${if enableFHS then nodejsFHS else nodejs}/bin/node"
                else
                  ''\$(dirname "\$0")/node.patched''
              );
            in
            ''exec "${nodePath}" "\$@"''
          }
          EOF
          chmod +x "$actual_dir/node"
        ''}

        # Mark the bin directory as being patched.
        echo 0 > "$patched_file"
      }

      # Initialize arrays for bins_dirs_1 and bins_dirs_2
      bins_dirs_1=()
      bins_dirs_2=()

      # Use a delimiter-separated string to map bins_dir -> install_path
      # Format: "bins_dir1|install_path1:bins_dir2|install_path2:..."
      bins_to_install_map=""

      # Populate bins_dirs_1 and bins_dirs_2 based on installPaths
      for current_install_path in "''${installPaths[@]}"; do
        bins_dirs_1+=("$current_install_path/bin")
        bins_to_install_map+="$current_install_path/bin|$current_install_path:"
        shopt -s nullglob
        for platform_dir in "$current_install_path/bin/"*; do
          if [[ -d "$platform_dir" ]]; then
            bins_dirs_1+=("$platform_dir")
            bins_to_install_map+="$platform_dir|$current_install_path:"
          fi
        done
        shopt -u nullglob
        bins_dirs_2+=("$current_install_path/cli/servers")
        bins_to_install_map+="$current_install_path/cli/servers|$current_install_path:"
      done

      # Helper function to get install path from bins_dir
      get_install_path () {
        local target_dir="$1"
        local entry
        IFS=':' read -ra entries <<< "$bins_to_install_map"
        for entry in "''${entries[@]}"; do
          if [[ "$entry" == "$target_dir|"* ]]; then
            echo "''${entry#*|}"
            return 0
          fi
        done
        # Fallback: try to infer from path structure
        dirname "$target_dir"
      }

      # Create directories and patch existing bins
      for bins_dir_1 in "''${bins_dirs_1[@]}"; do
        mkdir -p "$bins_dir_1"
        install_path="$(get_install_path "$bins_dir_1")"
        while read -rd ''' bin; do
          if [[ ! -e "$bin/node" ]]; then
            continue
          fi
          patch_bin "$bin" "$install_path"
        done < <(find "$bins_dir_1" -mindepth 1 -maxdepth 1 -type d -printf '%p\0')
      done
      for bins_dir_2 in "''${bins_dirs_2[@]}"; do
        mkdir -p "$bins_dir_2"
        install_path="$(get_install_path "$bins_dir_2")"
        while read -rd ''' bin; do
          bin="$bin/server"
          patch_bin "$bin" "$install_path"
        done < <(find "$bins_dir_2" -mindepth 1 -maxdepth 1 -type d -printf '%p\0')
      done

      # Watch for new installations by monitoring node file creation
      while IFS=: read -r filepath event; do
        if [[ $event == 'CREATE' || $event == 'MOVED_TO' ]]; then
          # node file was created or moved
          if [[ "$filepath" == */node ]]; then
            node_file="$filepath"
            actual_dir="$(dirname "$node_file")"
            
            # Find install path
            install_path=""
            for check_dir in "''${bins_dirs_1[@]}" "''${bins_dirs_2[@]}"; do
              if [[ "$actual_dir" == "$check_dir"/* ]]; then
                install_path="$(get_install_path "$check_dir")"
                break
              fi
            done
            
            if [[ -z "$install_path" ]]; then
              continue
            fi
            
            # Skip if already patched
            if [[ -e "$actual_dir/.nixos-patched" ]]; then
              continue
            fi
            
            echo "VS Code/Cursor server installation detected in $actual_dir, patching..." >&2
            sleep 0.5
            patch_bin "$actual_dir" "$install_path"
          fi
          
        elif [[ $event == DELETE_SELF ]]; then
          # The monitored directory is deleted
          exit 0
        fi
      done < <(inotifywait -q -m -r -e CREATE -e MOVED_TO -e DELETE_SELF --format '%w%f:%e' "''${bins_dirs_1[@]}" "''${bins_dirs_2[@]}")
    '';
  };
in
autoFixScript
