# php — OCI Image

Reproducible PHP-FPM container image built with Nix. No Dockerfile, no apt — the build is deterministic and byte-identical given the same inputs.

Modelled after the [ZenDiS Debian image](https://gitlab.opencode.de/oci-community/images/zendis/debian).

---

## Quick start

```sh
# Build the image
nix build .#packages.x86_64-linux.php-83-fpm-amd64

# Load into Docker
docker load < result

# Test
docker run --rm localhost/php:83-fpm-amd64 php --version
docker run --rm localhost/php:83-fpm-amd64 php -m
```

---

## Flake structure

```
flake.nix
├── inputs
│   └── nixpkgs (nixos-unstable, pinned via flake.lock)
└── outputs
    └── packages
        ├── x86_64-linux
        │   ├── php-83-fpm-amd64    ← OCI image tar.gz
        │   └── php-83-fpm-arm64    ← cross-compile (later)
        └── aarch64-linux
            ├── php-83-fpm-amd64
            └── php-83-fpm-arm64
```

The attribute scheme `<image>-<phpver>-<variant>-<arch>` follows the ZenDiS pattern `debian-<version>-<arch>`.

---

## PHP extensions

Only the nixpkgs defaults — identical to what `php:8.3-fpm` from Docker Hub ships: `core`, `ctype`, `date`, `dom`, `fileinfo`, `filter`, `hash`, `iconv`, `json`, `mbstring`, `opcache`, `openssl`, `pdo`, `phar`, `session`, `tokenizer`, `xml`, `zlib` and others.

No additional extensions. App images (TYPO3, Moodle, ...) build on top and add their own extensions as a separate layer.

---

## Build via cibuild

```sh
# cibuild.env
CIBUILD_BUILD_CLIENT=nix
CIBUILD_NIX_FLAKE_ATTR=php-83-fpm-amd64
CIBUILD_BUILD_NATIVE=1
```

```yaml
# .gitlab-ci.yml
build:
  image: ghcr.io/stack4ops/cibuilder:build-nix
  script: [/bin/true]
```

---

## Why Nix instead of Dockerfile?

| | Dockerfile + apt | Nix flake |
|--|-----------------|-----------|
| Reproducible | No (apt pulls latest) | Yes (flake.lock pins everything) |
| Auditable | Limited | Fully (every dependency in the lock) |
| Cache | Layer-based | Content-addressed (Attic/Cachix) |
| Cross-compile | Via QEMU | Native (nixpkgs cross support) |
| ZenDiS-compatible | No | Yes (same build philosophy) |

---

## Roadmap

- **Stage 1** *(this file)*: `nixpkgs.dockerTools` with `pkgs.php83` — easy to learn, fully functional
- **Stage 2**: integrate `container-hardening-work-bench` — Debian packages directly from `snapshot.debian.org` as in the ZenDiS image
- **Stage 3**: contribute to `oci-community/images` on opencode.de