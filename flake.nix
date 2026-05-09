# =============================================================================
# flake.nix — PHP-FPM OCI Image
#
# Modelled after the ZenDiS debian/python3 images:
#   https://gitlab.opencode.de/oci-community/images/zendis/debian
#   https://gitlab.opencode.de/oci-community/images/zendis/python3
#
# What happens here:
#   1. nixpkgs provides PHP — no Dockerfile, no apt
#   2. dockerTools.buildLayeredImage assembles the OCI image
#   3. bombon generates a CycloneDX SBOM as a separate Nix package
#   4. The result is deterministic — byte-identical given the same inputs
#   5. cibuild integrates this via CIBUILD_BUILD_CLIENT=nix
#
# Build locally:
#   nix build .#packages.x86_64-linux."8.3-fpm-amd64"
#   docker load < result
#   docker run --rm localhost/php:8.3-fpm-amd64 php --version
#
#   nix build .#packages.x86_64-linux."8.3-fpm-amd64-sbom"
#   ls result/  # → sbom.cdx.json
#
# Build via cibuild (branch "8.3-fpm"):
#   CIBUILD_BUILD_CLIENT=nix
#   CIBUILD_BUILD_NATIVE=1
#   → flake attr derived automatically: 8.3-fpm-amd64
# =============================================================================

{
  description = "PHP-FPM OCI image — reproducible build via Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # bombon: CycloneDX SBOM generation for Nix derivations
    # Generates SBOMs directly from the Nix dependency graph — no image scanning
    # BSI TR-03183 and US EO 14028 compliant
    # Mirrors ZenDiS container-hardening/nix/sbom.nix approach
    # Usage: bombon.lib.${system}.buildBom <derivation> { }
    bombon = {
      url = "github:nikstur/bombon";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # sbomnix: vulnerability scanning for Nix packages via Repology/OSV
    # vulnxscan scans runtime dependencies against CVE databases
    # aggregates: NVD, OSV, Debian Security, GitHub Advisories via Repology
    sbomnix = {
      url = "github:tiiuae/sbomnix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, bombon, sbomnix }:
    let
      buildSystems  = [ "x86_64-linux" "aarch64-linux" ];
      targetSystems = [ "x86_64-linux" "aarch64-linux" ];

      systemToArch = system:
        if system == "x86_64-linux" then "amd64" else "arm64";

      # renovate: datasource=repology depName=nix_unstable/php83 versioning=loose
      # php-version: 8.3.21
      phpVersion = "8.3";   # used in image tag and flake attribute: 8.3-fpm-amd64
      phpPkgAttr = "php83"; # nixpkgs attribute name — pkgs.php83

      imageName  = "php";
      phpVariant = "fpm";
      imageTag   = "${phpVersion}-${phpVariant}";  # e.g. "8.3-fpm"

      packagesForSystem = buildSystem: targetSystem:
        let
          arch = systemToArch targetSystem;

          # use targetSystem so the package set matches the image architecture
          pkgs = nixpkgs.legacyPackages.${targetSystem};

          php = pkgs.${phpPkgAttr};

          # robust php-fpm binary path detection
          phpFpmBin =
            if pkgs.lib.pathExists "${php}/bin/php-fpm"
            then "${php}/bin/php-fpm"
            else "${php}/sbin/php-fpm";

          etcFiles = pkgs.runCommand "etc-layer" {} ''
            mkdir -p $out/etc
            cat > $out/etc/passwd << 'EOF'
root:x:0:0:root:/root:/bin/sh
www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF
            cat > $out/etc/group << 'EOF'
root:x:0:
www-data:x:33:
nobody:x:65534:
EOF
            chmod 644 $out/etc/passwd $out/etc/group
          '';

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
listen = 0.0.0.0:9000
pm = dynamic
pm.max_children      = 5
pm.start_servers     = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
access.log  = /proc/self/fd/2
catch_workers_output = yes
EOF
          '';

          image = pkgs.dockerTools.buildLayeredImage {
            name = imageName;
            tag  = "${imageTag}-${arch}";
            contents = [
              pkgs.dockerTools.caCertificates
              etcFiles
              phpFpmConfig
              php
              pkgs.tzdata
            ];
            extraCommands = ''
              mkdir -p tmp && chmod 1777 tmp
              mkdir -p var/run && chmod 755 var/run
              mkdir -p var/log/php-fpm && chmod 755 var/log/php-fpm
              mkdir -p var/www && chmod 755 var/www
            '';
            fakeRootCommands = ''
              chown 33:33 var/www
            '';
            config = {
              architecture = arch;
              Entrypoint = [ phpFpmBin "-F" ];
              Cmd = [ "--fpm-config" "/etc/php-fpm.d/www.conf" ];
              ExposedPorts = { "9000/tcp" = {}; };
              Env = [
                "LANG=C.UTF-8"
                "LC_ALL=C.UTF-8"
                "PATH=${php}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                "TZ=UTC"
              ];
              WorkingDir = "/var/www";
              User = "33:33";
              Labels = {
                "org.opencontainers.image.title"       = "php-fpm";
                "org.opencontainers.image.description" = "PHP-FPM OCI image — reproducible build via Nix";
                "org.opencontainers.image.licenses"    = "MIT";
                "org.opencontainers.image.source"      = "https://gitlab.opencode.de/oci-community/images/php";
                # version label — used by cibuild to derive minor/patch image tags
                # e.g. "8.3.30" → tags: 8.3.30-fpm, 8.3-fpm
                "org.opencontainers.image.version"     = php.version;
              };
            };
          };

          # -------------------------------------------------------------------
          # SBOM — generated from the Nix dependency graph, not image scanning
          #
          # bombon.lib.buildBom walks the runtime closure of php and produces
          # a CycloneDX SBOM — every Nix store path (php + all dependencies)
          # is listed with its exact version, hash, and license.
          #
          # NOTE: we pass php (not image) — image is the OCI tar.gz which
          # would only produce a trivial single-entry SBOM for the tar itself.
          # php gives us the full runtime dependency graph.
          #
          # Mirrors ZenDiS sbomGen.forImage pattern:
          #   python3 → sbomGen.forImage { packages = config.packages; }
          #   php     → bombon.lib.buildBom php { }
          #
          # Output: result/sbom.cdx.json (CycloneDX 1.5, BSI TR-03183)
          #
          # The release run converts CycloneDX → SPDX and scans for CVEs:
          #   trivy sbom sbom.cdx.json --format spdx-json
          #   trivy sbom sbom.cdx.json --scanners vuln
          # -------------------------------------------------------------------
          sbom = bombon.lib.${buildSystem}.buildBom php { };

        in { inherit image sbom php; };

      # -----------------------------------------------------------------------
      # Assemble all packages
      #
      # Attribute scheme (mirrors ZenDiS python3 pattern):
      #   packages.<buildSystem>."8.3-fpm-amd64"      → OCI image
      #   packages.<buildSystem>."8.3-fpm-amd64-sbom" → CycloneDX SBOM
      # -----------------------------------------------------------------------
      packagesForBuildSystem = buildSystem:
        builtins.listToAttrs (
          map (targetSystem:
            let arch = systemToArch targetSystem;
                pkg  = packagesForSystem buildSystem targetSystem;
            in { name = "${phpVersion}-${phpVariant}-${arch}"; value = pkg.image; }
          ) targetSystems
          ++
          map (targetSystem:
            let arch = systemToArch targetSystem;
                pkg  = packagesForSystem buildSystem targetSystem;
            in { name = "${phpVersion}-${phpVariant}-${arch}-sbom"; value = pkg.sbom; }
          ) targetSystems
          ++
          map (targetSystem:
            let arch = systemToArch targetSystem;
                pkg  = packagesForSystem buildSystem targetSystem;
            in { name = "${phpVersion}-${phpVariant}-${arch}-php"; value = pkg.php; }
          ) targetSystems
        );

    in {
      # -----------------------------------------------------------------------
      # Outputs
      #
      # nix build .#packages.x86_64-linux."8.3-fpm-amd64"
      # nix build .#packages.x86_64-linux."8.3-fpm-amd64-sbom"
      # nix build .#packages.x86_64-linux."8.3-fpm-amd64-php"
      # vulnreport: generated via nix run github:tiiuae/sbomnix#vulnxscan in build.sh (needs network)
      # -----------------------------------------------------------------------
      packages = builtins.listToAttrs (map (buildSystem: {
        name  = buildSystem;
        value = packagesForBuildSystem buildSystem;
      }) buildSystems);
    };
}
