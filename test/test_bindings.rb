# frozen_string_literal: true

# Bindings: the Prism loader reads what the compiler needs, the loader refuses malformed files, and
# every example passes against the Ruby reference body (the answer key the Rust is compared to).
#
#   ruby -Ilib test/test_bindings.rb
require "minitest/autorun"
require "tmpdir"
require "rmcp_dsl"
require "rmcp_dsl/binding_dsl"

class TestBindings < Minitest::Test
  # The bindings live next to the examples that use them; the compiler ships none.
  BINDINGS_DIR = File.expand_path("../examples/bindings", __dir__)

  def load_binding(name) = RmcpDsl::Bindings.load(name, root: BINDINGS_DIR)

  def test_a_binding_is_looked_up_next_to_the_dsl_file
    assert_equal File.join(File.expand_path("/x/y"), "bindings"), RmcpDsl::Bindings.dir_for("/x/y/server.rb")
  end

  def test_a_missing_bindings_folder_is_named_in_the_error
    Dir.mktmpdir do |dir|
      err = assert_raises(RmcpDsl::CompileError) { RmcpDsl::Bindings.load("nope", root: File.join(dir, "bindings")) }
      assert_includes err.message, "no binding named nope"
      assert_includes err.message, "next to the DSL file"
    end
  end

  def test_a_missing_file_in_an_existing_folder_is_named_in_the_error
    Dir.mktmpdir do |dir|
      err = assert_raises(RmcpDsl::CompileError) { RmcpDsl::Bindings.load("nope", root: dir) }
      assert_includes err.message, "has no nope.rb"
    end
  end

  def test_the_loader_reads_types_templates_crates_and_examples
    heck = load_binding("heck")
    assert_equal "Heck", heck.module_name
    assert_equal [["heck", "0.5"]], heck.crates
    assert_equal %w[snake_case kebab_case upper_camel_case], heck.fns.keys
    fn = heck.fns["snake_case"]
    assert_equal [["s", :string]], fn.params
    assert_equal :string, fn.returns
    assert_equal "heck::ToSnakeCase::to_snake_case(s)", fn.rust
    assert_equal "heck_snake_case", heck.wrapper(fn)
    assert_includes heck.examples, { method: "snake_case", args: ["HelloWorld fooBar"], expect: "hello_world_foo_bar" }
  end

  def test_a_binding_without_a_template_is_compiled_from_its_ruby_body
    fn = load_binding("words").fns["shout"]
    assert_nil fn.rust
    refute_nil fn.body
  end

  # The Ruby bodies are the reference: run them and check every example.
  # html, url and net have no Ruby stand-in (no_reference): their Rust is checked by bin/gen_shim_tests.
  %w[heck words html url net].each do |name|
    define_method("test_every_example_of_#{name}_passes_against_the_ruby_reference") do
      file = load_binding(name)
      load File.join(BINDINGS_DIR, "#{name}.rb")
      mod = Object.const_get(file.module_name)
      refute_empty file.examples, "#{name} should have examples"
      file.examples.each do |ex|
        next if file.fns.fetch(ex[:method]).no_reference

        assert_equal ex[:expect], mod.public_send(ex[:method], *ex[:args]), "#{file.module_name}.#{ex[:method]}(#{ex[:args].inspect})"
      end
    end
  end

  def test_every_method_has_an_example_including_empty_input
    %w[heck words html url net].each do |name|
      file = load_binding(name)
      file.fns.each_key do |m|
        exs = file.examples.select { |e| e[:method] == m }
        refute_empty exs, "#{file.module_name}.#{m} needs an example"
      end
    end
  end

  # --- refusals: write a small binding file and expect the loader to say why it is wrong
  def refuse(source, expect)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "bad.rb"), source)
      err = assert_raises(RmcpDsl::CompileError) { RmcpDsl::Bindings.load("bad", root: dir) }
      assert_includes err.message, expect
      assert_match(/bad\.rb:\d+:\d+: /, err.message)
    end
  end

  def test_the_loader_reads_list_and_nilable_types
    html = load_binding("html")
    assert_equal :ostrs, html.fns["select"].returns
    assert_equal [["html", :string], ["css", :string]], html.fns["select"].params
    assert_equal :bool, html.fns["valid_selector?"].returns
    assert_equal "html_valid_selector_p", html.wrapper(html.fns["valid_selector?"])
    assert_equal :oi64, load_binding("url").fns["port"].returns
  end

  def test_refuses_a_nilable_parameter
    refuse("module M\n  sig { params(s: T.nilable(String)).returns(String) }\n  def self.f(s) = s.to_s\nend\n", "a parameter cannot be nilable")
  end

  def test_refuses_nilable_of_an_unsupported_type
    refuse("module M\n  sig { params(s: String).returns(T.nilable(Hash)) }\n  def self.f(s) = nil\nend\n", "T.nilable takes one of")
  end

  def test_refuses_a_method_without_a_sig
    refuse("module M\n  def self.f(s) = s\nend\n", "`f` has no sig")
  end

  def test_refuses_integer_and_says_to_use_a_width
    refuse("module M\n  sig { params(n: Integer).returns(String) }\n  def self.f(n) = n.to_s\nend\n", "use I32 or I64")
  end

  def test_refuses_an_unsupported_type
    refuse("module M\n  sig { params(h: Hash).returns(String) }\n  def self.f(h) = h.to_s\nend\n", "unsupported type `Hash`")
  end

  def test_refuses_a_sig_that_does_not_match_the_def
    refuse("module M\n  sig { params(a: String).returns(String) }\n  def self.f(b) = b\nend\n", "the sig names")
  end

  def test_refuses_a_missing_reference_body_without_no_reference
    refuse("module M\n  rust \"x\"\n  sig { params(s: String).returns(String) }\n  def self.f(s); end\nend\n",
           "needs a Ruby body")
  end

  def test_no_reference_allows_an_empty_body_when_a_template_exists
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "ok.rb"),
                 "module M\n  rust \"s.to_string()\"\n  no_reference \"needs the network\"\n  " \
                 "sig { params(s: String).returns(String) }\n  def self.f(s); end\n  example :f, \"a\", expect: \"a\"\nend\n")
      assert_equal "needs the network", RmcpDsl::Bindings.load("ok", root: dir).fns["f"].no_reference
    end
  end

  def test_refuses_nothing_to_compile
    refuse("module M\n  no_reference \"why\"\n  sig { params(s: String).returns(String) }\n  def self.f(s); end\nend\n",
           "nothing to compile")
  end

  def test_refuses_other_code_in_a_binding
    refuse("module M\n  puts 1\n  sig { params(s: String).returns(String) }\n  def self.f(s) = s\nend\n",
           "unsupported call `puts`")
  end

  def test_refuses_an_example_for_an_unknown_method
    refuse("module M\n  sig { params(s: String).returns(String) }\n  def self.f(s) = s\n  example :g, \"a\", expect: \"a\"\nend\n",
           "example for unknown method `g`")
  end
end
