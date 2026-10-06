# typed: true
# Bindings: the body is plain Ruby calling Heck.snake_case(...) and Words.shout(...). Heck is backed
# by the heck crate (bindings/heck.rb); Words is compiled from the Ruby in bindings/words.rb. Both are in the bindings/
# folder next to this file: a binding is found only in a bindings/ folder in the same directory as the file using it.
server "bindings", version: "0.1.0" do
  use_bindings :heck
  use_bindings :words

  params :TextParams do
    field :text, :string
  end

  tool :snake_case, params: :TextParams, description: "snake_case (the heck crate)" do
    body do |text|
      Heck.snake_case(text)
    end
  end

  tool :kebab_case, params: :TextParams, description: "kebab-case (the heck crate)" do
    body do |text|
      Heck.kebab_case(text)
    end
  end

  tool :upper_camel_case, params: :TextParams, description: "UpperCamelCase (the heck crate)" do
    body do |text|
      Heck.upper_camel_case(text)
    end
  end

  tool :shout, params: :TextParams, description: "Uppercase with an exclamation mark (compiled from Ruby)" do
    body do |text|
      Words.shout(text)
    end
  end

  tool :bracket, params: :TextParams, description: "Trim and wrap in brackets (compiled from Ruby)" do
    body do |text|
      Words.bracket(text)
    end
  end

  transport :stdio
end
