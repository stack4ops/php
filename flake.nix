# =============================================================================
# flake.nix — PHP-FPM OCI Image
#
# Modelled after the ZenDiS debian image:
#   https://gitlab.opencode.de/oci-community/images/zendis/debian
#
# What happens here:
#   1. nixpkgs provides PHP — no Dockerfile, no apt
#   2. dockerTools.buildLayeredImage assembles the OCI image
#   3. The result is a deterministic .tar.gz — byte-identical given the same inputs
#   4. cibuild integrates this via CIBUILD_BUILD_CLIENT=nix
#
# Stages (mirroring the ZenDiS approach):
#   Stage 1 (this file): nixpkgs-based, easy to learn
#   Stage 2 (later):     container-hardening-work-bench, Debian packages
#                        directly from snapshot.debian.org (like ZenDiS)
#
# Build locally:
#   nix build .#packages.x86_64-linux.php-83-fpm-amd64
#   docker load < result
#   docker run --rm localhost/php:83-fpm-amd64 php --version
#
# Build via cibuild:
#   CIBUILD_BUILD_CLIENT=nix
#   CIBUILD_NIX_FLAKE_ATTR=php-83-fpm-amd64   (or arm64)
# =============================================================================

{
  description = "PHP-FPM OCI image — reproducible build via Nix";

  inputs = {
    # nixpkgs: stable branch — same choice as ZenDiS (nixos-unstable)
    # For production: pin to a specific commit via flake.lock (done automatically by `nix flake update`)
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # -----------------------------------------------------------------------
      # Systems — mirrors the ZenDiS buildSystems / targetSystems split
      #
      # buildSystem:  the machine running `nix build` (amd64 or arm64 host)
      # targetSystem: the OCI image architecture we want to produce
      #
      # Difference from ZenDiS: they cross-compile (x86_64-linux builds arm64).
      # We start with native builds — one runner per arch.
      # This aligns with CIBUILD_BUILD_NATIVE=1 in cibuild.
      # -----------------------------------------------------------------------
      buildSystems  = [ "x86_64-linux" "aarch64-linux" ];
      targetSystems = [ "x86_64-linux" "aarch64-linux" ];

      # Helper: Nix system string → OCI architecture name (like ZenDiS systemToArch)
      systemToArch = system:
        if system == "x86_64-linux" then "amd64" else "arm64";

      # -----------------------------------------------------------------------
      # PHP version — defined centrally, like ZenDiS "versions = [ "13" ]"
      # Later: multiple versions [ "83" "84" ] across branches
      # -----------------------------------------------------------------------
      phpVersion = "83"; # → pkgs.php83

      # -----------------------------------------------------------------------
      # Image metadata
      # -----------------------------------------------------------------------
      imageName  = "php";
      phpVariant = "fpm";
      imageTag   = "${phpVersion}-${phpVariant}";  # e.g. "83-fpm"

      # -----------------------------------------------------------------------
      # Packages for a buildSystem/targetSystem pair
      #
      # ZenDiS uses distrolessHelpers.getPkgsFor here — we use
      # nixpkgs.legacyPackages directly. Simpler entry point, same idea.
      # -----------------------------------------------------------------------
      packagesForSystem = buildSystem: targetSystem:
        let
          arch = systemToArch targetSystem;

          # pkgs: package set for the target system build
          # pkgs.pkgsCross would be the ZenDiS approach for cross-compilation —
          # native for now (buildSystem == targetSystem)
          # use targetSystem so the package set matches the image architecture
          pkgs = nixpkgs.legacyPackages.${targetSystem};

          # -------------------------------------------------------------------
          # PHP — upstream defaults, no additional extensions
          #
          # Matches php:8.3-fpm from Docker Hub: only the extensions compiled
          # into PHP by default (core, ctype, date, dom, fileinfo, filter,
          # hash, iconv, json, mbstring, opcache, openssl, pdo, phar,
          # session, tokenizer, xml, zlib, ...).
          #
          # Extensions belong in app images on top of this base —
          # not in the base image itself. Follows the ZenDiS principle:
          # minimal base, extensions added by consuming images.
          # -------------------------------------------------------------------
          php = pkgs."php${phpVersion}";

          # robust php-fpm binary path detection — location can vary across nixpkgs versions
          phpFpmBin =
            if pkgs.lib.pathExists "${php}/bin/php-fpm"
            then "${php}/bin/php-fpm"
            else "${php}/sbin/php-fpm";

          # -------------------------------------------------------------------
          # /etc/passwd and /etc/group — mirrors ZenDiS etc/passwd etc/group
          #
          # ZenDiS copies these files explicitly into the image via
          # extraFakeRootCommands. We do the same via a small derivation.
          # -------------------------------------------------------------------
          etcFiles = pkgs.runCommand "etc-layer" {} ''
            mkdir -p $out/etc

            # Minimal passwd: root + www-data (uid 33, Debian standard) + nobody
            cat > $out/etc/passwd << 'EOF'
root:x:0:0:root:/root:/bin/sh
www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF

            # Minimal group
            cat > $out/etc/group << 'EOF'
root:x:0:
www-data:x:33:
nobody:x:65534:
EOF

            # Permissions — mirrors ZenDiS
            chmod 644 $out/etc/passwd $out/etc/group
          '';

          # -------------------------------------------------------------------
          # php-fpm configuration
          # Base config shipped as a layer in the image
          # -------------------------------------------------------------------
          phpFpmConfig = pkgs.runCommand "php-fpm-config" {} ''
            mkdir -p $out/etc/php-fpm.d
            mkdir -p $out/var/run
            mkdir -p $out/var/log/php-fpm

            cat > $out/etc/php-fpm.d/www.conf << 'EOF'
[global]
daemonize = no
error_log = /proc/self/fd/2
log_level = warning

[www]
user  = www-data
group = www-data

; TCP socket — no Unix socket so the container is easy to use as-is
listen = 0.0.0.0:9000

pm = dynamic
pm.max_children      = 5
pm.start_servers     = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3

; Log to stdout/stderr — container best practice
access.log  = /proc/self/fd/2
catch_workers_output = yes
EOF
          '';

        in {
          # -----------------------------------------------------------------
          # The OCI image
          #
          # dockerTools.buildLayeredImage:
          #   - produces multiple layers (more efficient than buildImage)
          #   - each element in "contents" becomes its own layer
          #   - reproducible: same inputs → same SHA256
          #
          # ZenDiS equivalent: distrolessHelpers.buildImage
          # -----------------------------------------------------------------
          image = pkgs.dockerTools.buildLayeredImage {
            name = imageName;
            tag  = "${imageTag}-${arch}";

            # Contents: what ends up in the container
            # Order = layer order (least frequently changed first)
            contents = [
              pkgs.dockerTools.caCertificates  # Nix-provided CA certificates
              etcFiles
              phpFpmConfig
              php
              pkgs.tzdata
            ];

            # extraCommands: runs at image build time as the Nix build user
            # Use for mkdir/chmod only — no chown (no root available here)
            extraCommands = ''
              # /tmp must be world-writable with sticky bit
              mkdir -p tmp
              chmod 1777 tmp

              # php-fpm needs /var/run for its PID file
              mkdir -p var/run
              chmod 755 var/run

              # log directory
              mkdir -p var/log/php-fpm
              chmod 755 var/log/php-fpm

              # working directory for www-data
              mkdir -p var/www
              chmod 755 var/www
            '';

            # fakeRootCommands: runs with fakeroot — safe for chown
            # Equivalent to ZenDiS extraFakeRootCommands
            fakeRootCommands = ''
              chown 33:33 var/www
            '';

            config = {
              # explicitly set OCI architecture — without this buildLayeredImage
              # would inherit the build host architecture into the manifest
              architecture = arch;

              # Run php-fpm in the foreground (-F = no daemon)
              Entrypoint = [ phpFpmBin "-F" ];

              # Default CMD: point at the config in /etc/php-fpm.d/
              Cmd = [ "--fpm-config" "/etc/php-fpm.d/www.conf" ];

              # Exposed port — documentation for the container runtime
              ExposedPorts = {
                "9000/tcp" = {};
              };

              # Environment — mirrors ZenDiS extraEnv
              Env = [
                "LANG=C.UTF-8"
                "LC_ALL=C.UTF-8"
                "PATH=${php}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                "TZ=UTC"
              ];

              WorkingDir = "/var/www";

              # Runtime user: www-data (uid 33) — never root
              User = "33:33";

              # OCI labels — mirrors cibuilder LABEL directives
              Labels = {
                "org.opencontainers.image.title"       = "php-fpm";
                "org.opencontainers.image.description" = "PHP-FPM OCI image — reproducible build via Nix";
                "org.opencontainers.image.licenses"    = "MIT";
                "org.opencontainers.image.source"      = "https://gitlab.opencode.de/oci-community/images/php";
              };
            };
          };
        };

      # -----------------------------------------------------------------------
      # Assemble all packages
      #
      # ZenDiS structure: packages.<buildSystem>.<name> = <derivation>
      # Name scheme: "<image>-<phpver>-<variant>-<arch>" → "php-83-fpm-amd64"
      # -----------------------------------------------------------------------
      packagesForBuildSystem = buildSystem:
        builtins.listToAttrs (map (targetSystem:
          let
            arch = systemToArch targetSystem;
            pkg  = packagesForSystem buildSystem targetSystem;
          in {
            name  = "${imageName}-${phpVersion}-${phpVariant}-${arch}";
            value = pkg.image;
          }
        ) targetSystems);

    in {
      # -----------------------------------------------------------------------
      # Outputs — what `nix build` and cibuild see
      #
      # Access:
      #   nix build .#packages.x86_64-linux.php-83-fpm-amd64
      #   nix build .#packages.x86_64-linux.php-83-fpm-arm64   (cross — later)
      # -----------------------------------------------------------------------
      packages = builtins.listToAttrs (map (buildSystem: {
        name  = buildSystem;
        value = packagesForBuildSystem buildSystem;
      }) buildSystems);
    };
}
