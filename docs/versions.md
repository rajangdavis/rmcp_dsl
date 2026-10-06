# Versions

Two version numbers are in play, and they move independently.

_See also: [README](../README.md)._

- **rmcp_dsl** (this gem) has its own [SemVer](https://semver.org): the minor changes for new DSL features, the major only when
  existing files stop compiling, the patch for fixes. `rmcp_dsl --version` prints it.
- **rmcp** (the Rust SDK the generated servers use) is pinned to one exact version per gem release. Every generated
  `Cargo.toml` says `rmcp = { version = "=3.5.0" }`, and the top of every generated `main.rs` says which rmcp_dsl and which rmcp
  it was made for, so a build never moves to a newer rmcp that has not been through the end-to-end suites.

| rmcp_dsl | rmcp |
|----------|------|
| 0.1.x | 3.5.0 |

To move to a newer rmcp: vendor its source under `vendor/` (that is what the compiler is written against), change `RMCP_VERSION`
in `lib/rmcp_dsl/version.rb`, and run `make check`. Green adds a row to the table. Red names the behaviour that changed. The MCP
protocol revision is negotiated at run time by rmcp, so it is not part of either number.
