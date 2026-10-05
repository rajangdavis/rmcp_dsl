# expect: type mismatch
server "t", version: "0.1.0" do
  params :P do
    field :a, :i32
    field :b, :i64
  end

  tool :x, params: :P, description: "d" do
    body do |a, b|
      (a + b).to_s
    end
  end

  transport :stdio
end
