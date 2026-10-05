# frozen_string_literal: true

module RmcpDsl
  # Types made of other types: typed maps (a Ruby Hash with String keys and one value type, T::Hash[String, V]) and the
  # nil-able form of any type that has no fixed symbol of its own. Internally a map is the symbol :"map<V>" and a
  # nil-able map :"opt<map<V>>", where V is the internal symbol of one of VALUES. A field declares a map as `map(:i64)`
  # or `map(list(:string))`; its canonical text in the IR is "map(i64)" or "map(string_list)".
  #
  # A map is a Rust BTreeMap, as serde_json's own objects are: keys come back sorted, not in insertion order.
  module CompositeTypes
    # canonical value name => [internal symbol, Rust type, display name]
    VALUES = {
      "string" => [:string, "String", "String"],
      "i64" => [:i64, "i64", "Integer (i64)"],
      "f64" => [:f64, "f64", "Float"],
      "bool" => [:bool, "bool", "T::Boolean"],
      "string_list" => [:strs, "Vec<String>", "T::Array[String]"],
      "i64_list" => [:i64s, "Vec<i64>", "T::Array[Integer (i64)]"]
    }.freeze
    BY_SYMBOL = VALUES.to_h { |name, (sym, rust, shown)| [sym, [name, rust, shown]] }.freeze
    MAP_FIELD = /\Amap\((\w+)\)\z/
    OPAQUE_FIELD = /\A[A-Z]\w*::[A-Z]\w*\z/ # a field typed with a type a binding owns: "Json::Value"

    # :"map<string>" -> :string; nil for anything that is not the symbol of a map
    def self.map_value(sym)
      m = sym.to_s.match(/\Amap<(\w+)>\z/) or return nil
      value = m[1].to_sym
      BY_SYMBOL.key?(value) ? value : nil
    end

    def self.map_symbol(value_sym) = :"map<#{value_sym}>"

    # The Rust type of a map with that value symbol.
    def self.map_rust(value_sym) = "std::collections::BTreeMap<String, #{BY_SYMBOL.fetch(value_sym)[1]}>"

    # "map(i64)" -> the map's internal symbol; nil when the text is not a map field type
    def self.field_symbol(type)
      m = type.to_s.match(MAP_FIELD) or return nil
      entry = VALUES[m[1]] or return nil
      map_symbol(entry[0])
    end

    # The types a binding owns (`class Value < RmcpDsl::Opaque` in a bindings/*.rb file). Internally a value of one is
    # the symbol :"ext<Json::Value>" and a nil-able one :"opt<ext<Json::Value>>"; the compiler knows only the name, the
    # Rust type behind it and whether it may cross the wire (be a tool field or part of a result). The registry is
    # filled when a file is read (Reader) and when the IR is turned into Rust (Emit), because Emit holds no state.
    module Opaque
      Entry = Struct.new(:name, :rust, :wire, keyword_init: true)
      EXT = /\Aext<([A-Z]\w*::[A-Z]\w*)>\z/

      @types = {}

      class << self
        def reset(entries = [])
          @types = entries.to_h { |e| [e["name"], Entry.new(name: e["name"], rust: e["rust"], wire: e["wire"])] }
        end

        def register(name, rust, wire) = @types[name] = Entry.new(name: name, rust: rust, wire: wire)

        def symbol(name) = :"ext<#{name}>"

        # :"ext<Json::Value>" -> "Json::Value"; nil for any other symbol
        def name_of(sym) = sym.to_s.match(EXT)&.[](1)

        def symbol?(sym) = !name_of(sym).nil?

        def entry(name) = @types[name]

        # "Json::Value" -> the Rust type, or raises when nothing declared that name
        def rust(name) = (@types[name] or raise(KeyError, "no opaque type #{name}")).rust

        # A field type's text ("Json::Value") -> its symbol; nil when the text is not shaped like a qualified name.
        def field_symbol(text) = text.to_s.match?(/\A[A-Z]\w*::[A-Z]\w*\z/) ? symbol(text) : nil

        def types = @types.values
      end
    end

    # Looks like the Hash it replaces (key?, [], fetch) for the nil-able types: fixed symbols for the old ones
    # (:ostr ...), :"opt<map<V>>" for a nil-able map and :"opt<ext<Name>>" for a nil-able opaque type.
    class OptTable
      def initialize(fixed) = @fixed = fixed

      def key?(sym) = @fixed.key?(sym) || !inside(sym).nil?

      def [](sym) = @fixed[sym] || inside(sym)

      def fetch(sym) = self[sym] || raise(KeyError, "key not found: #{sym.inspect}")

      private

      def inside(sym)
        m = sym.to_s.match(/\Aopt<(map<\w+>|ext<[\w:]+>)>\z/) or return nil
        inner = m[1].to_sym
        CompositeTypes.map_value(inner) || Opaque.symbol?(inner) ? inner : nil
      end
    end

    # The way back: the nil-able type of a type, for an optional field.
    class OptOfTable
      def initialize(fixed) = @fixed = fixed

      def key?(sym) = @fixed.key?(sym) || nested?(sym)

      def [](sym) = @fixed[sym] || (nested?(sym) ? :"opt<#{sym}>" : nil)

      def fetch(sym) = self[sym] || raise(KeyError, "key not found: #{sym.inspect}")

      private

      def nested?(sym) = !CompositeTypes.map_value(sym).nil? || Opaque.symbol?(sym)
    end

    # The map types: key?(sym) says whether a symbol is a map, fetch(sym) gives the value symbol.
    class MapTable
      def key?(sym) = !CompositeTypes.map_value(sym).nil?

      def [](sym) = CompositeTypes.map_value(sym)

      def fetch(sym) = self[sym] || raise(KeyError, "key not found: #{sym.inspect}")
    end
  end
end
