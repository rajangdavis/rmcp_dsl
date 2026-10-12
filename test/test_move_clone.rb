# frozen_string_literal: true

# Ruby reads a local without consuming it, so a String local used as an `if` branch value, assigned to
# another local, or put on the left of `||` must still be readable afterwards. Rust moves it in each of
# those places, so the emitter clones it there (rmcp-for-blender gaps #17, #21, #31: `check` passed and
# cargo refused with E0382).
#
#   ruby -Ilib test/test_move_clone.rb              # the emitted Rust
#   RMCP_CARGO=1 ruby -Ilib test/test_move_clone.rb # also cargo-checks it (make test-ruby-rust)
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "rmcp_dsl"

class TestMoveClone < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)

  SRC = <<~'RB'
    server "s", version: "0.1.0" do
      params :P do
        field :problem, :string
        field :output, :string
        field :names, :string_list
        field :n, :i64
      end

      tool :t, params: :P, description: "d" do
        body do |problem, output, names, n|
          failure = if output == "" then problem else "#{problem}\n#{output}" end
          raise failure unless problem == ""
          copy = output
          first = names.first
          name = first || "none"
          m = n
          "#{copy} #{output} #{name} #{first.to_s} #{m} #{n}"
        end
      end

      transport :stdio
    end
  RB

  def with_source
    Dir.mktmpdir("move-clone") do |dir|
      file = File.join(dir, "s.rmcp.rb")
      File.write(file, SRC)
      yield file
    end
  end

  def test_a_moved_local_is_cloned_and_check_accepts_it
    with_source do |file|
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", file)
      assert status.success?, err
      main = RmcpDsl::Emit.files(RmcpDsl.read(file), file)["src/main.rs"]
      assert_includes main, "{ problem.clone() }", "an if branch's String local"
      assert_includes main, "let copy = output.clone();", "a String local assigned to another"
      assert_includes main, "first.clone().unwrap_or_else(", "the left of ||"
      assert_includes main, "let m = n;", "a Copy local is not cloned"
    end
  end

  def test_the_emitted_crate_compiles
    skip "set RMCP_CARGO=1 to cargo-check the emitted crate (make test-ruby-rust)" unless ENV["RMCP_CARGO"]
    with_source do |file|
      out = File.join(File.dirname(file), "out")
      _o, err, status = Open3.capture3(RbConfig.ruby, EXE, "build", file, "-o", out)
      assert status.success?, err
      _o, err, status = Open3.capture3("cargo", "check", "-q", chdir: out)
      assert status.success?, "cargo check refused the emitted crate:\n#{err}"
    end
  end
end
