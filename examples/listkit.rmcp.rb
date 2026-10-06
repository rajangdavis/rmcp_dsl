# typed: true
# listkit: lists, nil-able values, case/when and the character methods, written in Ruby with no
# Rust. test/e2e_listkit.sh checks every answer against what Ruby itself returns (split drops
# trailing empty pieces, negative indexes count from the end, index counts characters).
server "listkit", version: "0.1.0" do
  params :TextParams do
    field :text, :string, description: "Comma-separated text"
  end

  params :NthParams do
    field :text, :string, description: "Comma-separated text"
    field :n, :i32, description: "Index; negative counts from the end"
  end

  params :CountParams do
    field :n, :i32, description: "How many"
  end

  params :SliceParams do
    field :text, :string, description: "The text to slice"
    field :start, :i32, description: "First character; negative counts from the end"
    field :len, :i32, description: "How many characters"
  end

  tool :parts, params: :TextParams, description: "Split on commas and join with bars (leading empty pieces stay, trailing ones go)" do
    body do |text|
      text.split(",").join("|")
    end
  end

  tool :nth, params: :NthParams, description: "The nth comma-separated piece, or (none)" do
    body do |text, n|
      text.split(",")[n] || "(none)"
    end
  end

  tool :last_part, params: :TextParams, description: "The last comma-separated piece, or (none)" do
    body do |text|
      text.split(",").last || "(none)"
    end
  end

  tool :first_or_raise, params: :TextParams, description: "The first comma-separated piece; an error result when there is none" do
    body do |text|
      text.split(",").first || raise("empty")
    end
  end

  tool :offset, params: :TextParams, description: "Character offset of the first l, or none" do
    body do |text|
      at = text.index("l")
      at.nil? ? "none" : "at #{at || 0}"
    end
  end

  tool :kind, params: :TextParams, description: "Classify the text with case/when" do
    body do |text|
      case text
      when "a", "b" then "ab"
      when /\Ax/ then "x-word"
      else "other"
      end
    end
  end

  tool :scrub, params: :TextParams, description: "tr, then delete, then squeeze" do
    body do |text|
      text.tr("abc", "xyz").delete("-").squeeze
    end
  end

  tool :member, params: :TextParams, description: "Is the text a known colour" do
    body do |text|
      ["red", "green"].include?(text) ? "known" : "unknown"
    end
  end

  tool :count, params: :TextParams, description: "How many comma-separated pieces, or empty" do
    body do |text|
      text.split(",").empty? ? "empty" : text.split(",").length.to_s
    end
  end

  tool :long_words, params: :TextParams, description: "Words longer than three letters, comma-joined" do
    body do |text|
      text.split.select { |w| w.length > 3 }.join(",")
    end
  end

  tool :short_words, params: :TextParams, description: "Words of at most three letters, comma-joined" do
    body do |text|
      text.split.reject { |w| w.length > 3 }.join(",")
    end
  end

  tool :first_long, params: :TextParams, description: "The first word longer than four letters, or (none)" do
    body do |text|
      text.split.find { |w| w.length > 4 } || "(none)"
    end
  end

  tool :has_digit, params: :TextParams, description: "Does any word contain a digit" do
    body do |text|
      text.split.any? { |w| w.match?(/\d/) } ? "yes" : "no"
    end
  end

  tool :all_caps, params: :TextParams, description: "Is every word upper case" do
    body do |text|
      text.split.all? { |w| w == w.upcase } ? "yes" : "no"
    end
  end

  tool :how_many, params: :TextParams, description: "How many words start with a" do
    body do |text|
      text.split.count { |w| w.start_with?("a") }.to_s
    end
  end

  tool :sorted, params: :TextParams, description: "The words sorted, comma-joined" do
    body do |text|
      text.split.sort.join(",")
    end
  end

  tool :unique, params: :TextParams, description: "The comma-separated pieces without repeats" do
    body do |text|
      text.split(",").uniq.join(",")
    end
  end

  tool :backwards, params: :TextParams, description: "The words in reverse order" do
    body do |text|
      text.split.reverse.join(" ")
    end
  end

  tool :port, params: :TextParams, description: "The leading integer of the text, as Ruby to_i reads it" do
    body do |text|
      text.to_i.to_s
    end
  end

  tool :bump, params: :TextParams, description: "The leading integer plus one" do
    body do |text|
      (text.to_i + 1).to_s
    end
  end

  tool :after_scheme, params: :TextParams, description: "Everything after the first ://, or empty" do
    body do |text|
      text.partition("://").last || ""
    end
  end

  tool :before_slash, params: :TextParams, description: "Everything before the first slash" do
    body do |text|
      text.partition("/").first || ""
    end
  end

  tool :limit_two, params: :TextParams, description: "The last piece when splitting on commas into at most two" do
    body do |text|
      text.split(",", 2).last || "(none)"
    end
  end

  tool :strict, params: :TextParams, description: "Parse a decimal integer strictly; anything else is an error result" do
    body do |text|
      Integer(text, 10).to_s
    end
  end

  tool :repeat, params: :NthParams, description: "The text repeated n times; a negative n is an error result" do
    body do |text, n|
      text * n
    end
  end

  tool :pieces, params: :TextParams, description: "The characters joined with dashes" do
    body do |text|
      text.chars.join("-")
    end
  end

  tool :line_count, params: :TextParams, description: "How many lines" do
    body do |text|
      text.lines.length.to_s
    end
  end

  tool :slice, params: :SliceParams, description: "text[start, len], or (nil)" do
    body do |text, start, len|
      text[start, len] || "(nil)"
    end
  end

  tool :at_char, params: :NthParams, description: "text[n], or (nil)" do
    body do |text, n|
      text[n] || "(nil)"
    end
  end

  tool :bracket_digits, params: :TextParams, description: "Wrap every run of digits in brackets (gsub with a block)" do
    body do |text|
      text.gsub(/\d+/) { |m| "[#{m}]" }
    end
  end

  tool :shout_first, params: :TextParams, description: "Upper-case the first lower-case word (sub with a block)" do
    body do |text|
      text.sub(/[a-z]+/) { |w| w.upcase }
    end
  end

  tool :pad_empty, params: :TextParams, description: "Mark every empty match, once per position (gsub with a block)" do
    body do |text|
      text.gsub(/x*/) { |m| "<#{m}>" }
    end
  end

  tool :squares, params: :CountParams, description: "The first n squares, comma-joined (times, map, checked arithmetic in a block)" do
    body do |n|
      n.times.map { |i| i * i }.join(",")
    end
  end

  tool :total, params: :CountParams, description: "The sum of 1..n" do
    body do |n|
      (1..n).sum.to_s
    end
  end

  tool :evens, params: :CountParams, description: "The even numbers up to n" do
    body do |n|
      (1..n).select { |i| i % 2 == 0 }.join(",")
    end
  end

  tool :biggest, params: :CountParams, description: "The largest of 1..n, or empty" do
    body do |n|
      (1..n).max.to_s
    end
  end

  tool :digit_sum, params: :TextParams, description: "Sum the characters read as integers" do
    body do |text|
      text.chars.map { |c| c.to_i }.sum.to_s
    end
  end

  tool :table, params: :CountParams, description: "A small multiplication table (nested blocks)" do
    body do |n|
      n.times.map { |r| (1..3).map { |c| r * c }.join(" ") }.join("|")
    end
  end

  tool :run_up, params: :CountParams, description: "The digits from 2 up to n (upto)" do
    body do |n|
      2.upto(n).map { |i| i.to_s }.join("")
    end
  end

  tool :has_num, params: :CountParams, description: "Is n one of 1, 2, 3" do
    body do |n|
      [1, 2, 3].include?(n) ? "yes" : "no"
    end
  end

  tool :sorted_nums, params: :CountParams, description: "An integer array literal, sorted, de-duplicated and reversed" do
    body do
      [3, 1, 2, 3].sort.uniq.reverse.join(",")
    end
  end

  tool :guarded, params: :CountParams, description: "1..n as text; raise inside a block when n is above 3" do
    body do |n|
      (1..n).map { |i| i > 3 ? raise("too big") : i.to_s }.join(",")
    end
  end

  tool :first_big, params: :CountParams, description: "The first i whose square exceeds 20, or empty" do
    body do |n|
      (1..n).find { |i| i * i > 20 }.to_s
    end
  end

  tool :count_even, params: :CountParams, description: "How many even numbers in 1..n" do
    body do |n|
      (1..n).count { |i| i % 2 == 0 }.to_s
    end
  end

  tool :all_small, params: :CountParams, description: "Is every number in 1..n below 5" do
    body do |n|
      (1..n).all? { |i| i < 5 } ? "yes" : "no"
    end
  end

  tool :twice, params: :TextParams, description: "Use a local list twice: how many pieces, and how many longer than one character" do
    body do |text|
      parts = text.split(",")
      "#{parts.length}/#{parts.select { |piece| piece.length > 1 }.length}"
    end
  end

  tool :classify, params: :TextParams, description: "Guard clauses: return early, or raise" do
    body do |text|
      return "empty" if text.empty?
      return "long" unless text.length < 5
      raise "digits not allowed" if text.match?(/\d/)
      first = text.start_with?("a")
      return "a-word" if first
      "short"
    end
  end

  tool :big_or_list, params: :CountParams, description: "1..n as text, but return big from inside the block when n is large" do
    body do |n|
      (1..n).map { |i| i > 3 ? (return "big") : i.to_s }.join(",")
    end
  end

  # `each` runs the block for its effects, and this body's effects are progress notifications, so the
  # tool is compiled async. The block's value is ignored; the loop yields the list, which is dropped.
  tool :announce, params: :TextParams, description: "Send a progress notification for each comma-separated word" do
    body do |text|
      text.split(",").each { |w| progress(1, message: w) }
      "announced"
    end
  end

  # Cooperative cancellation: the client's `notifications/cancelled` cancels the request token, but rmcp
  # does not force-stop the body. This loop awaits on a progress notification each iteration, so it can
  # observe `cancelled?` and stop early; the e2e cancels it and checks that it did.
  tool :slow_count, params: :CountParams, description: "Count to n, one progress notification per step; stop early when the call is cancelled" do
    body do |n|
      (1..n).each do |i|
        progress(i, total: n, message: "step #{i}")
        raise "cancelled" if cancelled?
      end
      "done"
    end
  end

  params :FloatParams do
    field :values, :f64_list, description: "Numbers to work on", min_items: 1, max_items: 4
  end

  output :FloatStats do
    field :total, :f64, description: "Sum of the values"
    field :smallest, :f64, description: "Smallest value"
    field :largest, :f64, description: "Largest value"
    field :halved, :f64_list, description: "Each value times a half"
  end

  tool :float_join, params: :FloatParams, description: "Join the values with commas as Ruby prints them" do
    body do |values|
      values.join(",")
    end
  end

  tool :float_stats, params: :FloatParams, output: :FloatStats, description: "Sum, bounds and halved values" do
    body do |values|
      result(:FloatStats, total: values.sum, smallest: values.min || 0.0, largest: values.max || 0.0,
             halved: values.map { |x| x * 0.5 })
    end
  end

  tool :float_order, params: :FloatParams, description: "Sort, de-duplicate and reverse the values" do
    body do |values|
      values.sort.uniq.reverse.join(" ")
    end
  end

  tool :float_filter, params: :FloatParams, description: "Keep, drop and count values with blocks" do
    body do |values|
      big = values.select { |x| x > 1.5 }
      "#{big.join(",")}|#{values.reject { |x| x > 1.5 }.join(",")}|#{values.find { |x| x > 2.0 }.to_s}|#{values.any? { |x| x > 2.0 }}|#{values.all? { |x| x > 0.5 }}|#{values.count { |x| x > 1.5 }}"
    end
  end

  tool :float_pick, params: :FloatParams, description: "First, last, second and membership" do
    body do |values|
      "#{values.first.to_s}|#{values.last.to_s}|#{values[1].to_s}|#{values.include?(2.5)}|#{values.empty?}|#{values.length}"
    end
  end

  tool :float_literal, params: :FloatParams, description: "A float array literal joined and summed" do
    body do |values|
      lit = [1.5, 2.5, 0.5]
      "#{values.join("/")} vs #{lit.join("/")} = #{lit.sum}"
    end
  end

  transport :stdio
end
