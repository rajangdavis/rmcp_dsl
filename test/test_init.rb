# frozen_string_literal: true

# `rmcp_dsl init`: the scaffold it writes (a starter DSL file that compiles, and a bindings/
# folder that survives version control), --force, --no-bindings and the refusal of a bad name.
#
#   ruby -Ilib test/test_init.rb
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"

class TestInit < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  EXE = File.join(ROOT, "exe/rmcp_dsl")

  def run_init(*args, chdir: nil)
    opts = chdir ? { chdir: chdir } : {}
    Open3.capture3(RbConfig.ruby, EXE, "init", *args, **opts)
  end

  def test_creates_a_compiling_server_and_a_bindings_folder
    Dir.mktmpdir("init") do |dir|
      out, err, status = run_init("myserver", "-o", dir)
      assert status.success?, err
      dsl = File.join(dir, "myserver.rmcp.rb")
      bindings = File.join(dir, "bindings")
      assert File.file?(dsl), "the DSL file was not written"
      assert File.directory?(bindings), "the bindings/ folder was not written"
      assert File.file?(File.join(bindings, ".gitkeep")), "an empty bindings/ needs a .gitkeep"
      assert_includes out, dsl
      assert_includes out, bindings

      source = File.read(dsl)
      assert_match(/\A# typed: true\n/, source)
      assert_includes source, 'server "myserver"'
      assert_includes source, "transport :stdio"

      check_out, check_err, check_status = Open3.capture3(RbConfig.ruby, EXE, "check", dsl)
      assert check_status.success?, check_err
      assert_includes check_out, "ok"
    end
  end

  def test_a_second_run_without_force_refuses
    Dir.mktmpdir("init") do |dir|
      _out, _err, first = run_init("myserver", "-o", dir)
      assert first.success?
      out, err, second = run_init("myserver", "-o", dir)
      refute second.success?
      assert_includes err, "already exists; pass --force to overwrite"
      assert_empty out
    end
  end

  def test_force_overwrites_the_existing_file
    Dir.mktmpdir("init") do |dir|
      run_init("myserver", "-o", dir)
      dsl = File.join(dir, "myserver.rmcp.rb")
      File.write(dsl, "junk\n")
      out, err, status = run_init("myserver", "-o", dir, "--force")
      assert status.success?, err
      assert_includes out, dsl
      refute_includes File.read(dsl), "junk"
    end
  end

  def test_no_bindings_skips_the_folder
    Dir.mktmpdir("init") do |dir|
      out, err, status = run_init("myserver", "-o", dir, "--no-bindings")
      assert status.success?, err
      assert File.file?(File.join(dir, "myserver.rmcp.rb"))
      refute File.exist?(File.join(dir, "bindings")), "bindings/ should be skipped"
      refute_includes out, "bindings"
    end
  end

  def test_an_existing_bindings_folder_is_reused
    Dir.mktmpdir("init") do |dir|
      FileUtils.mkdir_p(File.join(dir, "bindings"))
      File.write(File.join(dir, "bindings", "words.rb"), "# mine\n")
      _out, err, status = run_init("myserver", "-o", dir)
      assert status.success?, err
      assert File.file?(File.join(dir, "bindings", "words.rb")), "an existing binding must survive"
      assert File.file?(File.join(dir, "bindings", ".gitkeep"))
    end
  end

  def test_rejects_a_name_that_is_not_a_plain_file_name
    Dir.mktmpdir("init") do |dir|
      ["", "has/slash", "../escape", "with space"].each do |name|
        _out, err, status = run_init(name, "-o", dir)
        refute status.success?, "#{name.inspect} should be rejected"
        assert_includes err, "invalid name"
      end
    end
  end

  def test_the_default_output_directory_is_the_current_one
    Dir.mktmpdir("init") do |dir|
      out, err, status = run_init("here", chdir: dir)
      assert status.success?, err
      assert File.file?(File.join(dir, "here.rmcp.rb"))
      assert_includes out, File.join(".", "here.rmcp.rb")
    end
  end
end
