# frozen_string_literal: true

module RmcpDsl
  # IR -> Rust text. No Prism from here on.
  module Emit
    # Rust helper for cmd_fn / script_fn. Arguments are separate argv entries (never shell
    # text); the environment is reduced to PATH; 10 s timeout; 1 MB output cap.
    RUN_SUBPROCESS = <<~'RS'
      fn run_subprocess(program: &str, argv: &[String], stdin: Option<&str>) -> String {
          use std::io::{Read, Write};
          use std::process::{Command, Stdio};
          use std::time::{Duration, Instant};

          const TIMEOUT: Duration = Duration::from_secs(10);
          const MAX_OUT: u64 = 1_000_000;

          let mut child = match Command::new(program)
              .args(argv)
              .env_clear()
              .env("PATH", std::env::var_os("PATH").unwrap_or_default())
              .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
              .stdout(Stdio::piped())
              .stderr(Stdio::piped())
              .spawn()
          {
              Ok(child) => child,
              Err(e) => return format!("error: cannot start {program}: {e}"),
          };
          let out = child.stdout.take();
          let err = child.stderr.take();
          let read_out = std::thread::spawn(move || {
              let mut buf = Vec::new();
              if let Some(r) = out {
                  let _ = r.take(MAX_OUT + 1).read_to_end(&mut buf);
              }
              buf
          });
          let read_err = std::thread::spawn(move || {
              let mut buf = Vec::new();
              if let Some(r) = err {
                  let _ = r.take(MAX_OUT).read_to_end(&mut buf);
              }
              buf
          });
          if let (Some(text), Some(mut pipe)) = (stdin, child.stdin.take()) {
              let _ = pipe.write_all(text.as_bytes());
          }
          let start = Instant::now();
          let status = loop {
              match child.try_wait() {
                  Ok(Some(status)) => break status,
                  Ok(None) if start.elapsed() > TIMEOUT => {
                      let _ = child.kill();
                      let _ = child.wait();
                      return format!("error: {program} timed out after {} s", TIMEOUT.as_secs());
                  }
                  Ok(None) => std::thread::sleep(Duration::from_millis(10)),
                  Err(e) => return format!("error: waiting for {program}: {e}"),
              }
          };
          let out_bytes = read_out.join().unwrap_or_default();
          if out_bytes.len() as u64 > MAX_OUT {
              return format!("error: {program} produced more than {MAX_OUT} bytes of output");
          }
          let stdout = String::from_utf8_lossy(&out_bytes).into_owned();
          let stderr = String::from_utf8_lossy(&read_err.join().unwrap_or_default()).into_owned();
          if status.success() {
              stdout.strip_suffix('\n').unwrap_or(&stdout).to_string()
          } else {
              format!("error: {program} exited with {status}: {}", stderr.trim())
          }
      }
    RS

    # Overflow-checked integer arithmetic. Ruby integers never overflow, so rather than panic
    # (debug) or wrap (release), a failing operation returns text that says what went wrong,
    # where, and how to fix it. Only the operations a server actually uses are emitted (one small
    # function per operation and type), so generated code has no unused items and rustc's
    # dead-code warning stays a real check on this generator.
    ARITH_ERROR = <<~'RS'
      fn arith_error(op: &str, a: impl std::fmt::Display, b: impl std::fmt::Display, b_is_zero: bool, ty: &str, min: i128, max: i128, at: &str) -> String {
          if b_is_zero && (op == "/" || op == "%") {
              format!("error: division by zero at {at}: {a} {op} 0. Fix: check that the divisor is not zero before dividing, or reject that input.")
          } else {
              let fix = if ty == "i64" {
                  "i64 is already the widest integer type here, so limit the input range before this operation"
              } else {
                  "declare the field as :i64 for a wider range, or limit the input range before this operation"
              };
              format!("error: integer overflow at {at}: {a} {op} {b} does not fit in {ty} ({min}..={max}). Fix: {fix}.")
          }
      }
    RS

    # kind => [operator shown in messages, Rust expression over a and b returning an Option].
    # fdiv / fmod round down like Ruby; div / rem truncate like Rust (Rust::Int32 operands).
    CHECKED_BIN = {
      "add" => ["+", "a.checked_add(b)"],
      "sub" => ["-", "a.checked_sub(b)"],
      "mul" => ["*", "a.checked_mul(b)"],
      "div" => ["/", "a.checked_div(b)"],
      "rem" => ["%", "a.checked_rem(b)"],
      "fdiv" => ["/", "a.checked_div(b).and_then(|q| { let r = a % b; if r != 0 && ((r < 0) != (b < 0)) { q.checked_sub(1) } else { Some(q) } })"],
      "fmod" => ["%", "a.checked_rem(b).and_then(|r| if r != 0 && ((r < 0) != (b < 0)) { r.checked_add(b) } else { Some(r) })"]
    }.freeze

    # String#to_i with Ruby's rules (leading whitespace, optional sign, digits with single underscores
    # between them, stop at anything else, no digits is 0), returning an i64. A value that does not
    # fit is an error: Ruby would return a bignum, and a silent wrong number is worse. The shim catalog
    # test (bin/gen_shim_tests) pastes this same text, so Ruby and Rust are compared on its examples.
    STR_TO_I = <<~'RS'
      fn str_to_i(s: &str, at: &str) -> Result<i64, String> {
          let mut chars = s
              .trim_start_matches(|c: char| matches!(c, ' ' | '\t' | '\n' | '\u{b}' | '\u{c}' | '\r'))
              .chars()
              .peekable();
          let negative = match chars.peek() {
              Some('-') => {
                  chars.next();
                  true
              }
              Some('+') => {
                  chars.next();
                  false
              }
              _ => false,
          };
          let mut value: i128 = 0;
          let mut overflow = false;
          let mut after_digit = false;
          while let Some(&c) = chars.peek() {
              if c.is_ascii_digit() {
                  chars.next();
                  after_digit = true;
                  if !overflow {
                      match value.checked_mul(10).and_then(|v| v.checked_add(c as i128 - '0' as i128)) {
                          Some(v) if v <= i64::MAX as i128 + 1 => value = v,
                          _ => overflow = true,
                      }
                  }
              } else if c == '_' && after_digit {
                  chars.next();
                  match chars.peek() {
                      Some(d) if d.is_ascii_digit() => {}
                      _ => break,
                  }
              } else {
                  break;
              }
          }
          let signed = if negative { -value } else { value };
          if overflow || signed > i64::MAX as i128 || signed < i64::MIN as i128 {
              return Err(format!(
                  "error: integer overflow at {at}: {s:?} does not fit in i64 ({}..={}). Fix: check the length of the input before converting it.",
                  i64::MIN,
                  i64::MAX
              ));
          }
          Ok(signed as i64)
      }
    RS

    # Integer(text, 10): strict decimal parsing. Surrounding whitespace, a sign and single underscores
    # between digits are accepted; anything else is an error, as Ruby raises ArgumentError. i64 result,
    # with an overflow error instead of a bignum. Pasted into the shim test file like STR_TO_I.
    STR_TO_INT = <<~'RS'
      fn str_to_int(s: &str, at: &str) -> Result<i64, String> {
          let t = s.trim_matches(|c: char| matches!(c, ' ' | '\t' | '\n' | '\u{b}' | '\u{c}' | '\r'));
          let (negative, digits) = match t.as_bytes().first() {
              Some(b'-') => (true, &t[1..]),
              Some(b'+') => (false, &t[1..]),
              _ => (false, t),
          };
          let well_formed = !digits.is_empty()
              && !digits.starts_with('_')
              && !digits.ends_with('_')
              && !digits.contains("__")
              && digits.chars().all(|c| c.is_ascii_digit() || c == '_');
          if !well_formed {
              return Err(format!("error: invalid value for Integer(): {s:?} at {at}"));
          }
          let mut value: i128 = 0;
          for c in digits.chars().filter(|c| *c != '_') {
              match value.checked_mul(10).and_then(|v| v.checked_add(c as i128 - '0' as i128)) {
                  Some(v) if v <= i64::MAX as i128 + 1 => value = v,
                  _ => {
                      return Err(format!(
                          "error: integer overflow at {at}: {s:?} does not fit in i64 ({}..={}). Fix: check the length of the input before converting it.",
                          i64::MIN,
                          i64::MAX
                      ))
                  }
              }
          }
          let signed = if negative { -value } else { value };
          if signed > i64::MAX as i128 || signed < i64::MIN as i128 {
              return Err(format!(
                  "error: integer overflow at {at}: {s:?} does not fit in i64 ({}..={}). Fix: check the length of the input before converting it.",
                  i64::MIN,
                  i64::MAX
              ));
          }
          Ok(signed as i64)
      }
    RS

    module_function

    def files(ir, src)
      CompositeTypes::Opaque.reset(ir["opaque_types"].to_a) # Emit holds no state: the types a binding owns come from the IR
      main, map = main_rs(ir, src)
      files = { "Cargo.toml" => cargo(ir), "src/main.rs" => main, CargoBuild::MAP => "#{JSON.pretty_generate(map)}\n" }
      ir["modules"].to_a.each { |m| files["src/#{m['name']}.rs"] = m["source"] }
      files
    end

    # name and version are validated in Reader (name regex, SEMVER), so plain
    # interpolation into TOML is safe here.
    def cargo(ir)
      <<~TOML
        [package]
        name = "#{ir['name']}"
        version = "#{ir['version']}"
        edition = "2021"

        [dependencies]
        # rmcp 3.5.0 resolved on the first host build (2026-10-03); it uses schemars 1.x.
        rmcp = { version = "3.5", features = [#{http?(ir) ? '"server", "transport-streamable-http-server"' : '"server", "transport-io"'}] }
        serde = { version = "1", features = ["derive"] }
        schemars = "1"
        tokio = { version = "1", features = ["full"] }
        anyhow = "1"#{http?(ir) ? "\naxum = { version = \"0.8\", default-features = false, features = [\"http1\", \"tokio\"] }" : ""}#{regex_dep(ir)}#{crate_deps(ir)}
      TOML
    end

    def http?(ir) = ir["transport"] == "http"

    # The regex crate is only a dependency when some body uses a regex literal.
    def regex_dep(ir) = ir["regexes"].to_a.empty? ? "" : "\nregex = \"1\""

    # Extra dependencies declared with rust_crate (name and version validated in Reader).
    def crate_deps(ir) = ir["crates"].to_a.map { |c| "\n#{c['name']} = \"#{c['version']}\"" }.join

    def main_rs(ir, src)
      srv = ir["name"].split(/[-_]/).map(&:capitalize).join
      regexes = ir["regexes"].to_a
      o = []
      ranges = []
      o << "// Generated by rmcp_dsl from #{File.basename(src)}. Do not edit."
      # Parameters wraps a tool's or prompt's arguments; a server of only resources never names it
      wrapper = ir["tools"].any? { |t| t["output"] } ? "{Json, Parameters}" : "Parameters"
      uses_parameters = !ir["tools"].empty? || !ir["prompts"].to_a.empty?
      o << "use rmcp::{#{"handler::server::wrapper::#{wrapper}, " if uses_parameters}tool_handler, tool_router, ServerHandler#{http?(ir) ? "" : ", ServiceExt"}};"
      o << "use rmcp::tool;" unless ir["tools"].empty?
      o << "use schemars::JsonSchema;"
      o << "use serde::{Deserialize, Serialize};"
      # a paged server writes list_prompts and get_prompt itself, so it never names prompt_handler
      o << "use rmcp::{prompt, #{'prompt_handler, ' unless paged?(ir)}prompt_router};" unless ir["prompts"].to_a.empty?
      o << "use rmcp::model::{PromptMessage, Role};" unless ir["prompts"].to_a.empty?
      o << "use rmcp::task_manager::{TaskExit, TaskManager, TaskOptions};" if tasks?(ir)
      o << "use rmcp::model::{CompleteRequestParams, CompleteResult, CompletionInfo, Reference};" if completions?(ir)
      unless ir["resources"].to_a.empty?
        o << "use rmcp::model::{ListResourcesResult, PaginatedRequestParams, ReadResourceRequestParams, ReadResourceResponse, ReadResourceResult, #{"Resource, " unless ir["resources"].all? { |res| res["template"] }}ResourceContents#{templates?(ir) ? ", ListResourceTemplatesResult, ResourceTemplate" : ""}};"
      end
      # the handler methods written out (resources, completion, tasks, paged lists) take a request context
      if tasks?(ir) || completions?(ir) || paged?(ir) || !ir["resources"].to_a.empty?
        o << "use rmcp::service::RequestContext;"
        o << "use rmcp::RoleServer;"
      end
      cb = ir["tools"].any? { |t| t["body"]["fallible"] || t["body"]["type"] == "blocks" || checked?(ir["params"].find { |x| x["name"] == t["params"] }, ir) }
      if cb
        o << "use rmcp::model::{CallToolResult, ContentBlock};"
      elsif ir["tools"].any? { |t| t["output"] }
        o << "use rmcp::model::CallToolResult;"
      end
      unless regexes.empty?
        o << "use regex::Regex;"
        o << "use std::sync::LazyLock;"
      end
      ir["modules"].to_a.each { |m| o << "mod #{m['name']};" }
      o << ""
      ir["params"].each do |p|
        mapped(o, ranges, p["line"], "params `#{p['name']}`") do
          o << "#[derive(Debug, Serialize, Deserialize, JsonSchema)]"
          o << "struct #{p['name']} {"
          p["fields"].each do |f|
            field_attrs(f, p["name"]).each { |a| o << "    #{a}" }
            ty = field_rust_type(f["type"])
            o << "    #{f['name']}: #{f['optional'] ? "Option<#{ty}>" : ty},"
          end
          o << "}"
        end
        p["fields"].select { |f| f.key?("default") }.each { |f| o.concat(["", *default_fn(p["name"], f)]) }
        o.concat(["", *check_impl(p, ir)]) if checked?(p, ir)
        o << ""
      end
      ir["outputs"].to_a.each do |p|
        mapped(o, ranges, p["line"], "output `#{p['name']}`") do
          o << "#[derive(Serialize, JsonSchema)]"
          o << "struct #{p['name']} {"
          p["fields"].each do |f|
            field_attrs(f, p["name"]).each { |a| o << "    #{a}" }
            ty = field_rust_type(f["type"])
            o << "    #{f['name']}: #{f['optional'] ? "Option<#{ty}>" : ty},"
          end
          o << "}"
        end
        o << ""
      end
      o.concat([*PERCENT_DECODE.lines.map(&:chomp), ""]) if templates?(ir)
      o.concat([*PERCENT_LIST.lines.map(&:chomp), ""]) if template_vars?(ir) { |v| v["explode"] }
      o.concat([*QUERY_PARAM.lines.map(&:chomp), ""]) if template_vars?(ir) { |v| v["op"] == "?" }
      o.concat([*META_OBJECT.lines.map(&:chomp), ""]) if meta?(ir)
      regexes.each do |r|
        o << "static #{r['id']}: LazyLock<Regex> = LazyLock::new(|| Regex::new(#{RmcpDsl.rstr(r['pattern'])}).unwrap());"
      end
      o << "" unless regexes.empty?
      ir["items"].to_a.each do |code|
        o << "// injected Rust (rust_item): written by hand, not generated"
        o.concat(code.lines.map(&:chomp))
        o << ""
      end
      if ir["subprocs"].to_a.any? || ir["modules"].to_a.any? { |m| m["uses"] == "subprocess" }
        o << "// subprocess helper and wrappers (cmd_fn / script_fn): written by the compiler"
        o.concat(RUN_SUBPROCESS.lines.map(&:chomp))
        o << ""
        ir["subprocs"].to_a.each do |sp|
          mapped(o, ranges, sp["line"], "subprocess `#{sp['name']}`") { o.concat(subproc_fn(sp)) }
          o << ""
        end
      end
      ir["binding_fns"].to_a.each do |b|
        o << "// binding function (see bindings/): written by the compiler"
        o.concat(binding_fn(b))
        o << ""
      end
      unless ir["checked"].to_a.empty?
        o << "// overflow-checked integer arithmetic (only what this server uses): written by the compiler"
        o.concat(checked_int_lines(ir["checked"]))
      end
      { "str_to_i" => ["String#to_i", STR_TO_I], "str_to_int" => ["Integer(text, 10)", STR_TO_INT] }.each do |key, (what, rust)|
        next unless ir["helpers"].to_a.include?(key)

        o << "// #{what} (Ruby rules, i64 result): written by the compiler"
        o.concat(rust.lines.map(&:chomp))
        o << ""
      end
      ir["user_helpers"].to_a.each do |h|
        mapped(o, ranges, h["line"], "helper `#{h['name']}`") { o.concat(helper_fn(h)) }
        o << ""
      end
      # One task manager for the whole process, so a task survives the session that created it (HTTP makes a handler
      # per session) and a client can poll it after reconnecting.
      o.concat(["static TASKS: std::sync::LazyLock<TaskManager> = std::sync::LazyLock::new(TaskManager::new);", ""]) if tasks?(ir)
      o.concat([*notify_runtime(ir), ""]) if notifies?(ir)
      o.concat([*page_fn(ir), ""]) if paged?(ir)
      o << "#[derive(Clone)]"
      o << "struct #{srv};"
      o << ""
      # tool_router refuses an impl with no tools unless told it is intended (a server of only prompts and resources).
      o << (ir["tools"].empty? ? "#[tool_router(allow_empty)]" : "#[tool_router]")
      o << "impl #{srv} {"
      ir["tools"].each_with_index do |t, i|
        o << "" if i.positive?
        mapped(o, ranges, t["line"], "tool `#{t['name']}`") { o.concat(tool_fn(t, ir)) }
      end
      o << "}"
      o << ""
      prompts = ir["prompts"].to_a
      resources = ir["resources"].to_a
      unless prompts.empty?
        o << "#[prompt_router]"
        o << "impl #{srv} {"
        prompts.each_with_index do |pr, i|
          o << "" if i.positive?
          mapped(o, ranges, pr["line"], "prompt `#{pr['name']}`") { o.concat(prompt_fn(pr, ir)) }
        end
        o << "}"
        o << ""
      end
      unless resources.empty?
        o << "impl #{srv} {"
        resources.each_with_index do |res, i|
          o << "" if i.positive?
          mapped(o, ranges, res["line"], "resource `#{res['name']}`") { o.concat(resource_fn(res, ir)) }
        end
        o << "}"
        o << ""
      end
      # Explicit handler instead of `#[tool_router(server_handler)]`, which would leave
      # the MCP serverInfo as rmcp's own name and version (rmcp-macros 3.5.0). The macro writes get_info()
      # and enables the tools capability, and the prompts capability when `prompt_handler` is on the same
      # impl. Resources have no macro, so a server with resources writes get_info() and the two resource
      # methods itself.
      # Title, description, website and icon do not fit the macro's attributes either, so they also mean a
      # hand-written get_info().
      manual = !resources.empty? || completions?(ir) || tasks?(ir) || paged?(ir) || %w[title description website_url icon].any? { |k| ir[k] }
      extra = ir["instructions"] ? ", instructions = #{RmcpDsl.rstr(ir['instructions'])}" : ""
      if manual
        o << "#[tool_handler(router = Self::tool_router())]"
      else
        o << "#[tool_handler(router = Self::tool_router(), name = #{RmcpDsl.rstr(ir['name'])}, version = #{RmcpDsl.rstr(ir['version'])}#{extra})]"
      end
      o << "#[prompt_handler]" unless prompts.empty? || paged?(ir) # a paged server writes list_prompts and get_prompt itself
      if manual
        o << "impl ServerHandler for #{srv} {"
        o.concat(resources.empty? ? get_info_lines(ir, prompts) : resource_handler(ir, prompts))
        o.concat(["", *complete_lines(ir)]) if completions?(ir)
        o.concat(["", *paged_list_lines(ir)]) if paged?(ir)
        o.concat(["", *task_lines(ir)]) if tasks?(ir)
        o.concat(["", *notify_lines(ir)]) if notifies?(ir)
        o << "}"
      else
        o << "impl ServerHandler for #{srv} {}"
      end
      o << ""
      o.concat(main_fn(ir, srv))
      o.concat(regex_test(regexes))
      ["#{o.join("\n")}\n", source_map(o, ranges, src)]
    end

    # Records that o[first..last], as built by the block, came from the DSL declaration at `line`.
    def mapped(o, ranges, line, what)
      first = o.size
      yield
      ranges << [first, o.size - 1, line, what] if line
    end

    # Which main.rs lines each DSL declaration produced, so CargoBuild can point rustc errors
    # back at the DSL. Lines are 1-based and inclusive; an element of `o` may hold newlines.
    def source_map(o, ranges, src)
      start = []
      at = 1
      o.each do |s|
        start << at
        at += 1 + s.count("\n")
      end
      { "source" => src,
        "ranges" => ranges.map do |first, last, line, what|
          { "from" => start[first], "to" => start[last] + o[last].count("\n"), "dsl_line" => line, "what" => what }
        end }
    end

    # One wrapper per binding function the server calls. The types come from the binding's sig, so
    # rustc checks a `rust "..."` template against them; a Ruby-bodied binding is compiled here.
    def binding_fn(b)
      params = b["args"].map { |n, t| "#{n}: #{rust_type(t, param: true)}" }
      lines = ["fn #{b['name']}(#{params.join(', ')}) -> #{rust_type(b['returns'])} {"]
      if b["rust"]
        lines << "    #{b['rust']}"
      else
        lines.concat(body_lines(b["body"]).map { |l| "    #{l}" })
      end
      lines << "}"
    end

    # A helper is a plain function over owned values. If its body can fail (raise, return, checked
    # arithmetic, to_i, a helper that can fail) it returns Result<T, String> and callers use `?`.
    def helper_fn(h)
      params = h["args"].map { |n, t| "#{n}: #{rust_type(t)}" }.join(", ")
      ret = rust_type(h["returns"])
      body = h["body"]
      locals = body["locals"].map { |l| "    #{l}" }
      if body["fallible"]
        ["fn helper_#{h['name']}(#{params}) -> Result<#{ret}, String> {", *locals, "    Ok(#{body['expr']})", "}"]
      else
        ["fn helper_#{h['name']}(#{params}) -> #{ret} {", *locals, "    #{body['expr']}", "}"]
      end
    end

    # The Rust type of a DSL type: parameters borrow (&str, &[String]), results own. Nil-able types are Option.
    def rust_type(type, param: false)
      if CompositeTypes::Opaque.symbol?(type)
        rust = CompositeTypes::Opaque.rust(CompositeTypes::Opaque.name_of(type))
        return param ? "&#{rust}" : rust
      end
      if (inner = Body::OPT[type.to_sym]) && CompositeTypes::Opaque.symbol?(inner)
        return "Option<#{CompositeTypes::Opaque.rust(CompositeTypes::Opaque.name_of(inner))}>"
      end

      case type.to_sym
      when :string then param ? "&str" : "String"
      when :strs then param ? "&[String]" : "Vec<String>"
      when :i64s then param ? "&[i64]" : "Vec<i64>"
      when :ostr then "Option<String>"
      when :oi64 then "Option<i64>"
      when :oi32 then "Option<i32>"
      when :of64 then "Option<f64>"
      when :obool then "Option<bool>"
      when :ostrs then "Option<Vec<String>>"
      when :oi64s then "Option<Vec<i64>>"
      else TYPES.fetch(type.to_sym)
      end
    end

    # Rust for exactly the checked operations a server uses (keys like "add:i32", "neg:i64").
    def checked_int_lines(used)
      lines = []
      unless used.all? { |u| u.start_with?("neg:") }
        lines.concat(ARITH_ERROR.lines.map(&:chomp))
        lines << ""
      end
      used.each do |key|
        kind, ty = key.split(":")
        if kind == "neg"
          lines << "fn ck_neg_#{ty}(a: #{ty}, at: &str) -> Result<#{ty}, String> {"
          lines << "    a.checked_neg().ok_or_else(|| {"
          lines << "        format!(\"error: integer overflow at {at}: negating {a} does not fit in #{ty} ({}..={}). " \
                   "Fix: limit the input range before negating, or use a wider type.\", #{ty}::MIN, #{ty}::MAX)"
        else
          op, expr = CHECKED_BIN.fetch(kind)
          lines << "fn ck_#{kind}_#{ty}(a: #{ty}, b: #{ty}, at: &str) -> Result<#{ty}, String> {"
          lines << "    #{expr}.ok_or_else(|| {"
          lines << "        arith_error(#{RmcpDsl.rstr(op)}, a, b, b == 0, \"#{ty}\", #{ty}::MIN as i128, #{ty}::MAX as i128, at)"
        end
        lines << "    })"
        lines << "}"
        lines << ""
      end
      lines
    end

    # A tool with an output returns Json<Output>, which rmcp turns into structured content plus the text of
    # the same JSON, and publishes the type's schema as the tool's outputSchema. A failure is still an
    # isError result, so the Err side is a CallToolResult.
    def output_lines(b, out)
      return [*b["locals"], "Ok(Json(#{b['expr']}))"] unless b["fallible"]

      ["match (|| -> Result<#{out}, String> {",
       *b["locals"].map { |l| "    #{l}" },
       "    Ok(#{b['expr']})",
       "})() {",
       "    Ok(v) => Ok(Json(v)),",
       "    Err(e) => Err(CallToolResult::error(vec![ContentBlock::text(e)])),",
       "}"]
    end

    # A body that uses checked arithmetic or `raise` runs in a closure so `?` and `return Err` can
    # leave it. A tool (mcp: true) turns the error into an MCP error result, isError: true; a
    # binding function returns the error text as its String.
    def body_lines(b, mcp: false, force: false)
      return b["locals"] + [b["expr"]] unless b["fallible"] || force

      blocks = b["type"] == "blocks" # the body ends in content blocks, not a string
      ok, err = mcp ? [blocks ? "CallToolResult::success(s)" : "CallToolResult::success(vec![ContentBlock::text(s)])", "CallToolResult::error(vec![ContentBlock::text(e)])"] : %w[s e]
      ok_type = blocks ? "Vec<ContentBlock>" : "String"
      [mcp ? "Ok(match (|| -> Result<#{ok_type}, String> {" : "match (|| -> Result<#{ok_type}, String> {",
       *b["locals"].map { |l| "    #{l}" },
       "    Ok(#{b['expr']})",
       "})() {",
       "    Ok(s) => #{ok},",
       "    Err(e) => #{err},",
       mcp ? "})" : "}"]
    end

    # Field options the generated server enforces itself (the JSON schema only advises the client).
    CHECKED_OPTIONS = %w[min max min_length max_length pattern enum min_items max_items].freeze
    ANNOTATION_ATTRS = { "read_only" => "read_only_hint", "destructive" => "destructive_hint",
                         "idempotent" => "idempotent_hint", "open_world" => "open_world_hint" }.freeze

    # Does this params struct (or an object nested in it) have constraints the server enforces itself?
    def checked?(params, ir = nil)
      params["fields"].any? do |f|
        CHECKED_OPTIONS.any? { |k| f.key?(k) } ||
          (ir && f["type"].match?(CAMEL) && (inner = ir["params"].find { |x| x["name"] == f["type"] }) && checked?(inner, ir))
      end
    end

    # The Rust type of a field: scalars, lists, or the name of a nested params struct.
    def field_rust_type(type)
      case type
      when "string_list" then "Vec<String>"
      when "i64_list" then "Vec<i64>"
      when CompositeTypes::MAP_FIELD then CompositeTypes.map_rust(CompositeTypes.field_symbol(type).then { |s| CompositeTypes.map_value(s) })
      when CAMEL then type
      when CompositeTypes::OPAQUE_FIELD then CompositeTypes::Opaque.rust(type)
      else TYPES.fetch(type.to_sym)
      end
    end

    # serde calls this when the field is missing, and schemars reads it for the schema's default.
    def default_fn(struct, f)
      value =
        case f["type"]
        when "string" then "#{RmcpDsl.rstr(f['default'])}.to_string()"
        when "f64" then f["default"].to_f.to_s
        else f["default"].to_s
        end
      ["fn #{default_name(struct, f)}() -> #{field_rust_type(f['type'])} {", "    #{value}", "}"]
    end

    def default_name(struct, f) = "default_#{struct.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase}_#{f['name']}"

    # A numeric bound as a Rust literal of the field's type (f64 needs a decimal point).
    def bound(field, value) = field["type"] == "f64" ? value.to_f.to_s : value.to_s

    # The #[schemars(...)] attributes of a field: its description and JSON schema constraints.
    def field_attrs(f, struct)
      attrs = []
      attrs << "#[schemars(description = #{RmcpDsl.rstr(f['description'])})]" if f["description"]
      bounds = %w[min max].select { |k| f.key?(k) }.map { |k| "#{k} = #{bound(f, f[k])}" }
      attrs << "#[schemars(range(#{bounds.join(', ')}))]" unless bounds.empty?
      lengths = %w[min max].select { |k| f.key?("#{k}_length") || f.key?("#{k}_items") }.map { |k| "#{k} = #{f["#{k}_length"] || f["#{k}_items"]}" }
      attrs << "#[schemars(length(#{lengths.join(', ')}))]" unless lengths.empty?
      attrs << "#[schemars(regex(pattern = #{RmcpDsl.rstr(f['pattern'])}))]" if f["pattern"]
      attrs << "#[schemars(extend(\"enum\" = [#{f['enum'].map { |v| RmcpDsl.rstr(v) }.join(', ')}]))]" if f["enum"]
      attrs << "#[serde(default = \"#{default_name(struct, f)}\")]" if f.key?("default")
      attrs << "#[schemars(extend(\"format\" = #{RmcpDsl.rstr(f['format'])}))]" if f["format"]
      attrs
    end

    # impl P { fn check(&self) }: rejects values that break a constraint, with an error message.
    def check_impl(params, ir)
      body = params["fields"].flat_map { |f| field_checks(f, ir) }
      ["impl #{params['name']} {", "    fn check(&self) -> Result<(), String> {",
       *body.map { |l| "        #{l}" }, "        Ok(())", "    }", "}"]
    end

    def field_checks(f, ir)
      name = RmcpDsl.rstr(f["name"])
      if f["type"].match?(CAMEL) # a nested object checks itself
        inner = ir["params"].find { |x| x["name"] == f["type"] }
        return [] unless inner && checked?(inner, ir)

        return ["if let Err(e) = self.#{f['name']}.check() {", "    return Err(e);", "}"]
      end
      tests = []
      fail_if = lambda do |cond, fmt, *args|
        tests.push("if #{cond} {", "    return Err(format!(#{RmcpDsl.rstr(fmt)}, #{[name, *args].join(', ')}));", "}")
      end
      fail_if.call("*v < #{bound(f, f['min'])}", "error: invalid value for {}: {} is below the minimum of {}", "v", RmcpDsl.rstr(bound(f, f["min"]))) if f["min"]
      fail_if.call("*v > #{bound(f, f['max'])}", "error: invalid value for {}: {} is above the maximum of {}", "v", RmcpDsl.rstr(bound(f, f["max"]))) if f["max"]
      if f["min_length"]
        fail_if.call("v.chars().count() < #{f['min_length']}", "error: invalid value for {}: it has {} characters, fewer than the minimum of {}",
                     "v.chars().count()", f["min_length"].to_s)
      end
      if f["max_length"]
        fail_if.call("v.chars().count() > #{f['max_length']}", "error: invalid value for {}: it has {} characters, more than the maximum of {}",
                     "v.chars().count()", f["max_length"].to_s)
      end
      if f["min_items"]
        fail_if.call("v.len() < #{f['min_items']}", "error: invalid value for {}: it has {} items, fewer than the minimum of {}", "v.len()", f["min_items"].to_s)
      end
      if f["max_items"]
        fail_if.call("v.len() > #{f['max_items']}", "error: invalid value for {}: it has {} items, more than the maximum of {}", "v.len()", f["max_items"].to_s)
      end
      fail_if.call("!#{f['pattern_id']}.is_match(v)", "error: invalid value for {}: {:?} does not match the pattern {}", "v", RmcpDsl.rstr(f["pattern"])) if f["pattern"]
      if f["enum"]
        list = f["enum"].map { |v| RmcpDsl.rstr(v) }.join(", ")
        fail_if.call("![#{list}].contains(&v.as_str())", "error: invalid value for {}: {:?} is not one of {}", "v", RmcpDsl.rstr(f["enum"].join(", ")))
      end
      return [] if tests.empty?

      if f["optional"]
        ["if let Some(v) = &self.#{f['name']} {", *tests.map { |l| "    #{l}" }, "}"]
      else
        ["{", "    let v = &self.#{f['name']};", *tests.map { |l| "    #{l}" }, "}"]
      end
    end

    # #[tool(description = ..., annotations(...))]: the annotations tell a client whether a tool is safe to
    # call without asking.
    def tool_attr(tool)
      ann = tool["annotations"] || {}
      parts = []
      parts << "title = #{RmcpDsl.rstr(ann['title'])}" if ann["title"]
      ANNOTATION_ATTRS.each { |key, rust| parts << "#{rust} = #{ann[key]}" if ann.key?(key) }
      extra = parts.empty? ? "" : ", annotations(#{parts.join(', ')})"
      extra = ", title = #{RmcpDsl.rstr(ann['title'])}#{extra}" if ann["title"]
      extra += ", icons = #{icon_list(tool['icon'])}" if tool["icon"]
      extra += ", meta = #{meta_expr(tool['meta'])}" if tool["meta"]
      "    #[tool(description = #{RmcpDsl.rstr(tool['description'])}#{extra})]"
    end

    # A prompt method: the body's string becomes one user message. A broken constraint or a failure in the
    # body is a protocol error (invalid params), because a prompt has no error-result form.
    def prompt_fn(pr, ir)
      prm = ir["params"].find { |x| x["name"] == pr["params"] }
      messages = pr["messages"] || [{ "role" => "user", "body" => pr["body"] }]
      used = messages.flat_map { |m| m["body"]["args"] }.uniq
      pat =
        if used.empty? then "_"
        else "#{prm['name']} { #{used.join(', ')}#{used.size < prm['fields'].size ? ', ..' : ''} }"
        end
      checked = checked?(prm, ir)
      head =
        if checked
          ["    async fn prompt_#{pr['name']}(&self, Parameters(params): Parameters<#{prm['name']}>) -> Result<Vec<PromptMessage>, rmcp::ErrorData> {",
           "        if let Err(e) = params.check() {",
           "            return Err(rmcp::ErrorData::invalid_params(e, None));",
           "        }",
           *(used.empty? ? [] : ["        let #{pat} = params;"])]
        else
          ["    async fn prompt_#{pr['name']}(&self, Parameters(#{pat}): Parameters<#{prm['name']}>) -> Result<Vec<PromptMessage>, rmcp::ErrorData> {"]
        end
      attrs = "name = #{RmcpDsl.rstr(pr['name'])}, description = #{RmcpDsl.rstr(pr['description'])}"
      attrs += ", title = #{RmcpDsl.rstr(pr['title'])}" if pr["title"]
      attrs += ", icons = #{icon_list(pr['icon'])}" if pr["icon"]
      attrs += ", meta = #{meta_expr(pr['meta'])}" if pr["meta"]
      # Each message is computed on its own; the first one that fails ends the prompt.
      built = messages.flat_map do |m|
        b = m["body"]
        role = m["role"] == "assistant" ? "Role::Assistant" : "Role::User"
        ["        match (|| -> Result<String, String> {",
         *b["locals"].map { |l| "            #{l}" },
         "            Ok(#{b['expr']})",
         "        })() {",
         "            Ok(s) => messages.push(PromptMessage::new_text(#{role}, s)),",
         "            Err(e) => return Err(rmcp::ErrorData::invalid_params(e, None)),",
         "        }"]
      end
      ["    #[prompt(#{attrs})]", *head,
       "        let mut messages: Vec<PromptMessage> = Vec::new();",
       *built,
       "        Ok(messages)",
       "    }"]
    end

    # The text of a resource, computed on every read. Always a Result so a body that can fail needs no special case.
    def resource_fn(res, ir)
      b = res["body"]
      if res["template"]
        prm = ir["params"].find { |x| x["name"] == res["params"] }
        unpack = b["args"].empty? ? [] : ["        let #{prm['name']} { #{b['args'].join(', ')}#{b['args'].size < prm['fields'].size ? ', ..' : ''} } = params;"]
        return ["    fn resource_#{res['name']}(&self, #{b['args'].empty? ? '_params' : 'params'}: #{prm['name']}) -> Result<String, String> {",
                *unpack,
                *b["locals"].map { |l| "        #{l}" },
                "        Ok(#{b['expr']})",
                "    }"]
      end
      ["    fn resource_#{res['name']}(&self) -> Result<String, String> {",
       *b["locals"].map { |l| "        #{l}" },
       "        Ok(#{b['expr']})",
       "    }"]
    end

    def templates?(ir) = ir["resources"].to_a.any? { |res| res["template"] }

    def template_vars?(ir, &test) = ir["resources"].to_a.any? { |res| res["vars"].to_a.any?(&test) }

    # {x*}: the value is a comma-separated list, each item percent-decoded; the empty string is the empty list.
    PERCENT_LIST = <<~'RS'
      fn percent_list(s: &str) -> Result<Vec<String>, String> {
          if s.is_empty() {
              return Ok(Vec::new());
          }
          s.split(',').map(percent_decode).collect()
      }
    RS

    # {?q,limit}: form-style query variables (RFC 6570). A variable that is not in the query is None; one that
    # appears twice is refused, because which value was meant is a guess. Other parameters are ignored.
    QUERY_PARAM = <<~'RS'
      fn query_param(query: Option<&str>, name: &str) -> Result<Option<String>, String> {
          let mut found: Option<String> = None;
          for pair in query.unwrap_or("").split('&').filter(|p| !p.is_empty()) {
              let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
              if percent_decode(key)? == name {
                  if found.is_some() {
                      return Err("it appears twice in the query".to_string());
                  }
                  found = Some(percent_decode(value)?);
              }
          }
          Ok(found)
      }
    RS

    # A uri placeholder's value arrives percent-encoded (RFC 6570 expands it that way); a bad escape is the
    # caller's mistake and is reported as one.
    PERCENT_DECODE = <<~'RS'
      fn percent_decode(s: &str) -> Result<String, String> {
          let bytes = s.as_bytes();
          let mut out = Vec::with_capacity(bytes.len());
          let mut i = 0;
          while i < bytes.len() {
              if bytes[i] == b'%' {
                  let hex = s.get(i + 1..i + 3).filter(|h| h.bytes().all(|c| c.is_ascii_hexdigit()));
                  match hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                      Some(b) => out.push(b),
                      None => return Err(format!("{:?} is not a valid escape", s.get(i..(i + 3).min(s.len())).unwrap_or("%"))),
                  }
                  i += 3;
              } else {
                  out.push(bytes[i]);
                  i += 1;
              }
          }
          String::from_utf8(out).map_err(|_| "the decoded bytes are not valid UTF-8".to_string())
      }
    RS

    def icon_list(url) = "vec![rmcp::model::Icon::new(#{RmcpDsl.rstr(url)})]"

    # `meta:` is a JSON literal checked by the reader; it becomes the `_meta` object of a tool, prompt or resource.
    def meta_expr(value) = "meta_object(rmcp::serde_json::json!(#{json_rust(value)}))"

    def json_rust(value)
      case value
      when Hash then "{#{value.map { |k, v| "#{RmcpDsl.rstr(k)}: #{json_rust(v)}" }.join(', ')}}"
      when Array then "[#{value.map { |v| json_rust(v) }.join(', ')}]"
      when String then RmcpDsl.rstr(value)
      when nil then "null"
      else value.to_s # true, false, integers and floats read the same in Rust
      end
    end

    def meta?(ir) = (ir["tools"].to_a + ir["prompts"].to_a + ir["resources"].to_a).any? { |x| x["meta"] }

    # MetaObject is a newtype around a JSON object; the reader has already checked that the literal is one.
    META_OBJECT = <<~'RS'
      fn meta_object(value: rmcp::serde_json::Value) -> rmcp::model::MetaObject {
          match value {
              rmcp::serde_json::Value::Object(map) => rmcp::model::MetaObject(map),
              _ => rmcp::model::MetaObject::new(),
          }
      }
    RS

    # Prompt arguments that have `enum:` values: [prompt name, field name, values]. MCP completion applies to
    # prompt arguments and resource templates; a tool's arguments are not completed.
    def completion_fields(ir)
      sources = ir["prompts"].to_a + ir["resources"].to_a.select { |res| res["template"] }
      sources.flat_map { |src| ir["params"].find { |x| x["name"] == src["params"] }["fields"] }
    end

    def completions?(ir) = completion_fields(ir).any? { |f| f["enum"] }

    # The match arms for one argument list: an enum offers its values, any other argument has nothing to offer
    # (empty, as rmcp's default does), and a name the prompt or template does not have is invalid params.
    def completion_arms(ir, params_name, key, what)
      prm = ir["params"].find { |x| x["name"] == params_name }
      fields = prm["fields"].map do |f|
        field = RmcpDsl.rstr(f["name"])
        if f["enum"]
          "                (#{key}, #{field}) => vec![#{f['enum'].map { |v| RmcpDsl.rstr(v) }.join(', ')}],"
        else
          "                (#{key}, #{field}) => return Ok(CompleteResult::default()),"
        end
      end
      [*fields,
       "                (#{key}, other) => return Err(rmcp::ErrorData::invalid_params(format!(\"#{what} `{}` has no argument `{}`\", #{key}, other), None)),"]
    end

    # completion/complete. rmcp's own default answers with an empty CompleteResult, so anything this server has
    # nothing to offer for gets exactly that; an argument with `enum:` values offers the values that start
    # with what has been typed so far.
    def complete_lines(ir)
      prompt_arms = ir["prompts"].to_a.flat_map { |pr| completion_arms(ir, pr["params"], RmcpDsl.rstr(pr["name"]), "prompt") }
      template_arms = ir["resources"].to_a.select { |res| res["template"] }
                                     .flat_map { |res| completion_arms(ir, res["params"], RmcpDsl.rstr(res["uri"]), "resource template") }
      ["    async fn complete(&self, request: CompleteRequestParams, _context: RequestContext<RoleServer>) -> Result<CompleteResult, rmcp::ErrorData> {",
       "        let typed = request.argument.value.as_str();",
       "        let values: Vec<&str> = match &request.r#ref {",
       "            Reference::Prompt(p) => match (p.name.as_str(), request.argument.name.as_str()) {",
       *prompt_arms,
       "                (name, _) => return Err(rmcp::ErrorData::invalid_params(format!(\"unknown prompt `{name}`\"), None)),",
       "            },",
       "            Reference::Resource(t) => match (t.uri.as_str(), request.argument.name.as_str()) {",
       *template_arms,
       "                (uri, _) => return Err(rmcp::ErrorData::invalid_params(format!(\"unknown resource template `{uri}`\"), None)),",
       "            },",
       "            _ => return Ok(CompleteResult::default()),",
       "        };",
       "        // At most 100 values go out; total and hasMore say how many matched (MCP completion).",
       "        let all: Vec<String> = values.into_iter().filter(|v| v.starts_with(typed)).map(String::from).collect();",
       "        let total = all.len();",
       "        let shown: Vec<String> = all.into_iter().take(CompletionInfo::MAX_VALUES).collect();",
       "        match CompletionInfo::with_pagination(shown, Some(total as u32), total > CompletionInfo::MAX_VALUES) {",
       "            Ok(info) => Ok(CompleteResult::new(info)),",
       "            Err(e) => Err(rmcp::ErrorData::internal_error(e, None)),",
       "        }",
       "    }"]
    end

    def tasks?(ir) = ir["tools"].any? { |t| t["task"] }

    # `page_size:` on the server: each list is cut into pages of that many items. The cursor is opaque to clients: here
    # it is `c` and the offset of the page's first item in hex. A cursor that is not one of ours (or points past the
    # end) is invalid params, as the specification says.
    def paged?(ir) = !ir["page_size"].nil?

    def page_fn(ir)
      ["fn page<T>(items: Vec<T>, cursor: Option<&str>) -> Result<(Vec<T>, Option<String>), rmcp::ErrorData> {",
       "    const PAGE_SIZE: usize = #{ir['page_size']};",
       "    let start = match cursor {",
       "        None => 0,",
       "        Some(c) => c",
       "            .strip_prefix('c')",
       "            .and_then(|n| usize::from_str_radix(n, 16).ok())",
       "            .filter(|n| *n <= items.len())",
       "            .ok_or_else(|| rmcp::ErrorData::invalid_params(format!(\"invalid cursor {c:?}\"), None))?,",
       "    };",
       "    let end = (start + PAGE_SIZE).min(items.len());",
       "    let next = (end < items.len()).then(|| format!(\"c{end:x}\"));",
       "    Ok((items.into_iter().skip(start).take(end - start).collect(), next))",
       "}"]
    end

    # list_tools (and list_prompts with get_prompt, which the prompt macro would overwrite) written out with paging.
    def paged_list_lines(ir)
      cache = ["        let supports_cache_hints = context.protocol_version().is_some_and(|version| version >= rmcp::model::ProtocolVersion::V_2026_07_28);"]
      tail = ["            ttl_ms: supports_cache_hints.then_some(0),",
              "            cache_scope: supports_cache_hints.then_some(rmcp::model::CacheScope::Public),"]
      lines = ["    async fn list_tools(&self, request: Option<rmcp::model::PaginatedRequestParams>, context: RequestContext<RoleServer>) -> Result<rmcp::model::ListToolsResult, rmcp::ErrorData> {",
               *cache,
               "        let (tools, next_cursor) = page(Self::tool_router().list_all(), request.and_then(|r| r.cursor).as_deref())?;",
               "        Ok(rmcp::model::ListToolsResult {",
               "            result_type: Some(rmcp::model::ResultType::COMPLETE),",
               "            tools,",
               "            meta: None,",
               "            next_cursor,",
               *tail,
               "        })",
               "    }"]
      return lines if ir["prompts"].to_a.empty?

      [*lines, "",
       "    async fn list_prompts(&self, request: Option<rmcp::model::PaginatedRequestParams>, context: RequestContext<RoleServer>) -> Result<rmcp::model::ListPromptsResult, rmcp::ErrorData> {",
       *cache,
       "        let (prompts, next_cursor) = page(Self::prompt_router().list_all(), request.and_then(|r| r.cursor).as_deref())?;",
       "        Ok(rmcp::model::ListPromptsResult {",
       "            result_type: Some(rmcp::model::ResultType::COMPLETE),",
       "            prompts,",
       "            meta: None,",
       "            next_cursor,",
       *tail,
       "        })",
       "    }",
       "",
       "    async fn get_prompt(&self, request: rmcp::model::GetPromptRequestParams, context: RequestContext<RoleServer>) -> Result<rmcp::model::GetPromptResponse, rmcp::ErrorData> {",
       "        let prompt_context = rmcp::handler::server::prompt::PromptContext::new(self, request.name, request.arguments, context);",
       "        Self::prompt_router().get_prompt(prompt_context).await",
       "    }"]
    end

    # Tools that say which resources they change (`updates:`) or that they add or remove some (`resource_list_changed:`).
    def subscribes?(ir) = ir["tools"].any? { |t| t["updates"] }

    def list_changes?(ir) = ir["tools"].any? { |t| t["list_changed"] }

    def notifies?(ir) = subscribes?(ir) || list_changes?(ir)

    # What the server keeps to tell clients about changes. A client on protocol 2026-07-28 opens a subscriptions/listen
    # stream (STREAMS holds its sink, which only lets through what the client asked for); a client on an earlier version
    # calls resources/subscribe and is told about the uris it subscribed to, and about list changes if it initialized
    # (LEGACY). Both lists are one per process, so a notification reaches every client the server is talking to.
    def notify_runtime(ir)
      lines = [
        "static STREAMS: std::sync::Mutex<Vec<rmcp::service::SubscriptionSink>> = std::sync::Mutex::new(Vec::new());",
        "static LEGACY: std::sync::Mutex<Vec<Legacy>> = std::sync::Mutex::new(Vec::new());",
        "",
        "struct Legacy {",
        "    peer: rmcp::service::Peer<RoleServer>,",
        "    uris: Vec<String>,",
        "}",
        "",
        "fn same_peer(a: &rmcp::service::Peer<RoleServer>, b: &rmcp::service::Peer<RoleServer>) -> bool {",
        "    match (a.peer_info(), b.peer_info()) {",
        "        (Some(x), Some(y)) => std::sync::Arc::ptr_eq(&x, &y),",
        "        _ => false,",
        "    }",
        "}",
        "",
        "fn legacy_entry<'a>(list: &'a mut Vec<Legacy>, peer: &rmcp::service::Peer<RoleServer>) -> &'a mut Legacy {",
        "    let at = match list.iter().position(|l| same_peer(&l.peer, peer)) {",
        "        Some(at) => at,",
        "        None => {",
        "            list.push(Legacy { peer: peer.clone(), uris: Vec::new() });",
        "            list.len() - 1",
        "        }",
        "    };",
        "    &mut list[at]",
        "}",
        "",
        "// Tell every client that asked. Runs apart from the tool call, so a slow client never delays the result.",
        "fn notify_resources(updated: Vec<String>, list_changed: bool) {",
        "    tokio::spawn(async move {",
        "        let streams: Vec<rmcp::service::SubscriptionSink> = STREAMS.lock().unwrap_or_else(|e| e.into_inner()).clone();",
        "        let mut closed = Vec::new();",
        "        for sink in &streams {",
        "            let mut results = Vec::new();",
        "            for uri in &updated {",
        "                results.push(sink.notify_resource_updated(uri.clone()).await);",
        "            }",
        "            if list_changed {",
        "                results.push(sink.notify_resource_list_changed().await);",
        "            }",
        "            if results.iter().any(|r| matches!(r, Err(rmcp::service::SubscriptionSendError::SubscriptionClosed))) {",
        "                closed.push(sink.id().clone());",
        "            }",
        "        }",
        "        if !closed.is_empty() {",
        "            STREAMS.lock().unwrap_or_else(|e| e.into_inner()).retain(|s| !closed.contains(s.id()));",
        "        }",
        "        let legacy: Vec<(rmcp::service::Peer<RoleServer>, Vec<String>)> =",
        "            LEGACY.lock().unwrap_or_else(|e| e.into_inner()).iter().map(|l| (l.peer.clone(), l.uris.clone())).collect();",
        "        for (peer, uris) in &legacy {",
        "            if list_changed {",
        "                let _ = peer.notify_resource_list_changed().await;",
        "            }",
        "            for uri in updated.iter().filter(|u| uris.contains(u)) {",
        "                let _ = peer.notify_resource_updated(rmcp::model::ResourceUpdatedNotificationParam::new(uri.clone())).await;",
        "            }",
        "        }",
        "        LEGACY.lock().unwrap_or_else(|e| e.into_inner()).retain(|l| !l.peer.is_transport_closed());",
        "    });",
        "}"
      ]
      if ir["tools"].any? { |t| (t["updates"] || []).any? { |parts| parts.any? { |kind, _| kind == "var" } } }
        lines.concat(["",
                      "// A value in a uri: everything but unreserved characters is percent-encoded ({+x} also keeps reserved ones).",
                      "fn uri_part(value: &str, keep_reserved: bool) -> String {",
                      "    let mut out = String::new();",
                      "    for b in value.bytes() {",
                      "        if b.is_ascii_alphanumeric() || b\"-._~\".contains(&b) || (keep_reserved && b\":/?#[]@!$&'()*+,;=\".contains(&b)) {",
                      "            out.push(b as char);",
                      "        } else {",
                      "            out.push_str(&format!(\"%{:02X}\", b));",
                      "        }",
                      "    }",
                      "    out",
                      "}"])
      end
      lines
    end

    # Is this uri one the server serves? Used to refuse subscribing to a resource that does not exist.
    def known_resource_fn(ir)
      statics = ir["resources"].reject { |r| r["template"] }.map { |r| RmcpDsl.rstr(r["uri"]) }
      templates = ir["resources"].select { |r| r["template"] }.map { |r| "#{r['regex_id']}.is_match(uri)" }
      checks = [(statics.empty? ? nil : "matches!(uri, #{statics.join(' | ')})"), *templates].compact
      ["    fn known_resource(uri: &str) -> bool {", "        #{checks.empty? ? 'false' : checks.join(' || ')}", "    }"]
    end

    # The handler methods: the 2026-07-28 subscriptions/listen stream, the earlier resources/subscribe and unsubscribe,
    # and on_initialized to remember who can be told about list changes.
    def notify_lines(ir)
      accepted = []
      accepted << "        accepted.resources_list_changed = requested.resources_list_changed;" if list_changes?(ir)
      if subscribes?(ir)
        accepted << "        accepted.resource_subscriptions = requested.resource_subscriptions.as_ref().map(|uris| uris.iter().filter(|u| known_resource(u)).cloned().collect());"
      end
      known = ["        fn known_resource(uri: &str) -> bool {", *known_resource_fn(ir)[1..-2].map { |l| "    #{l}" }, "        }"]
      lines = [
        "    fn accepted_subscription_filter(&self, requested: &rmcp::model::SubscriptionFilter) -> Option<rmcp::model::SubscriptionFilter> {",
        *(subscribes?(ir) ? known : []),
        "        let mut accepted = rmcp::model::SubscriptionFilter::new();",
        *accepted,
        "        Some(accepted)",
        "    }",
        "",
        "    async fn listen(&self, context: rmcp::service::SubscriptionContext) -> Result<(), rmcp::ErrorData> {",
        "        STREAMS.lock().unwrap_or_else(|e| e.into_inner()).push(context.sink().clone());",
        "        context.cancelled().await;",
        "        Ok(())",
        "    }",
        "",
        "    async fn on_initialized(&self, context: rmcp::service::NotificationContext<RoleServer>) {",
        "        legacy_entry(&mut LEGACY.lock().unwrap_or_else(|e| e.into_inner()), &context.peer);",
        "    }"
      ]
      return lines unless subscribes?(ir)

      [*lines, "",
       "    #[allow(deprecated)]",
       "    async fn subscribe(&self, request: rmcp::model::SubscribeRequestParams, context: RequestContext<RoleServer>) -> Result<(), rmcp::ErrorData> {",
       *known,
       "        if !known_resource(&request.uri) {",
       "            return Err(rmcp::ErrorData::resource_not_found(format!(\"unknown resource {}\", request.uri), Some(rmcp::serde_json::json!({ \"uri\": request.uri }))));",
       "        }",
       "        let mut legacy = LEGACY.lock().unwrap_or_else(|e| e.into_inner());",
       "        let entry = legacy_entry(&mut legacy, &context.peer);",
       "        if !entry.uris.contains(&request.uri) {",
       "            entry.uris.push(request.uri);",
       "        }",
       "        Ok(())",
       "    }",
       "",
       "    #[allow(deprecated)]",
       "    async fn unsubscribe(&self, request: rmcp::model::UnsubscribeRequestParams, context: RequestContext<RoleServer>) -> Result<(), rmcp::ErrorData> {",
       "        let mut legacy = LEGACY.lock().unwrap_or_else(|e| e.into_inner());",
       "        legacy_entry(&mut legacy, &context.peer).uris.retain(|u| u != &request.uri);",
       "        Ok(())",
       "    }"]
    end

    # The notification a tool sends once it has succeeded, as the Rust that builds the list of uris.
    def notify_call(tool)
      uris = (tool["updates"] || []).map do |parts|
        if parts.all? { |kind, _| kind == "lit" }
          "#{RmcpDsl.rstr(parts.map(&:last).join)}.to_string()"
        else
          fmt = parts.map { |kind, text| kind == "lit" ? text.gsub("{", "{{").gsub("}", "}}") : "{}" }.join
          vars = parts.select { |kind, _| kind == "var" }.map { |_, name, plus| "uri_part(&#{name}, #{plus})" }
          "format!(#{RmcpDsl.rstr(fmt)}, #{vars.join(', ')})"
        end
      end
      "notify_resources(vec![#{uris.join(', ')}], #{tool['list_changed'] ? 'true' : 'false'});"
    end

    # A tool is successful when its result is not an error: the plain string always is, a CallToolResult unless it says
    # isError, and a structured result when it is the Ok side.
    def with_notification(tool, ret, lines)
      ["let __result = {", *lines.map { |l| "    #{l}" }, "};",
       *(case ret
         when "String" then [notify_call(tool)]
         when /\AResult<Json/ then ["if __result.is_ok() {", "    #{notify_call(tool)}", "}"]
         else ["if matches!(&__result, Ok(r) if r.is_error != Some(true)) {", "    #{notify_call(tool)}", "}"]
         end),
       "__result"]
    end

    # The tasks extension (io.modelcontextprotocol/tasks, SEP-2663), as rmcp's own task test writes it. A tool
    # declared with `task: true` runs inside a task when the client declared the extension; the client gets a handle
    # (`resultType: "task"`) and polls tasks/get, and the body is the same one a plain call runs. Everything else goes
    # to the router as usual. The task is created before the response is sent (TaskManager::spawn), and errors in
    # the arguments surface as the task's own result, as they would from the router. A body cannot be interrupted:
    # cancelling is acknowledged, and a task whose body is already running still finishes (the extension allows it).
    def task_lines(ir)
      arms = ir["tools"].select { |t| t["task"] }.map do |t|
        opts = +"TaskOptions::new()"
        opts << ".with_ttl_ms(#{t['task']['ttl_ms']}u64)" if t["task"]["ttl_ms"]
        opts << ".with_poll_interval_ms(#{t['task']['poll_ms']}u64)" if t["task"]["poll_ms"]
        "            #{RmcpDsl.rstr(t['name'])} => Some(#{opts}),"
      end
      ["    async fn call_tool(&self, request: rmcp::model::CallToolRequestParams, context: RequestContext<RoleServer>) -> Result<rmcp::model::CallToolResponse, rmcp::ErrorData> {",
       "        let options = match request.name.as_ref() {",
       *arms,
       "            _ => None,",
       "        };",
       "        if let Some(options) = options {",
       "            if context.client_capabilities().is_some_and(|caps| caps.supports_tasks()) {",
       "                let this = self.clone();",
       "                let task = TASKS.spawn(options, move |_task| {",
       "                    Box::pin(async move {",
       "                        let call = rmcp::handler::server::tool::ToolCallContext::new(&this, request, context);",
       "                        match Self::tool_router().call(call).await {",
       "                            Ok(rmcp::model::CallToolResponse::Complete(result)) => Ok(result),",
       "                            Ok(_) => Err(TaskExit::Error(rmcp::ErrorData::internal_error(\"a task body cannot ask for more input\", None))),",
       "                            Err(e) => Err(TaskExit::Error(e)),",
       "                        }",
       "                    })",
       "                });",
       "                return Ok(rmcp::model::CallToolResponse::Task(rmcp::model::CreateTaskResult::new(task)));",
       "            }",
       "        }",
       "        let call = rmcp::handler::server::tool::ToolCallContext::new(self, request, context);",
       "        Self::tool_router().call(call).await",
       "    }",
       "",
       "    async fn get_task(&self, request: rmcp::model::GetTaskParams, _context: RequestContext<RoleServer>) -> Result<rmcp::model::GetTaskResult, rmcp::ErrorData> {",
       "        Ok(rmcp::model::GetTaskResult::new(TASKS.get_task(&request.task_id)?))",
       "    }",
       "",
       "    async fn update_task(&self, request: rmcp::model::UpdateTaskParams, _context: RequestContext<RoleServer>) -> Result<(), rmcp::ErrorData> {",
       "        TASKS.update_task(&request.task_id, request.input_responses)",
       "    }",
       "",
       "    async fn cancel_task(&self, request: rmcp::model::CancelTaskParams, _context: RequestContext<RoleServer>) -> Result<(), rmcp::ErrorData> {",
       "        TASKS.cancel_task(&request.task_id)",
       "    }"]
    end

    # get_info written out: the macro cannot enable resources or set the title, description, website and icon.
    def get_info_lines(ir, prompts)
      resources = !ir["resources"].to_a.empty?
      caps = [".enable_tools()", (".enable_prompts()" unless prompts.empty?), (".enable_resources()" if resources),
              (".enable_resources_subscribe()" if subscribes?(ir)), (".enable_resources_list_changed()" if list_changes?(ir)),
              (".enable_completions()" if completions?(ir)), (".enable_tasks()" if tasks?(ir))].compact.join
      instructions = ir["instructions"] ? ".with_instructions(#{RmcpDsl.rstr(ir['instructions'])}.to_string())" : ""
      impl = "rmcp::model::Implementation::new(#{RmcpDsl.rstr(ir['name'])}, #{RmcpDsl.rstr(ir['version'])})"
      impl += ".with_title(#{RmcpDsl.rstr(ir['title'])})" if ir["title"]
      impl += ".with_description(#{RmcpDsl.rstr(ir['description'])})" if ir["description"]
      impl += ".with_website_url(#{RmcpDsl.rstr(ir['website_url'])})" if ir["website_url"]
      impl += ".with_icons(#{icon_list(ir['icon'])})" if ir["icon"]
      ["    fn get_info(&self) -> rmcp::model::ServerConfig {",
       "        rmcp::model::ServerConfig::new(rmcp::model::ServerCapabilities::builder()#{caps}.build())",
       "            .with_server_info(#{impl})#{instructions}",
       "    }"]
    end

    # get_info, list_resources and read_resource.
    # Title, description, MIME type, icon and annotations: the same chain on a Resource and a ResourceTemplate.
    def resource_attrs(res)
      value = +""
      value << ".with_title(#{RmcpDsl.rstr(res['title'])})" if res["title"]
      value << ".with_description(#{RmcpDsl.rstr(res['description'])})" if res["description"]
      value << ".with_mime_type(#{RmcpDsl.rstr(res['mime_type'])})" if res["mime_type"]
      value << ".with_icons(#{icon_list(res['icon'])})" if res["icon"]
      value << ".with_meta(#{meta_expr(res['meta'])})" if res["meta"]
      value << ".with_size(#{res['size']}u64)" if res["size"]
      if res["audience"] || res["priority"]
        ann = "rmcp::model::Annotations::default()"
        ann += ".with_audience(vec![#{res['audience'].map { |a| "rmcp::model::Role::#{a.capitalize}" }.join(', ')}])" if res["audience"]
        ann += ".with_priority(#{res['priority'].to_f})" if res["priority"]
        value << ".with_annotations(#{ann})"
      end
      value
    end

    # A uri matching a template: the placeholder values are percent-decoded, checked against the params'
    # constraints (a violation is invalid params), and handed to the body. A body that raises means the resource
    # does not exist, which rmcp reports as not found (-32002, or -32602 for peers on protocol 2026-07-28).
    def template_read(res, ir)
      prm = ir["params"].find { |x| x["name"] == res["params"] }
      mime = res["mime_type"] ? ".with_mime_type(#{RmcpDsl.rstr(res['mime_type'])})" : ""
      fields = res["vars"].map do |v|
        name = v["name"]
        value =
          if v["op"] == "?" then "query_param(caps.get(#{v['group']}).map(|m| m.as_str()), #{RmcpDsl.rstr(name)})"
          elsif v["explode"] then "percent_list(&caps[#{v['group']}])"
          else "percent_decode(&caps[#{v['group']}])"
          end
        what = v["op"] == "?" ? "invalid query parameter `#{name}`" : "invalid percent-encoding in `{{#{name}#{'*' if v['explode']}}}`"
        "                #{name}: #{value}.map_err(|e| rmcp::ErrorData::invalid_params(format!(\"#{what}: {}\", e), None))?,"
      end
      check = checked?(prm, ir) ? ["            if let Err(e) = params.check() {", "                return Err(rmcp::ErrorData::invalid_params(e, None));", "            }"] : []
      ["        if let Some(caps) = #{res['regex_id']}.captures(request.uri.as_str()) {",
       "            let params = #{prm['name']} {",
       *fields,
       "            };",
       *check,
       "            return match self.resource_#{res['name']}(params) {",
       "                Ok(text) => Ok(ReadResourceResult::new(vec![ResourceContents::text(text, request.uri.clone())#{mime}]).into()),",
       "                Err(e) => Err(rmcp::ErrorData::resource_not_found(e, Some(rmcp::serde_json::json!({ \"uri\": request.uri })))),",
       "            };",
       "        }"]
    end

    def resource_handler(ir, prompts)
      statics = ir["resources"].reject { |res| res["template"] }
      templates = ir["resources"].select { |res| res["template"] }
      listed = statics.map do |res|
        "            Resource::new(#{RmcpDsl.rstr(res['uri'])}, #{RmcpDsl.rstr(res['name'])})#{resource_attrs(res)},"
      end
      paged = paged?(ir)
      cursor = "request.and_then(|r| r.cursor).as_deref()"
      template_items = templates.map { |res| "                ResourceTemplate::new(#{RmcpDsl.rstr(res['uri'])}, #{RmcpDsl.rstr(res['name'])})#{resource_attrs(res)}," }
      template_list = templates.empty? ? [] : [
        "",
        "    async fn list_resource_templates(&self, #{paged ? '' : '_'}request: Option<PaginatedRequestParams>, _context: RequestContext<RoleServer>) -> Result<ListResourceTemplatesResult, rmcp::ErrorData> {",
        *(paged ? ["        let (resource_templates, next_cursor) = page(vec![", *template_items, "        ], #{cursor})?;",
                   "        Ok(ListResourceTemplatesResult { resource_templates, next_cursor, ..Default::default() })"] :
                  ["        Ok(ListResourceTemplatesResult {", "            resource_templates: vec![", *template_items, "            ],", "            ..Default::default()", "        })"]),
        "    }"
      ]
      list_resources = [
        "    async fn list_resources(&self, #{paged ? '' : '_'}request: Option<PaginatedRequestParams>, _context: RequestContext<RoleServer>) -> Result<ListResourcesResult, rmcp::ErrorData> {",
        *(paged ? ["        let (resources, next_cursor) = page(vec![", *listed.map { |l| "    #{l}" }, "        ], #{cursor})?;",
                   "        Ok(ListResourcesResult { resources, next_cursor, ..Default::default() })"] :
                  ["        Ok(ListResourcesResult {", "            resources: vec![", *listed.map { |l| "    #{l}" }, "            ],", "            ..Default::default()", "        })"]),
        "    }"
      ]
      arms = statics.flat_map do |res|
        mime = res["mime_type"] ? ".with_mime_type(#{RmcpDsl.rstr(res['mime_type'])})" : ""
        ["            #{RmcpDsl.rstr(res['uri'])} => match self.resource_#{res['name']}() {",
         "                Ok(text) => Ok(ReadResourceResult::new(vec![ResourceContents::text(text, request.uri.clone())#{mime}]).into()),",
         "                Err(e) => Err(rmcp::ErrorData::internal_error(e, None)),",
         "            },"]
      end
      [*get_info_lines(ir, prompts),
       "",
       *list_resources,
       *template_list,
       "",
       "    async fn read_resource(&self, request: ReadResourceRequestParams, _context: RequestContext<RoleServer>) -> Result<ReadResourceResponse, rmcp::ErrorData> {",
       *templates.flat_map { |res| template_read(res, ir) },
       "        match request.uri.as_str() {",
       *arms,
       "            _ => Err(rmcp::ErrorData::resource_not_found(format!(\"unknown resource {}\", request.uri), Some(rmcp::serde_json::json!({ \"uri\": request.uri })))),",
       "        }",
       "    }"]
    end

    def tool_fn(tool, ir)
      b = tool["body"]
      prm = ir["params"].find { |x| x["name"] == tool["params"] }
      checked = checked?(prm, ir)
      out = tool["output"]
      blocks = b["type"] == "blocks"
      ret = if out then "Result<Json<#{out}>, CallToolResult>"
            elsif b["fallible"] || checked || blocks then "Result<CallToolResult, rmcp::ErrorData>"
            else "String"
            end
      # the fields the body reads, and those a uri in `updates:` is filled from
      args = (b["args"] + (tool["updates"] || []).flat_map { |parts| parts.select { |k, _| k == "var" }.map { |_, n, _| n } }).uniq
      pat =
        if args.empty? then "_"
        else "#{prm['name']} { #{args.join(', ')}#{args.size < prm['fields'].size ? ', ..' : ''} }"
        end
      head =
        if checked
          ["    fn #{tool['name']}(&self, Parameters(params): Parameters<#{prm['name']}>) -> #{ret} {",
           "        if let Err(e) = params.check() {",
           "            return #{out ? "Err" : "Ok"}(CallToolResult::error(vec![ContentBlock::text(e)]));",
           "        }",
           *(args.empty? ? [] : ["        let #{pat} = params;"])]
        else
          ["    fn #{tool['name']}(&self, Parameters(#{pat}): Parameters<#{prm['name']}>) -> #{ret} {"]
        end
      lines = out ? output_lines(b, out) : body_lines(b, mcp: true, force: checked || blocks)
      lines = with_notification(tool, ret, lines) if tool["updates"] || tool["list_changed"]
      [tool_attr(tool), *head, *lines.map { |l| "        #{l}" }, "    }"]
    end

    # Compiles every regex under `cargo test`, so a pattern Rust rejects fails a test
    # instead of panicking the first time a tool runs.
    # One wrapper per cmd_fn/script_fn: fixed argv prefix, then the call arguments.
    def subproc_fn(sp)
      params = sp["args"].each_with_index.map { |t, i| "a#{i}: #{t == 'string' ? '&str' : TYPES.fetch(t.to_sym)}" }
      prefix = sp["argv"].map { |s| "#{RmcpDsl.rstr(s)}.to_string()" }
      stdin = sp["pass"] == "stdin"
      mut = !stdin && !sp["args"].empty? ? "mut " : ""
      lines = ["fn #{sp['name']}(#{params.join(', ')}) -> String {",
               "    let #{mut}argv: Vec<String> = vec![#{prefix.join(', ')}];"]
      if stdin
        lines << "    run_subprocess(#{RmcpDsl.rstr(sp['program'])}, &argv, Some(a0))"
      else
        sp["args"].each_index { |i| lines << "    argv.push(a#{i}.to_string());" }
        lines << "    run_subprocess(#{RmcpDsl.rstr(sp['program'])}, &argv, None)"
      end
      lines << "}"
    end

    def regex_test(regexes)
      return [] if regexes.empty?

      [
        "",
        "#[cfg(test)]",
        "mod tests {",
        "    use super::*;",
        "",
        "    #[test]",
        "    fn regexes_compile() {",
        *regexes.map { |r| "        LazyLock::force(&#{r['id']});" },
        "    }",
        "}"
      ]
    end

    # The streamable HTTP server is wired the way rmcp's own tests do it: a StreamableHttpService with the
    # default session manager and the default config, mounted at /mcp, served by axum on 127.0.0.1.
    def main_fn(ir, srv)
      if http?(ir)
        return [
          "#[tokio::main]",
          "async fn main() -> anyhow::Result<()> {",
          "    let service: rmcp::transport::streamable_http_server::StreamableHttpService<#{srv}, rmcp::transport::streamable_http_server::session::local::LocalSessionManager> =",
          "        rmcp::transport::streamable_http_server::StreamableHttpService::new(",
          "            || Ok(#{srv}),",
          "            Default::default(),",
          "            rmcp::transport::streamable_http_server::StreamableHttpServerConfig::default(),",
          "        );",
          "    let router = axum::Router::new().nest_service(\"/mcp\", service);",
          "    let listener = tokio::net::TcpListener::bind(\"127.0.0.1:#{ir['port']}\").await?;",
          "    axum::serve(listener, router).await?;",
          "    Ok(())",
          "}"
        ]
      end
      [
        "#[tokio::main]",
        "async fn main() -> anyhow::Result<()> {",
        "    let service = #{srv}.serve(rmcp::transport::stdio()).await?;",
        "    service.waiting().await?;",
        "    Ok(())",
        "}"
      ]
    end
  end
end
