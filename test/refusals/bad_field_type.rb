# expect: `:banana` is not a field type (:i32 :i64 :f64 :bool :string :string_list :i64_list :f64_list, map(...), list(...), or the CamelCase name of another params)
server "t", version: "0.1.0" do
  params :P do
    field :text, :banana
  end

  tool :x, params: :P, description: "d" do
    body do |text|
      text
    end
  end

  transport :stdio
end
