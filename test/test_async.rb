# frozen_string_literal: true

# Async in the DSL: a `rust_fn` or binding declared `async: true`, and any helper, tool, prompt or
# resource body that calls an async function, is compiled `async fn` and awaited. Async is inferred,
# so a caller never repeats `async: true`. This file also holds the golden test that guards sync-only
# codegen, the async binding / Send coverage, and the hover test for an async helper.
#
#   ruby -Ilib -Itest test/test_async.rb
require "minitest/autorun"
require "rmcp_dsl"
require "digest"
require "tmpdir"
require "fileutils"

class TestAsync < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  # The sync-only fixture; see test_sync_helper_is_byte_identical below.
  SYNC_FIXTURE = "test/golden/sync_golden.rmcp.rb"

  # Sync-only sources whose emitted Rust must not change: they never await, so the inference and
  # closure changes must leave them byte for byte alone. The hashes are of src/main.rs.
  GOLDEN = {
    "test/golden/sync_golden.rmcp.rb" => "f4c6d3a1cb3c5dc8b58c3af80439aa8a75ec76d945d693a6e774d5fdcf25862c",
    "examples/add.rmcp.rb" => "d686b31f74bb555529f79ba5f5bc62248cbd7f174c0ca4dc1e89cee1b0e41072"
  }.freeze

  # A tool calls `bump`, an async helper; `bump` calls the injected async rust_fn `fetch`. Async is
  # inferred, so neither `bump` nor the tool declares it.
  ASYNC_SOURCE = <<~'RB'
    server "async", version: "0.1.0" do
      rust_item <<~'RS'
        async fn fetch(x: i64) -> i64 {
            std::future::ready(()).await;
            x + 1
        }
      RS
      rust_fn :fetch, args: [:i64], returns: :i64, async: true

      params :P do
        field :n, :i64
      end

      helper :bump, args: [:i64], returns: :i64 do |n|
        rust(:fetch, n)
      end

      tool :run, params: :P, description: "d" do
        body do |n|
          bump(n).to_s
        end
      end

      transport :stdio
    end
  RB

  def emit(path)
    RmcpDsl::Notify.reset!
    RmcpDsl::Emit.files(RmcpDsl.read(File.join(ROOT, path)), path)["src/main.rs"]
  end

  # A DSL source in a throwaway directory (with an optional { name => body } bindings hash), so
  # bindings and imports resolve.
  def emit_source(source, bindings = {})
    Dir.mktmpdir("async") do |dir|
      unless bindings.empty?
        FileUtils.mkdir_p(File.join(dir, "bindings"))
        bindings.each { |name, body| File.write(File.join(dir, "bindings", "#{name}.rb"), body) }
      end
      path = File.join(dir, "async.rmcp.rb")
      File.write(path, source)
      RmcpDsl::Notify.reset!
      return RmcpDsl::Emit.files(RmcpDsl.read(path), path)["src/main.rs"]
    end
  end

  # The exact sync helper, byte for byte: the async work must not change Emit#helper_fn for a sync body.
  def test_sync_helper_is_byte_identical
    main = emit(SYNC_FIXTURE)
    assert_includes main, "fn helper_wrap(s: String) -> String {\n    format!(\"[{}]\", s)\n}"
  end

  # Each sync-only source must emit src/main.rs byte for byte as pinned below: the async inference and
  # closure work must not change any sync codegen. Gated on GOLDEN: ruby-tests runs on the projected
  # tree (live buffers, proposals included), so the digest moves with every unsaved edit. Run with
  # GOLDEN=1 on the saved tree only, and re-pin only from such a run, deliberately, when the emitter's
  # sync output genuinely changes. Every mismatch is reported, not just the first.
  def test_golden_hashes_match_the_emitted_rust
    skip "set GOLDEN=1 on the saved tree to check the pinned digests" unless ENV["GOLDEN"]
    mismatches = GOLDEN.filter_map do |path, sha|
      actual = Digest::SHA256.hexdigest(emit(path))
      "#{path}: expected #{sha}, got #{actual}" unless actual == sha
    end
    assert_empty mismatches, "emitted src/main.rs changed:\n#{mismatches.join("\n")}"
  end

  # The sync paths must not have grown an `async`/`.await`: a sync helper is still `fn helper_`,
  # a sync rust_fn call is not awaited, a sync resource body is still `fn resource_`, and a fallible
  # sync body still uses the sync closure.
  def test_sync_paths_stay_synchronous
    main = emit("test/golden/sync_golden.rmcp.rb")
    assert_includes main, "fn helper_wrap("
    refute_includes main, "async fn helper_wrap("
    assert_includes main, "shout(&text)"
    refute_includes main, "shout(&text).await"
    assert_includes main, "fn resource_doc("
    refute_includes main, "async fn resource_doc("
    assert_includes main, "(|| -> Result<String, String> {"
    refute_includes main, "(async || -> Result<String, String> {"
  end

  def test_async_is_inferred_through_helpers_and_the_tool
    main = emit_source(ASYNC_SOURCE)
    assert_includes main, "async fn helper_bump(n: i64) -> i64 {"
    assert_includes main, "fetch(n).await"
    assert_includes main, "helper_bump(n).await.to_string()"
    assert_includes main, "async fn run("
  end

  def test_an_async_rust_fn_call_is_awaited
    main = emit_source(ASYNC_SOURCE)
    assert_includes main, "async fn fetch"
    assert_includes main, "(async || -> i64 {"
    assert_includes main, "fetch(n).await"
  end

  # An async binding: `rust "...", async: true` makes the wrapper an `async fn`, and a body that
  # calls it is compiled `async fn` and awaits the eventual value.
  def test_async_binding_wrapper_is_async_and_awaited
    bindings = {
      "ticker" => <<~RB
        module Ticker
          extend T::Sig
          extend RmcpDsl::BindingDsl
          no_reference "an async Rust stand-in"
          rust "std::future::ready(s.to_string()).await", async: true
          sig { params(s: String).returns(String) }
          def self.tick(s) = s
        end
      RB
    }
    source = <<~RB
      server "b", version: "0.1.0" do
        use_bindings :ticker
        params :S do
          field :s, :string
        end
        tool :t, params: :S, description: "x" do
          body do |s|
            Ticker.tick(s)
          end
        end
        transport :stdio
      end
    RB
    main = emit_source(source, bindings)
    assert_includes main, "async fn ticker_tick"
    assert_includes main, "ticker_tick(&s).await"
  end

  # A forward helper call cannot form a cycle: the compiler refuses it before the fixpoint runs, so
  # the async cycle guard (which would need Box::pin) is unreachable from a well-formed file.
  def test_a_forward_helper_call_is_refused_before_a_cycle_can_form
    source = <<~RB
      server "f", version: "0.1.0" do
        params :S do
          field :s, :string
        end
        helper :first, args: [:string], returns: :string do |s|
          second(s)
        end
        helper :second, args: [:string], returns: :string do |s|
          s.upcase
        end
        tool :t, params: :S, description: "x" do
          body do |s|
            first(s)
          end
        end
        transport :stdio
      end
    RB
    err = assert_raises(RmcpDsl::CompileError) { emit_source(source) }
    assert_includes err.message, "a helper can only be called after it is declared"
  end

  # rmcp requires a tool's future to be Send. The DSL never boxes a future: it awaits inline, so
  # rustc's ordinary Send obligation applies directly. A non-Send value (a std::sync::MutexGuard, an
  # Rc, a RefCell borrow) held across an `.await` makes the future non-Send, so the generated tool
  # fails to compile with rustc's Send error; the DSL cannot know whether hand-written Rust is Send,
  # so it pins the shape (inline await, no Box::pin) and documents the constraint.
  def test_async_futures_are_awaited_inline_and_never_boxed
    main = emit_source(ASYNC_SOURCE)
    assert_includes main, ".await"
    refute_includes main, "Box::pin", "futures are awaited inline, never boxed"
  end

  # The "allowed" side of the async audit: a list `map` lowers to a for loop, so an async call in its
  # block is awaited inside that loop (unlike a gsub/sub block, which is refused), and the future is
  # awaited inline rather than boxed.
  def test_an_async_call_in_a_list_map_is_awaited_inside_the_loop
    source = <<~RB
      server "listmap", version: "0.1.0" do
        rust_item <<~'RS'
          async fn fetch(x: i64) -> i64 {
              std::future::ready(()).await;
              x + 1
          }
        RS
        rust_fn :fetch, args: [:i64], returns: :i64, async: true

        params :P do
          field :ns, :i64_list
        end

        tool :run, params: :P, description: "d" do
          body do |ns|
            ns.map { |n| rust(:fetch, n).to_s }.join(",")
          end
        end

        transport :stdio
      end
    RB
    main = emit_source(source)
    loop_line = main.lines.find { |l| l.include?("for __e in") }
    refute_nil loop_line, "a list map should lower to a for loop"
    assert_includes loop_line, ".await", "the async call must be awaited inside the loop"
    refute_includes main, "Box::pin", "a list map must not box the future"
  end

  def test_hover_shows_an_async_helper_and_why
    Dir.mktmpdir("async") do |dir|
      path = File.join(dir, "async.rmcp.rb")
      File.write(path, ASYNC_SOURCE)
      analysis = RmcpDsl::Lsp::Analysis.new(path, ASYNC_SOURCE)
      line = ASYNC_SOURCE.lines.index { |l| l.include?("helper :bump") }
      hover = RmcpDsl::Lsp::Hover.at(analysis, line, ASYNC_SOURCE.lines[line].index("bump"))
      refute_nil hover, "hover on the async helper"
      value = hover["contents"]["value"]
      assert_includes value, "(async)"
      assert_includes value, "calls rust_fn `fetch`"
    end
  end
end
