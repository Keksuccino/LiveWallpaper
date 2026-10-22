//! The UniFFI binding generator, as its own binary.
//!
//! `uniffi-bindgen generate --library <lib> --language swift` writes the Swift bindings and the
//! C header for the renderer.

fn main() {
    uniffi::uniffi_bindgen_main()
}
