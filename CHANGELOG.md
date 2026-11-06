# Changelog

Use spec: https://common-changelog.org/

## v1.0.0 - 2026-11-06

This release aligns `zmosh` with the official release of `zmx v1.0.0` and upgrades the codebase to `zig 0.17.0`.

### Added

- Multi-platform pre-compiled binaries for Linux (`x86_64`, `aarch64`) and macOS (`x86_64`, `aarch64`).
- C header `include/zmosh/zmosh.h` for embedding zmosh client functionality.
- Automated release build target (`zig build release`) generating tarballs and SHA256 checksums.

### Changed

- **Package Dependency**: Decoupled `zmosh` from `zmx` source code; `zmosh` now consumes `zmx` as an external Zig package module dependency via `libzmx`.
- **Wire Protocol**: Fully compatible with the frozen 8-byte aligned IPC header and wire protocol in `zmx v1.0.0`.
- **Toolchain**: Upgraded build system and compiler compatibility to Zig 0.17.0.

