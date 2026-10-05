# frozen_string_literal: true

# L7: every file in test/refusals/ must be REFUSED by the compiler, with the message named in
# its first line (`# expect: ...`). Each refusal is a rule of the DSL; this keeps the messages
# (and the rules) from silently disappearing.
#
#   ruby -Ilib test/test_refusals.rb
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class TestRefusals < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)
  EXAMPLE_BINDINGS = File.expand_path("../examples/bindings", __dir__)

  Dir.glob(File.expand_path("refusals/*.rb", __dir__)).sort.each do |file|
    expect = File.foreach(file).first[/\A# expect: (.+)\s*\z/, 1] or raise "#{file}: first line must be `# expect: ...`"

    define_method("test_refuses_#{File.basename(file, '.rb')}") do
      # A file that uses bindings needs a bindings/ folder in its own directory, so it is compiled from a temporary
      # directory holding a copy of it and of the example bindings.
      Dir.mktmpdir("refusal") do |dir|
        target = file
        if File.read(file).include?("use_bindings")
          FileUtils.cp_r(EXAMPLE_BINDINGS, File.join(dir, "bindings"))
          target = File.join(dir, File.basename(file))
          FileUtils.cp(file, target)
        end
        _out, err, status = Open3.capture3(RbConfig.ruby, EXE, target, "--check")
        refute status.success?, "#{File.basename(file)} should be refused"
        assert_includes err, expect, "#{File.basename(file)}: wrong message:\n#{err}"
        assert_match(/\A#{Regexp.escape(target)}:\d+:\d+: /, err, "the message should start with FILE:LINE:COL")
      end
    end
  end

  def test_every_example_still_compiles
    Dir.glob(File.expand_path("../examples/*.rb", __dir__)).sort.each do |file|
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, file, "--check")
      assert status.success?, "#{file} should compile:\n#{err}"
    end
  end
end
