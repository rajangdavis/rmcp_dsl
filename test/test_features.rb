# frozen_string_literal: true

# The backend capability map (RmcpDsl::Features::TABLE) must match the vendored rmcp source it claims to
# describe: for every feature, the witness item is marked #[deprecated] exactly when the map says it is, the
# SEP in the note matches, and the map's `reference` names something that is really in that file. This keeps
# the compiler's mirror of the pinned SDK honest, so a future rmcp that deprecates or removes a feature is
# caught here instead of silently changing the DSL.
#
#   ruby -Ilib test/test_features.rb
require "minitest/autorun"
require "rmcp_dsl"

class TestFeatures < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SRC = File.join(ROOT, "vendor", "rmcp-#{RmcpDsl::RMCP_VERSION}", "src")

  # feature => [file under src/, regex matching the declaration line, the SEP the map should record]
  WITNESS = {
    logging: ["model.rs", /^pub enum LoggingLevel\b/, "SEP-2577"],
    sampling: ["model.rs", /^pub type CreateMessageRequest\b/, "SEP-2577"],
    roots: ["model.rs", /^pub type ListRootsRequest\b/, "SEP-2577"],
    elicitation: ["service/server.rs", /peer_req create_elicitation /, nil],
    progress: ["service/server.rs", /notify_progress ProgressNotification/, nil]
  }.freeze

  def vendor_dir = SRC

  def test_every_feature_has_a_witness_and_no_extras
    assert_equal RmcpDsl::Features.names.sort, WITNESS.keys.sort,
                 "every feature in Features::TABLE needs a witness here (and WITNESS must not name extras)"
  end

  def test_the_signature_table_gates_exactly_the_mapped_features
    assert_equal RmcpDsl::Features.names.sort, RmcpDsl::SIG[:feature][:pos][0].sort,
                 "SIG[:feature] must accept exactly Features::NAMES"
  end

  def test_the_map_matches_the_vendored_deprecation_attributes
    skip "vendor/ is not part of the gem" unless Dir.exist?(vendor_dir)

    RmcpDsl::Features.names.each do |name|
      entry = RmcpDsl::Features.get(name)
      file, decl, sep = WITNESS.fetch(name)
      source = File.read(File.join(vendor_dir, file))
      lines = source.lines
      idx = lines.index { |l| l.match?(decl) }
      refute_nil idx, "#{file} has no line matching #{decl.inspect}; the map for :#{name} is stale"

      note = deprecation_note(lines, idx)
      if (recorded = entry[:deprecated])
        refute_nil note, "Features::TABLE says :#{name} is deprecated by #{recorded}, but #{file} does not mark the witness #[deprecated]"
        assert_includes note, recorded, ":#{name} should name #{recorded}, but the vendored note says #{note.inspect}"
        assert_equal recorded, sep, "the witness for :#{name} expects #{sep}, the table records #{recorded}"
      else
        assert_nil note, "Features::TABLE says :#{name} is not deprecated, but #{file} marks the witness #[deprecated] (#{note})"
        assert_nil sep, "the witness for :#{name} expects #{sep}, the table says it is not deprecated"
      end

      assert entry[:provided], ":#{name} is marked provided: false; the removal path is not implemented yet"
      assert_includes source, entry[:reference].split("::").last,
                      "Features::TABLE names #{entry[:reference]} for :#{name}, which does not appear in #{file}"
    end
  end

  # A #[deprecated] within the few lines above the declaration belongs to it; one further up is a neighbour's.
  def deprecation_note(lines, idx)
    (idx - 1).downto([idx - 8, 0].max) do |i|
      return lines[i..idx].join(" ")[/note = "(.*?)"/m, 1] || lines[i..idx].join(" ") if lines[i].include?("#[deprecated(")
    end
    nil
  end
end
