# Rust

Cargo workspace for the Rust code of the Ente Photos offline fork. It holds only what the Flutter app links through `bindings/frb/photos`:

- `bindings/frb/photos`, `bindings/frb/log`: the Flutter Rust Bridge crate and its log sink.
- `crates/ml`, `crates/image`: on-device ML and image decode.
- `crates/photos`, `crates/vecdb`, `crates/location`, `crates/exif`, `crates/assets`, `crates/core`: the libraries those need.
- `tools/codegen`: the `cargo codegen` alias (see `.cargo/config.toml`).

## Development

```sh
cargo check -p ente-photos-frb --features flutter   # Type-check the bridge crate with its generated code
cargo test --workspace                              # Test the libraries
cargo codegen frb photos                            # Regenerate the bridge (Rust and Dart) for the photos app
```

Run `cargo codegen frb photos` whenever the exported surface under `bindings/frb/photos/src/api` changes. It writes `bindings/frb/photos/src/frb_generated.rs` and `mobile/apps/photos/lib/src/rust` (both git-ignored).

`scripts/lint.sh` runs the checks in `checks/`, `cargo fmt --check`, `cargo clippy` and `cargo audit`.
