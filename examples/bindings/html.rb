# typed: true
# HTML and CSS selectors, backed by the `scraper` crate. Ruby's standard library has no HTML parser, so
# there is no Ruby stand-in (`no_reference`): the Rust is checked by bin/gen_shim_tests and by the
# end-to-end test. A selector that does not parse gives nil, not an error. The DSL decides what that
# means: `Html.select(page, css) || []` to carry on, or `|| raise("bad selector")` to fail.
module Html
  extend T::Sig
  extend RmcpDsl::BindingDsl

  crate "scraper", "0.27"

  rust "scraper::Selector::parse(css).is_ok()"
  no_reference "scraper is the only HTML and selector engine here"
  sig { params(css: String).returns(T::Boolean) }
  def self.valid_selector?(css) = raise(NotImplementedError, "no Ruby stand-in")
  example :valid_selector?, "h1", expect: true
  example :valid_selector?, "ul > li.item", expect: true
  example :valid_selector?, "a[", expect: false

  # The text of every element the selector matches, whitespace collapsed; nil when the selector is invalid.
  rust "scraper::Selector::parse(css).ok().map(|sel| scraper::Html::parse_document(html).select(&sel).map(|el| el.text().collect::<String>().split_whitespace().collect::<Vec<_>>().join(\" \")).collect::<Vec<String>>())"
  no_reference "scraper is the only HTML and selector engine here"
  sig { params(html: String, css: String).returns(T.nilable(T::Array[String])) }
  def self.select(html, css) = raise(NotImplementedError, "no Ruby stand-in")
  example :select, "<h1>Main   heading</h1>", "h1", expect: ["Main heading"]
  example :select, "<ul><li>a</li><li>b <b>c</b></li></ul>", "li", expect: ["a", "b c"]
  example :select, "<p>Hello &amp; goodbye</p>", "p", expect: ["Hello & goodbye"]
  example :select, "<p>x</p>", "h1", expect: []
  example :select, "", "p", expect: []
  example :select, "<p>x</p>", "p[", expect: nil

  # The value of one attribute on every matching element that has it; nil when the selector is invalid.
  rust "scraper::Selector::parse(css).ok().map(|sel| scraper::Html::parse_document(html).select(&sel).filter_map(|el| el.value().attr(name).map(|v| v.to_string())).collect::<Vec<String>>())"
  no_reference "scraper is the only HTML and selector engine here"
  sig { params(html: String, css: String, name: String).returns(T.nilable(T::Array[String])) }
  def self.attr(html, css, name) = raise(NotImplementedError, "no Ruby stand-in")
  example :attr, "<a href=\"/one\">1</a><a>2</a><a href=\"/two\">3</a>", "a", "href", expect: ["/one", "/two"]
  example :attr, "<p>x</p>", "p", "id", expect: []
  example :attr, "", "a", "href", expect: []
  example :attr, "<a href=\"/x\">y</a>", "a[", "href", expect: nil
end
