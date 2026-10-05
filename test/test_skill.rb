# frozen_string_literal: true

# The generated agent skill must match the compiler it describes: every declaration, body method
# and notification code appears, every embedded example compiles, and the layout is the portable
# SKILL.md one (a folder named for the skill, frontmatter name and description, relative links).
#
#   ruby -Ilib test/test_skill.rb
require "minitest/autorun"
require "rmcp_dsl"
require "tmpdir"

class TestSkill < Minitest::Test
  def setup
    @files = RmcpDsl::Skill.files
    @skill = @files.fetch("rmcp-dsl/SKILL.md")
  end

  def test_layout_is_a_folder_named_for_the_skill
    assert(@files.keys.all? { |path| path.start_with?("rmcp-dsl/") })
    assert_equal %w[rmcp-dsl/SKILL.md rmcp-dsl/references/bindings.md rmcp-dsl/references/body-language.md
                    rmcp-dsl/references/cli.md rmcp-dsl/references/dsl.md], @files.keys.sort
  end

  def test_frontmatter_has_a_matching_name_and_a_short_description
    front = @skill[/\A---\n(.*?)\n---\n/m, 1] or flunk "SKILL.md must start with frontmatter"
    meta = YAML.safe_load(front)
    assert_equal "rmcp-dsl", meta.fetch("name")
    assert_operator meta.fetch("description").length, :<=, 1024
    assert_match(/\A[a-z0-9]+(-[a-z0-9]+)*\z/, meta.fetch("name"))
    assert_equal %w[description name], meta.keys.sort, "only the portable frontmatter fields"
  end

  def test_relative_links_resolve_to_generated_files
    links = @skill.scan(/\]\(([^)]+)\)/).flatten
    refute_empty links
    links.each { |link| assert @files.key?("rmcp-dsl/#{link}"), "#{link} is not generated" }
  end

  def test_every_declaration_is_documented
    dsl = @files.fetch("rmcp-dsl/references/dsl.md")
    RmcpDsl::SIG.each_key { |name| assert_includes dsl, "### `#{name}`" }
    RmcpDsl::TYPES.each_key { |type| assert_includes dsl, "`:#{type}`" }
  end

  def test_every_call_and_keyword_carries_its_doc_sentence
    dsl = @files.fetch("rmcp-dsl/references/dsl.md")
    RmcpDsl::SIG.each do |name, sig|
      assert_includes dsl, RmcpDsl::Docs.call(name), "the page lacks the sentence for `#{name}`"
      sig[:kw].each_key do |kw|
        assert_includes dsl, "  - `#{kw}:` #{RmcpDsl::Docs.keyword(name, kw)}", "the page lacks the sentence for `#{name} #{kw}:`"
      end
    end
  end

  def test_every_body_method_and_notification_is_documented
    body = @files.fetch("rmcp-dsl/references/body-language.md")
    RmcpDsl::Body::ALLOWED_METHODS.each { |m| assert_includes body, "`#{m}`" }
    RmcpDsl::Notify::CODES.each_key { |code| assert_includes body, code }
  end

  def test_catalog_methods_are_all_allowed_in_bodies
    RmcpDsl::Skill.catalog.select { |e| e["receiver"] == "native_ruby" }.each do |entry|
      Array(entry["method"]).each do |m|
        assert_includes RmcpDsl::Body::ALLOWED_METHODS, m, "#{entry['name']} names a method the body language refuses"
      end
    end
  end

  def test_the_bindings_page_explains_the_folder_and_the_macros
    page = @files.fetch("rmcp-dsl/references/bindings.md")
    ["bindings/", "SAME directory", "crate ", "rust \"", "no_reference", "example :", "T.nilable", "use_bindings :words"].each do |text|
      assert_includes page, text
    end
  end

  def test_the_binding_shown_on_the_page_parses_with_the_real_loader
    Dir.mktmpdir("skill-binding") do |dir|
      File.write(File.join(dir, "words.rb"), RmcpDsl::Skill::BINDING_EXAMPLE)
      file = RmcpDsl::Bindings.load("words", root: dir)
      assert_equal %w[shout], file.fns.keys
      assert_equal "Words", file.module_name
    end
  end

  def test_the_cli_page_names_every_subcommand
    cli = @files.fetch("rmcp-dsl/references/cli.md")
    %w[check build run skill].each { |cmd| assert_includes cli, "rmcp_dsl #{cmd}" }
  end

  def test_every_embedded_example_compiles
    Dir.mktmpdir("skill") do |dir|
      RmcpDsl::Skill::EXAMPLES.each do |name, source|
        RmcpDsl::Notify.reset!
        file = File.join(dir, "#{name}.rb")
        File.write(file, source)
        ir = RmcpDsl.read(file)
        refute_empty ir["tools"], "#{name} should declare a tool"
      end
    end
  end

  def test_examples_in_the_pages_are_the_tested_ones
    assert_includes @skill, RmcpDsl::Skill::BASIC
    dsl = @files.fetch("rmcp-dsl/references/dsl.md")
    assert_includes dsl, RmcpDsl::Skill::TEXT.chomp
    assert_includes dsl, RmcpDsl::Skill::CMD.chomp
  end
end
