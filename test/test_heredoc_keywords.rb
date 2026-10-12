# frozen_string_literal: true

# A heredoc is a string literal wherever the DSL takes one, so a page of prose such as `instructions:` can be
# written as one. The block's `do` belongs on the line that opens the heredoc; written after the terminator it
# is Ruby's own syntax error, and the message says where the `do` goes (rmcp-for-blender gap #18).
#
#   ruby -Ilib test/test_heredoc_keywords.rb
require "minitest/autorun"
require "tmpdir"
require "rmcp_dsl"

class TestHeredocKeywords < Minitest::Test
  BODY = <<~RB
    params :P do
      field :s, :string
    end
    tool :t, params: :P, description: "d" do
      body do |s|
        s
      end
    end
    transport :stdio
  end
  RB

  def read_source(source)
    Dir.mktmpdir("heredoc") do |dir|
      path = File.join(dir, "s.rmcp.rb")
      File.write(path, source)
      RmcpDsl::Notify.reset!
      return RmcpDsl.read(path)
    end
  end

  def test_a_heredoc_is_an_instructions_value
    source = "server \"s\", version: \"0.1.0\", instructions: <<~'TXT' do\n  Line one.\n  Line two.\nTXT\n#{BODY}"
    ir = read_source(source)
    assert_equal "Line one.\nLine two.\n", ir["instructions"]
  end

  def test_a_do_after_the_terminator_names_where_it_goes
    source = "server \"s\", version: \"0.1.0\",\n       instructions: <<~'TXT'\n  Prose.\nTXT\n       do\n#{BODY}"
    err = assert_raises(RmcpDsl::CompileError) { read_source(source) }
    assert_match(/goes at the end of the line that opens the heredoc/, err.message)
  end
end
