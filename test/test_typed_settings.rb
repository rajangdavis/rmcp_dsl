# frozen_string_literal: true

# A setting can be typed (`type: :i64`, `:f64`, `:bool`): it is parsed when the server starts, which refuses to
# start on a value that does not parse, and a body reads it as that type rather than parsing text by hand
# (rmcp-for-blender gap #6).
#
#   ruby -Ilib test/test_typed_settings.rb              # the emitted Rust and the refusals
#   RMCP_CARGO=1 ruby -Ilib test/test_typed_settings.rb # also cargo-checks the crate (make test-ruby-rust)
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "rmcp_dsl"

class TestTypedSettings < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)

  SRC = <<~'RB'
    server "s", version: "0.1.0" do
      setting :port, env: "S_PORT", type: :i64, default: 8080
      setting :verbose, env: "S_VERBOSE", type: :bool
      setting :ratio, env: "S_RATIO", type: :f64, optional: true
      setting :name, env: "S_NAME", default: "s"

      params :P do
        field :n, :i64
      end

      tool :t, params: :P, description: "d" do
        body do |n|
          "#{setting(:port) + n} #{setting(:verbose)} #{setting(:ratio).to_s} #{setting(:name)}"
        end
      end

      transport :stdio
    end
  RB

  def with_source(source)
    Dir.mktmpdir("typed-settings") do |dir|
      file = File.join(dir, "s.rmcp.rb")
      File.write(file, source)
      RmcpDsl::Notify.reset!
      yield file
    end
  end

  def test_typed_settings_are_parsed_at_startup
    with_source(SRC) do |file|
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", file)
      assert status.success?, err
      main = RmcpDsl::Emit.files(RmcpDsl.read(file), file)["src/main.rs"]
      assert_includes main, "    port: i64,"
      assert_includes main, "    verbose: bool,"
      assert_includes main, "    ratio: Option<f64>,"
      assert_includes main, "    name: String,"
      assert_includes main, "parse_setting::<i64>(\"S_PORT\", port_raw, \"an integer\", &mut problems).unwrap_or(8080);"
      assert_includes main, "fn parse_setting<T: std::str::FromStr>"
      assert_includes main, "missing.push(\"  S_VERBOSE  (verbose)\")"
    end
  end

  def refusal(setting_line)
    source = SRC.sub('setting :name, env: "S_NAME", default: "s"', setting_line)
    with_source(source) { |file| assert_raises(RmcpDsl::CompileError) { RmcpDsl.read(file) }.message }
  end

  def test_a_default_must_have_the_settings_type
    msg = refusal('setting :name, env: "S_NAME", type: :i64, default: "8080"')
    assert_match(/`default:` must be an integer literal for a `type: :i64` setting/, msg)
  end

  def test_a_secret_is_text
    msg = refusal('setting :name, env: "S_NAME", type: :i64, secret: true')
    assert_match(/a secret is text/, msg)
  end

  def test_type_string_is_the_default
    msg = refusal('setting :name, env: "S_NAME", type: :string')
    assert_match(/`type: :string` is the default/, msg)
  end

  def test_the_emitted_crate_compiles
    skip "set RMCP_CARGO=1 to cargo-check the emitted crate (make test-ruby-rust)" unless ENV["RMCP_CARGO"]
    with_source(SRC) do |file|
      out = File.join(File.dirname(file), "out")
      _o, err, status = Open3.capture3(RbConfig.ruby, EXE, "build", file, "-o", out)
      assert status.success?, err
      _o, err, status = Open3.capture3("cargo", "check", "-q", chdir: out)
      assert status.success?, "cargo check refused the emitted crate:\n#{err}"
    end
  end
end
