# Vendored zstd (decompression only)

- Version: 1.5.7 (latest stable release, published 2025-02-19)
- Source: https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz
- SHA-256: `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`
  (matches the release's published `zstd-1.5.7.tar.gz.sha256`)
- License: zstd is dual-licensed BSD or GPLv2; Domovy uses it under the BSD license (`LICENSE`).

## What is here

Unmodified files from the tarball:

- `lib/zstd.h`, `lib/zstd_errors.h`
- `lib/common/*` except `pool.*` and `threading.*` (only the multithreaded compressor uses them)
- `lib/decompress/*.c`, `lib/decompress/*.h` (not `huf_decompress_amd64.S`; the build sets
  `ZSTD_DISABLE_ASM`, so x86-64 uses the portable C decoder)

Not vendored: `lib/compress`, `lib/dictBuilder`, `lib/legacy` (`ZSTD_LEGACY_SUPPORT` is 0),
`lib/deprecated`, programs and tests.

`include/CZstd.h` is Domovy's own one-line umbrella header for the Swift module.

## Updating

Download the new release tarball and its `.sha256`, verify, copy the same files over, update
the version and checksum above, run `swift test` and `make app`.
