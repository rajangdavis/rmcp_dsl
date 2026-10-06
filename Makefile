.PHONY: probe gem-test e2e-webpeek e2e-listkit e2e-notekit e2e-logkit e2e-webkit e2e-guide e2e-formkit e2e-statkit e2e-httpkit e2e-httpauth e2e-httpoauth e2e-lsp e2e-mapkit e2e-jsonkit e2e-taskkit e2e-contentkit e2e-pathkit e2e-livekit e2e-pagekit e2e-configkit e2e-schemakit e2e-apikit e2e-shopkit test-ruby test-ruby-rust gen-diff test-diff e2e e2e-textkit e2e-injected e2e-hooked e2e-exec e2e-exec-slow e2e-fetchkit e2e-arith e2e-bindings dsl-check rbi rbi-check rbi-helpers rbi-helpers-check typecheck check-fast check-build check-e2e check

# Every cargo invocation shares one target dir, so rmcp and its dependencies compile once
# for the whole suite instead of once per generated crate.
export CARGO_TARGET_DIR := $(CURDIR)/target

# L1: Ruby shim tests against the catalog.
test-ruby:
	ruby -Ilib -Itest -e 'Dir.glob("test/test_*.rb").sort.reject { |f| %w[test_elicitation.rb test_roots.rb test_sampling.rb].include?(File.basename(f)) }.each { |f| require "./#{f}" }'

# L5 in Ruby: these build a generated crate and drive it over stdio, so they need the Rust
# toolchain. CARGO_TARGET_DIR is shared (above), so rmcp compiles once for all three.
test-ruby-rust:
	ruby -Ilib test/test_elicitation.rb
	ruby -Ilib test/test_roots.rb
	ruby -Ilib test/test_sampling.rb

# L3: generate Rust tests from the same catalog, then run them.
gen-diff:
	ruby bin/gen_shim_tests

test-diff: gen-diff
	cd shimcheck && cargo test

# A full `make check` cannot finish inside one hook timeout (it timed out at 600 s on 2026-10-05),
# so it is also available in slices: check-fast is the Ruby/Sorbet suites, check-build the
# generated-Rust ones, check-e2e the example servers. `check` still runs all three, for the host.
check-fast: rbi-check typecheck test-ruby

check-build: test-ruby-rust test-diff

check-e2e: e2e-listkit e2e-notekit e2e-logkit e2e-webkit e2e-guide e2e-formkit e2e-statkit e2e-httpkit e2e-httpauth e2e-httpoauth e2e-lsp e2e-mapkit e2e-jsonkit e2e-taskkit e2e-contentkit e2e-pathkit e2e-livekit e2e-pagekit e2e-configkit e2e-schemakit e2e-apikit e2e-shopkit

check: check-fast check-build check-e2e

# L5: build the example server and talk MCP to it.
e2e: e2e-listkit
	ruby exe/rmcp_dsl examples/add.rmcp.rb -o /tmp/add-out
	sh test/e2e_add.sh /tmp/add-out

# Sorbet: regenerate the DSL description from the compiler's SIG table, verify it
# is current, and typecheck the example servers against it (structure only).
rbi:
	ruby bin/gen_rbi

rbi-check:
	ruby bin/gen_rbi --check

# The helpers (and anything else only the DSL declares) of every example, as Sorbet signatures.
HELPER_RBI_DIR = sorbet/rbi/rmcp_dsl
rbi-helpers:
	ruby exe/rmcp_dsl rbi examples/*.rb -o $(HELPER_RBI_DIR)

# Fails if the checked-in helper RBI differs from what the examples produce now.
rbi-helpers-check:
	rm -rf /tmp/rmcp_dsl_rbi_check && ruby exe/rmcp_dsl rbi examples/*.rb -o /tmp/rmcp_dsl_rbi_check
	diff -u $(HELPER_RBI_DIR)/dsl_helpers.rbi /tmp/rmcp_dsl_rbi_check/dsl_helpers.rbi || { echo "$(HELPER_RBI_DIR)/dsl_helpers.rbi is stale: run make rbi-helpers"; exit 1; }

# `bundle exec`: in CI (and for anyone without a global Sorbet) srb is only in the bundle, not on PATH.
typecheck: rbi-check rbi-helpers-check

	bundle exec srb tc

# Fast gate: parse, type-check and report notifications for every example, no output files.
dsl-check:
	ruby exe/rmcp_dsl examples/add.rmcp.rb --check
	ruby exe/rmcp_dsl examples/textkit.rmcp.rb --check
	ruby exe/rmcp_dsl examples/injected.rmcp.rb --check
	ruby exe/rmcp_dsl examples/hooked.rmcp.rb --check
	ruby exe/rmcp_dsl examples/exec.rmcp.rb --check
	ruby exe/rmcp_dsl examples/fetchkit.rmcp.rb --check
	ruby exe/rmcp_dsl examples/arith.rmcp.rb --check
	ruby exe/rmcp_dsl examples/bindings.rmcp.rb --check
	ruby exe/rmcp_dsl examples/webpeek.rmcp.rb --check
	ruby exe/rmcp_dsl examples/listkit.rmcp.rb --check
	ruby exe/rmcp_dsl examples/notekit.rmcp.rb --check
	ruby exe/rmcp_dsl examples/logkit.rmcp.rb --check
	ruby exe/rmcp_dsl examples/webkit.rmcp.rb --check
	ruby exe/rmcp_dsl examples/guide.rmcp.rb --check
	ruby exe/rmcp_dsl examples/formkit.rmcp.rb --check
	ruby exe/rmcp_dsl examples/mapkit.rmcp.rb --check
	ruby exe/rmcp_dsl examples/httpauth.rmcp.rb --check
	ruby exe/rmcp_dsl examples/httpoauth.rmcp.rb --check
	ruby exe/rmcp_dsl examples/statkit.rmcp.rb --check
	ruby exe/rmcp_dsl examples/httpkit.rmcp.rb --check

# Which Ruby the DSL body language compiles today, one construct at a time (no cargo needed).
probe:
	ruby bin/probe

# L5 for textkit: build the crate, run its regex-compile test, then talk MCP to it.
e2e-textkit:
	ruby exe/rmcp_dsl examples/textkit.rmcp.rb -o /tmp/textkit-out
	cd /tmp/textkit-out && cargo test -q
	sh test/e2e_textkit.sh /tmp/textkit-out

# L5 for the injected-Rust proof: needs the network once, to fetch the heck crate.
e2e-injected:
	ruby exe/rmcp_dsl examples/injected.rmcp.rb -o /tmp/injected-out
	sh test/e2e_injected.sh /tmp/injected-out

# L5 for rust_file: build a crate that includes examples/rust/shout.rs and call it.
e2e-hooked:
	ruby exe/rmcp_dsl examples/hooked.rmcp.rb -o /tmp/hooked-out
	sh test/e2e_hooked.sh /tmp/hooked-out

# L5 for subprocess tools (needs tr and sh on the machine).
e2e-exec:
	ruby exe/rmcp_dsl examples/exec.rmcp.rb -o /tmp/exec-out
	sh test/e2e_exec.sh /tmp/exec-out

# The slow subprocess failure paths (timeout, output cap). Run e2e-exec first to build the crate.
e2e-exec-slow:
	sh test/e2e_exec_slow.sh /tmp/exec-out

# fetchkit: the Rust unit tests in examples/rust/guard.rs run under cargo test, then the
# hermetic end-to-end run against the local fixture server (about 40 s; needs curl).
e2e-fetchkit:
	ruby exe/rmcp_dsl examples/fetchkit.rmcp.rb -o /tmp/fetchkit-out
	cd /tmp/fetchkit-out && cargo test -q
	sh test/e2e_fetchkit.sh /tmp/fetchkit-out

# Integer semantics: Ruby rounding by default, checked arithmetic with friendly errors.
e2e-arith:
	ruby exe/rmcp_dsl examples/arith.rmcp.rb -o /tmp/arith-out
	sh test/e2e_arith.sh /tmp/arith-out

# listkit: lists, nil-able values, case/when and the character methods, built to Rust and checked
# against Ruby's own answers. Part of make check, so generated Rust that fails to compile is caught.
e2e-listkit:
	ruby exe/rmcp_dsl build examples/listkit.rmcp.rb -o /tmp/listkit-out
	sh test/e2e_listkit.sh /tmp/listkit-out

# notekit: tool annotations, field constraints and optional fields, built to Rust and checked end to end.
e2e-notekit:
	ruby exe/rmcp_dsl build examples/notekit.rmcp.rb -o /tmp/notekit-out
	sh test/e2e_notekit.sh /tmp/notekit-out

# logkit: a server that declares `feature :logging` and logs from a tool body. The declaration advertises
# the logging capability and answers logging/setLevel; the e2e asserts notifications/message.
e2e-logkit:
	ruby exe/rmcp_dsl build examples/logkit.rmcp.rb -o /tmp/logkit-out
	sh test/e2e_logkit.sh /tmp/logkit-out

# webkit: a request guard and HTML selectors in Ruby plus bindings (url, std::net, scraper); no network needed.
e2e-webkit:
	ruby exe/rmcp_dsl build examples/webkit.rmcp.rb -o /tmp/webkit-out
	sh test/e2e_webkit.sh /tmp/webkit-out

# guide: a server with no tools, only a prompt and a resource.
e2e-guide:
	ruby exe/rmcp_dsl build examples/guide.rmcp.rb -o /tmp/guide-out
	sh test/e2e_guide.sh /tmp/guide-out

# formkit: list fields, a nested object, defaults and a format.
e2e-formkit:
	ruby exe/rmcp_dsl build examples/formkit.rmcp.rb -o /tmp/formkit-out
	sh test/e2e_formkit.sh /tmp/formkit-out

# statkit: structured output.
e2e-statkit:
	ruby exe/rmcp_dsl build examples/statkit.rmcp.rb -o /tmp/statkit-out
	sh test/e2e_statkit.sh /tmp/statkit-out

# httpkit: the server over streamable HTTP (needs curl).
e2e-httpkit:
	ruby exe/rmcp_dsl build examples/httpkit.rmcp.rb -o /tmp/httpkit-out
	sh test/e2e_httpkit.sh /tmp/httpkit-out

# httpauth: the same, behind `transport :http, auth_setting:` (a bearer token; needs curl).
e2e-httpauth:
	ruby exe/rmcp_dsl build examples/httpauth.rmcp.rb -o /tmp/httpauth-out
	sh test/e2e_httpauth.sh /tmp/httpauth-out

# httpoauth: the same, as an OAuth resource server against a local fake issuer (needs curl, ruby).
e2e-httpoauth:
	ruby exe/rmcp_dsl build examples/httpoauth.rmcp.rb -o /tmp/httpoauth-out
	sh test/e2e_httpoauth.sh /tmp/httpoauth-out

# lsp: the language server as a real process over stdio (needs ruby).
e2e-lsp:
	sh test/e2e_lsp.sh

# mapkit: typed maps in, out and in the body.
e2e-mapkit:
	ruby exe/rmcp_dsl build examples/mapkit.rmcp.rb -o /tmp/mapkit-out
	sh test/e2e_mapkit.sh /tmp/mapkit-out

# jsonkit: a binding's own type (Json::Value) as a tool field, a local and part of a structured result.
e2e-jsonkit:
	ruby exe/rmcp_dsl build examples/jsonkit.rmcp.rb -o /tmp/jsonkit-out
	sh test/e2e_jsonkit.sh /tmp/jsonkit-out

# taskkit: the tasks extension, driven from Ruby because a task id travels from one response into the next request.
e2e-taskkit:
	ruby exe/rmcp_dsl build examples/taskkit.rmcp.rb -o /tmp/taskkit-out
	ruby test/e2e_taskkit.rb /tmp/taskkit-out

# contentkit: image, audio, resource link and embedded resource blocks in tool results.
e2e-contentkit:
	ruby exe/rmcp_dsl build examples/contentkit.rmcp.rb -o /tmp/contentkit-out
	sh test/e2e_contentkit.sh /tmp/contentkit-out

# pathkit: resource templates with the RFC 6570 operators.
e2e-pathkit:
	ruby exe/rmcp_dsl build examples/pathkit.rmcp.rb -o /tmp/pathkit-out
	sh test/e2e_pathkit.sh /tmp/pathkit-out

# livekit: resource subscriptions and update / list_changed notifications.
e2e-livekit:
	ruby exe/rmcp_dsl build examples/livekit.rmcp.rb -o /tmp/livekit-out
	sh test/e2e_livekit.sh /tmp/livekit-out

# pagekit: paged lists with opaque cursors.
e2e-pagekit:
	ruby exe/rmcp_dsl build examples/pagekit.rmcp.rb -o /tmp/pagekit-out
	sh test/e2e_pagekit.sh /tmp/pagekit-out

# configkit: settings from the environment, required ones, defaults and secrets.
e2e-configkit:
	ruby exe/rmcp_dsl build examples/configkit.rmcp.rb -o /tmp/configkit-out
	sh test/e2e_configkit.sh /tmp/configkit-out

# schemakit: a hand-written input schema.
e2e-schemakit:
	ruby exe/rmcp_dsl build examples/schemakit.rmcp.rb -o /tmp/schemakit-out
	sh test/e2e_schemakit.sh /tmp/schemakit-out

# apikit: settings, a secret and an HTTP client against a local API.
e2e-apikit:
	ruby exe/rmcp_dsl build examples/apikit.rmcp.rb -o /tmp/apikit-out
	ruby test/e2e_apikit.rb /tmp/apikit-out

# shopkit: tools made from an OpenAPI document, against a local API.
e2e-shopkit:
	ruby exe/rmcp_dsl build examples/shopkit.rmcp.rb -o /tmp/shopkit-out
	ruby test/e2e_shopkit.rb /tmp/shopkit-out

# Build the gem, install it into a throwaway GEM_HOME and use it from outside the repository.
# skill needs spec/shims/, so this fails if it did not ship; bindings are found next to the file, in examples/bindings/.
GEM_TMP = /tmp/rmcp_dsl_gem
gem-test:
	rm -rf $(GEM_TMP) && mkdir -p $(GEM_TMP)
	gem build rmcp_dsl.gemspec --output $(GEM_TMP)/rmcp_dsl.gem
	GEM_HOME=$(GEM_TMP)/home gem install --no-document $(GEM_TMP)/rmcp_dsl.gem
	cd $(GEM_TMP) && GEM_HOME=$(GEM_TMP)/home $(GEM_TMP)/home/bin/rmcp_dsl --version
	cd $(GEM_TMP) && GEM_HOME=$(GEM_TMP)/home $(GEM_TMP)/home/bin/rmcp_dsl check $(CURDIR)/examples/bindings.rmcp.rb
	cd $(GEM_TMP) && GEM_HOME=$(GEM_TMP)/home $(GEM_TMP)/home/bin/rmcp_dsl skill -o $(GEM_TMP)/skill
	test -f $(GEM_TMP)/skill/rmcp-dsl/references/body-language.md
	test -f $(GEM_TMP)/home/gems/rmcp_dsl-*/docs/versions.md

# webpeek: fetch and read pages with no hand-written Rust, against the local fixture server (about 30 s; needs curl).
e2e-webpeek:
	ruby exe/rmcp_dsl build examples/webpeek.rmcp.rb -o /tmp/webpeek-out
	sh test/e2e_webpeek.sh /tmp/webpeek-out

# Bindings: Heck (the heck crate, needs the network once) and Words (compiled from Ruby).
e2e-bindings:
	ruby exe/rmcp_dsl examples/bindings.rmcp.rb -o /tmp/bindings-out
	sh test/e2e_bindings.sh /tmp/bindings-out
