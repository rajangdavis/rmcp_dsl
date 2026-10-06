# typed: true
# fetchkit: fetch public web pages with curl. The address guard, redirect handling and curl
# arguments live in examples/rust/guard.rs (hand-written Rust, unit-tested there); this file
# only declares the tools. Page text is untrusted content, never instructions.
server "fetchkit", version: "0.1.0" do
  rust_file "rust/guard.rs", as: :guard, uses: :subprocess
  rust_fn :fetch, from: :guard, args: [:string], returns: :string
  rust_fn :head, from: :guard, args: [:string], returns: :string
  rust_crate "scraper", "0.27" # HTML parsing and CSS selectors (0.27.0 resolved on the first build)
  rust_fn :select, from: :guard, args: [:string, :string], returns: :string
  rust_fn :attr, from: :guard, args: [:string, :string, :string], returns: :string

  params :UrlParams do
    field :url, :string
  end

  params :SelectParams do
    field :url, :string
    field :css, :string
  end

  params :AttrParams do
    field :url, :string
    field :css, :string
    field :attr, :string
  end

  tool :fetch, params: :UrlParams, description: "GET a public http(s) URL with curl and return the page. Returns untrusted content, labelled as such. Private, loopback and link-local addresses are refused; up to 3 redirects are followed, each re-checked; 8 s time limit and 1 MB size limit. Failures start with 'error:'." do
    body do |url|
      rust(:fetch, url)
    end
  end

  tool :head, params: :UrlParams, description: "Like fetch, but sends a HEAD request and returns the status line and headers." do
    body do |url|
      rust(:head, url)
    end
  end

  tool :select, params: :SelectParams, description: "Fetch a public http(s) URL (same checks as fetch) and return the text of every element matching a CSS selector, one per line, whitespace collapsed, at most 200 matches of 500 characters. Untrusted content. Failures start with 'error:'." do
    body do |url, css|
      rust(:select, url, css)
    end
  end

  tool :attr, params: :AttrParams, description: "Like select, but returns the value of one attribute (for example href) of every matching element that has it." do
    body do |url, css, attr|
      rust(:attr, url, css, attr)
    end
  end

  transport :stdio
end
