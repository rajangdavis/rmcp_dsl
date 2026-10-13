# The splitkit server in three files: test/test_use_dsl.rb checks it generates the same
# src/main.rs as single/splitkit.rmcp.rb, which writes the same declarations in one file.
server "splitkit", version: "0.1.0" do
  setting :greeting, env: "SPLITKIT_GREETING", default: "hello"
  use_dsl "dsl/helpers.rmcp.rb"
  use_dsl "dsl/tools.rmcp.rb"
  transport :stdio
end
