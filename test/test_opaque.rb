# frozen_string_literal: true

# Types a binding owns (class Value < RmcpDsl::Opaque): what the loader reads, what the compiler records, and the
# refusals that need a binding the example folder does not have (one without wire: true, or malformed ones).
#
#   ruby -Ilib test/test_opaque.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rmcp_dsl"
require "rmcp_dsl/binding_dsl"

class TestOpaque < Minitest::Test
  BINDING = <<~RUBY
    module Doc
      extend T::Sig
      extend RmcpDsl::BindingDsl

      class Page < RmcpDsl::Opaque
        type_rust "crate_x::Page"%<wire>s
      end

      rust "crate_x::open(text)"
      no_reference "no Ruby literal"
      sig { params(text: String).returns(T.nilable(Doc::Page)) }
      def self.open(text) = raise(NotImplementedError, "none")

      rust "page.title()"
      no_reference "no Ruby literal"
      sig { params(page: Page).returns(String) }
      def self.title(page) = raise(NotImplementedError, "none")
    end
  RUBY

  DSL = <<~RUBY
    server "t", version: "0.1.0" do
      use_bindings :doc
      params :P do
        field :page, Doc::Page
      end
      tool :t, params: :P, description: "x" do
        body do |page|
          Doc.title(page)
        end
      end
      transport :stdio
    end
  RUBY

  def compile(binding_text, dsl = DSL)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bindings"))
      File.write(File.join(dir, "bindings", "doc.rb"), binding_text)
      File.write(File.join(dir, "server.rmcp.rb"), dsl)
      yield RmcpDsl.read(File.join(dir, "server.rmcp.rb"))
    end
  end

  def refused(binding_text, dsl = DSL)
    compile(binding_text, dsl) { flunk "should have been refused" }
  rescue RmcpDsl::CompileError => e
    e.message
  end

  def test_the_loader_reads_the_type_and_resolves_both_spellings_in_sigs
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "doc.rb"), format(BINDING, wire: ", wire: true"))
      file = RmcpDsl::Bindings.load("doc", root: dir)
      assert_equal %w[Page], file.types.keys
      assert_equal "crate_x::Page", file.types["Page"].rust
      assert file.types["Page"].wire
      assert_equal [["page", :"ext<Doc::Page>"]], file.fns["title"].params # Page and Doc::Page are the same type
      assert_equal :"opt<ext<Doc::Page>>", file.fns["open"].returns
    end
  end

  def test_the_ir_records_the_type_and_the_field_and_function_types
    compile(format(BINDING, wire: ", wire: true")) do |ir|
      assert_equal [{ "name" => "Doc::Page", "rust" => "crate_x::Page", "wire" => true }], ir["opaque_types"]
      assert_equal "Doc::Page", ir["params"][0]["fields"][0]["type"]
      fn = ir["binding_fns"].find { |f| f["name"] == "doc_title" }
      assert_equal [["page", "ext<Doc::Page>"]], fn["args"]
    end
  end

  def test_emit_writes_the_rust_type_for_a_field_a_parameter_and_a_result
    compile(format(BINDING, wire: ", wire: true")) do |ir|
      rust = RmcpDsl::Emit.files(ir, DSL)["src/main.rs"]
      assert_includes rust, "page: crate_x::Page,"
      assert_includes rust, "fn doc_title(page: &crate_x::Page) -> String {"
    end
  end

  def test_a_type_without_wire_cannot_be_a_field
    msg = refused(format(BINDING, wire: ""))
    assert_includes msg, "Doc::Page cannot be a field: its binding does not say `wire: true`"
  end

  def test_a_type_without_wire_still_works_inside_a_body
    dsl = <<~RUBY
      server "t", version: "0.1.0" do
        use_bindings :doc
        params :P do
          field :text, :string
        end
        tool :t, params: :P, description: "x" do
          body do |text|
            page = Doc.open(text) || raise("no page")
            Doc.title(page)
          end
        end
        transport :stdio
      end
    RUBY
    compile(format(BINDING, wire: ""), dsl) do |ir|
      rust = RmcpDsl::Emit.files(ir, dsl)["src/main.rs"]
      assert_includes rust, "fn doc_open(text: &str) -> Option<crate_x::Page> {"
      assert_includes rust, "doc_title(&page)"
    end
  end

  def test_malformed_type_declarations_are_refused
    assert_includes refused("module Doc\n  class Page < Object\n  end\n  def self.f; end\nend\n"), "a type in a binding is written `class Name < RmcpDsl::Opaque`"
    assert_includes refused("module Doc\n  class Page < RmcpDsl::Opaque\n  end\nend\n"), "holds one line: type_rust"
    assert_includes refused(format(BINDING, wire: ", wire: 1")), "type_rust takes only wire: true or wire: false"
    assert_includes refused(BINDING.sub('"crate_x::Page"%<wire>s', '"not a path!"')), "is not a path such as serde_json::Value"
  end

  def test_a_type_is_declared_once
    twice = format(BINDING, wire: "").sub("  rust \"crate_x::open", "  class Page < RmcpDsl::Opaque\n    type_rust \"crate_y::Page\"\n  end\n\n  rust \"crate_x::open")
    assert_includes refused(twice), "type `Page` is declared twice"
  end

  def test_the_registry_is_per_read_so_a_later_file_does_not_see_an_earlier_types
    compile(format(BINDING, wire: ", wire: true")) { |_| assert RmcpDsl::CompositeTypes::Opaque.entry("Doc::Page") }
    plain = "server \"t\", version: \"0.1.0\" do\n  tool :t, params: :P, description: \"x\" do\n    body { |x| x }\n  end\n  transport :stdio\nend\n"
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "s.rmcp.rb"), plain)
      begin
        RmcpDsl.read(File.join(dir, "s.rmcp.rb"))
      rescue RmcpDsl::CompileError
        nil
      end
    end
    assert_nil RmcpDsl::CompositeTypes::Opaque.entry("Doc::Page")
  end
end
