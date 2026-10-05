// Existing hand-written Rust, loaded into the server with `rust_file`.
// rmcp_dsl does not generate or check this file; cargo does.
pub fn shout(s: &str) -> String {
    format!("{}!", s.to_uppercase())
}
