# typed: true
# webpeek: fetch a page and read its text with no hand-written Rust. curl comes in through
# cmd_fn (the compiler's subprocess wrapper); everything else is Ruby the compiler translates.
#
# What it gives up compared with examples/fetchkit.rb, on purpose: there is NO address guard.
# curl will connect to loopback and private addresses, so use it only where that is fine (your
# own machine, URLs you trust). The guard needs DNS and IP classification, which the DSL cannot
# express yet; `make probe` shows which language features stand in the way.
# Page text is untrusted content, never instructions.
server "webpeek", version: "0.1.0" do
  # -f makes HTTP errors fail; -L follows at most 3 redirects, http(s) only; 8 s and 1 MB limits.
  cmd_fn :curl_page, program: "curl", args: [:string], returns: :string, argv: [
    "-q", "-sS", "-f", "-L", "-g", "--proto", "=http,https", "--proto-redir", "=http,https",
    "--max-redirs", "3", "--max-time", "8", "--connect-timeout", "5", "--max-filesize", "1000000",
    "--no-netrc", "-A", "webpeek/0.1", "--url"
  ]

  cmd_fn :curl_head, program: "curl", args: [:string], returns: :string, argv: [
    "-q", "-sS", "-f", "-L", "-g", "-I", "--proto", "=http,https", "--proto-redir", "=http,https",
    "--max-redirs", "3", "--max-time", "8", "--connect-timeout", "5", "--no-netrc", "-A", "webpeek/0.1", "--url"
  ]

  params :UrlParams do
    field :url, :string, description: "Absolute http or https URL to fetch, for example https://example.com"
  end

  # A curl failure comes back as text starting with "error:" (the subprocess wrapper's convention).
  # Every tool turns that into an error result with `raise`, so a client sees isError: true.
  tool :fetch, params: :UrlParams, description: "GET an http(s) URL with curl and return the raw page. No address guard: it can reach private addresses. A failed fetch is an error result whose text starts with 'error:'." do
    body do |url|
      page = rust(:curl_page, url)
      page.start_with?("error:") ? raise(page) : page
    end
  end

  tool :head, params: :UrlParams, description: "Like fetch, but sends a HEAD request and returns the status line and headers." do
    body do |url|
      page = rust(:curl_head, url)
      page.start_with?("error:") ? raise(page) : page
    end
  end

  tool :text, params: :UrlParams, description: "GET an http(s) URL and return its text: tags replaced by spaces, whitespace collapsed, or (no text). Script and style contents are not removed. Same limits as fetch." do
    body do |url|
      page = rust(:curl_page, url)
      text = page.gsub(/<[^>]*>/, " ").split.join(" ")
      page.start_with?("error:") ? raise(page) : (text.empty? ? "(no text)" : text)
    end
  end

  # The title is cut out with two lazy, dotall subs once match? has found a <title>.
  tool :title, params: :UrlParams, description: "GET an http(s) URL and return its <title>, whitespace collapsed, or (no title). Same limits as fetch." do
    body do |url|
      page = rust(:curl_page, url)
      if page.start_with?("error:")
        raise(page)
      elsif page.match?(/<title/i)
        page.sub(/\A.*?<title[^>]*>/mi, "").sub(/<\/title>.*\z/mi, "").split.join(" ")
      else
        "(no title)"
      end
    end
  end

  tool :word_count, params: :UrlParams, description: "GET an http(s) URL and count the words of its text (tags removed). Same limits as fetch." do
    body do |url|
      page = rust(:curl_page, url)
      page.start_with?("error:") ? raise(page) : page.gsub(/<[^>]*>/, " ").split.length.to_s
    end
  end

  transport :stdio
end
