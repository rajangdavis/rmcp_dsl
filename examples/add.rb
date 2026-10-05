# typed: true
server "calculator", version: "0.1.0" do
  params :CalcParams do
    field :a, :i32
    field :b, :i32
  end

  tool :add, params: :CalcParams, description: "Add two integers" do
    body do |a, b|
      (a + b).to_s
    end
  end

  tool :subtract, params: :CalcParams, description: "Subtract two integers" do
    body do |a, b|
      (a - b).to_s
    end
  end

  transport :stdio
end
