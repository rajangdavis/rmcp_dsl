# frozen_string_literal: true

module RmcpDsl
  # The version of this gem: its own SemVer, which changes for DSL features and fixes, not when rmcp does.
  VERSION = "0.1.0"

  # The one rmcp version the servers it generates are built against, and the only one tested. Every generated
  # Cargo.toml pins exactly this (`=3.5.0`), so a build never picks up a newer rmcp that has not been through the end to
  # end suites. Moving to another version is a change to this line, made after running them against it; the source of
  # that version is vendored under vendor/ (test/test_versions.rb checks the two agree).
  RMCP_VERSION = "3.5.0"
end
