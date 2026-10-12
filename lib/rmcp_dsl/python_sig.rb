# frozen_string_literal: true

module RmcpDsl
  # Reads what a `file ... entries:` declaration depends on in a Python file: each top-level
  # `def NAME(...) -> T:` header and each `class Name(TypedDict):` body. It is a line scan of a fixed
  # subset, not a Python parser, so it needs no python3 at build time; what it cannot read it reports
  # as Unreadable rather than guessing. docs/specs/source_hook.md is the contract.
  module PythonSig
    class Unreadable < StandardError; end

    # base is :string, :int, :f64, :bool, :strs, :i64s or :f64s; nilable means the annotation allows None.
    Type = Struct.new(:base, :nilable, :text, keyword_init: true)
    Param = Struct.new(:name, :annotation, :default, keyword_init: true)
    Def = Struct.new(:name, :params, :returns, :line, :header, keyword_init: true)
    # source is the field line with its comment dropped and whitespace collapsed, what the server compares at run time.
    Field = Struct.new(:name, :type, :required, :line, :source, keyword_init: true)

    SCALARS = { "str" => :string, "int" => :int, "float" => :f64, "bool" => :bool }.freeze
    LISTS = { "str" => :strs, "int" => :i64s, "float" => :f64s }.freeze
    CHECKABLE = "use str, int, float, bool, list[str], list[int], list[float], or one of those | None"

    module_function

    # The top-level `def NAME(` header, joined onto one line, with the line it starts on; nil when absent.
    def find_def(text, name)
      lines = text.lines
      lines.each_with_index do |line, i|
        next unless line.match?(/\A(?:async\s+)?def\s+#{Regexp.escape(name)}\s*\(/)

        header = +""
        depth = 0
        opened = false
        lines[i..].each do |l|
          code = strip_comment(l)
          header << " " unless header.empty?
          header << code.strip
          code.each_char do |c|
            if "([{".include?(c)
              depth += 1
              opened = true
            elsif ")]}".include?(c)
              depth -= 1
            end
          end
          return [header, i + 1] if opened && depth.zero? && code.rstrip.end_with?(":")
        end
        raise Unreadable, "the header of `def #{name}` (line #{i + 1}) never closes with `):`"
      end
      nil
    end

    # The parsed signature of `def NAME`. Every parameter and the return must be annotated.
    def signature(text, name)
      found = find_def(text, name) or return nil
      header, line = found
      open = header.index("(")
      close = matching(header, open) or raise Unreadable, "cannot read the parameters of `def #{name}` (line #{line})"
      rest = header[(close + 1)..].strip
      ret = rest.match(/\A->\s*(.+?)\s*:\z/)&.[](1)
      params = split_top(header[(open + 1)...close]).map(&:strip).reject(&:empty?).map do |part|
        if part.start_with?("*") || part == "/"
          raise Unreadable, "`def #{name}` (line #{line}) uses `#{part}`; an entry takes named parameters only"
        end
        nm, ann, default = split_param(part)
        Param.new(name: nm, annotation: ann, default: default)
      end
      Def.new(name: name, params: params, returns: ret, line: line, header: header.gsub(/\s+/, " ").strip)
    end

    # The `name: annotation` fields of `class NAME(TypedDict):`, or nil when the file has no such class.
    def typed_dict(text, name)
      lines = text.lines
      start = lines.index { |l| l.match?(/\Aclass\s+#{Regexp.escape(name)}\s*\(/) } or return nil
      head = strip_comment(lines[start]).strip
      unless head.match?(/\Aclass\s+#{Regexp.escape(name)}\s*\(\s*TypedDict\s*\)\s*:\z/)
        raise Unreadable, "`#{head}` (line #{start + 1}) is not a plain `class #{name}(TypedDict):`; total=False and base classes cannot be checked"
      end
      fields = []
      in_doc = nil
      lines[(start + 1)..].each_with_index do |raw, j|
        lineno = start + j + 2
        if in_doc
          in_doc = nil if raw.include?(in_doc)
          next
        end
        code = strip_comment(raw)
        break if !code.strip.empty? && !code.start_with?(" ", "\t")

        s = code.strip
        next if s.empty? || s == "pass"

        quote = s[0, 3]
        if ['"""', "'''"].include?(quote)
          in_doc = quote unless s.length > 3 && s[3..].include?(quote)
          next
        end
        m = s.match(/\A([A-Za-z_]\w*)\s*:\s*(.+)\z/) or
          raise Unreadable, "cannot read line #{lineno} of TypedDict #{name}: `#{s}`; a field is `name: type`"
        type, required = field_type(m[2], "#{name}.#{m[1]}")
        fields << Field.new(name: m[1], type: type, required: required, line: lineno, source: s.gsub(/\s+/, " "))
      end
      fields
    end

    # A TypedDict field's annotation: NotRequired[...] / Required[...] decide whether the key must be sent.
    def field_type(text, where)
      t = text.strip
      if (m = t.match(/\A(NotRequired|Required)\[(.*)\]\z/))
        return [parse_type(m[2], where), m[1] == "Required"]
      end

      [parse_type(t, where), true]
    end

    # One annotation in the checkable subset.
    def parse_type(text, where)
      t = text.strip
      parts = split_top(t, "|").map(&:strip)
      nilable = parts.delete("None") ? true : false
      if parts.size == 1 && (m = parts[0].match(/\AOptional\[(.*)\]\z/))
        parts = [m[1].strip]
        nilable = true
      end
      raise Unreadable, "#{where}: `#{t}` cannot be checked; #{CHECKABLE}" unless parts.size == 1

      one = parts[0]
      base = SCALARS[one]
      if base.nil? && (m = one.match(/\A[Ll]ist\[\s*(\w+)\s*\]\z/))
        base = LISTS[m[1]]
      end
      raise Unreadable, "#{where}: `#{t}` cannot be checked; #{CHECKABLE}" unless base

      Type.new(base: base, nilable: nilable, text: t)
    end

    def strip_comment(line)
      quote = nil
      line.each_char.with_index do |c, i|
        if quote
          quote = nil if c == quote
        elsif c == '"' || c == "'"
          quote = c
        elsif c == "#"
          return line[0...i]
        end
      end
      line.chomp
    end

    # The index of the bracket that closes the one at `open`, outside string literals.
    def matching(s, open)
      depth = 0
      quote = nil
      (open...s.length).each do |i|
        c = s[i]
        if quote
          quote = nil if c == quote
        elsif c == '"' || c == "'"
          quote = c
        elsif "([{".include?(c)
          depth += 1
        elsif ")]}".include?(c)
          depth -= 1
          return i if depth.zero?
        end
      end
      nil
    end

    # Splits on `sep` where no bracket or string is open.
    def split_top(s, sep = ",")
      out = []
      cur = +""
      depth = 0
      quote = nil
      s.each_char do |c|
        if quote
          quote = nil if c == quote
        elsif c == '"' || c == "'"
          quote = c
        elsif "([{".include?(c)
          depth += 1
        elsif ")]}".include?(c)
          depth -= 1
        elsif c == sep && depth.zero?
          out << cur
          cur = +""
          next
        end
        cur << c
      end
      out << cur
    end

    # `name: annotation = default` into its three parts; the annotation is nil when it is missing.
    def split_param(part)
      eq = split_top(part, "=")
      head = eq[0].strip
      default = eq.size > 1 ? eq[1..].join("=").strip : nil
      colon = split_top(head, ":")
      name = colon[0].strip
      ann = colon.size > 1 ? colon[1..].join(":").strip : nil
      [name, ann, default]
    end
  end
end
