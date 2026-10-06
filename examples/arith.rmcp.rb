# typed: true
# Integer arithmetic: Ruby semantics by default (/ and % round down), overflow is a friendly
# error, and wrapping a value in Rust::Int32(...) opts in to Rust's truncating behaviour.
server "arith", version: "0.1.0" do
  params :CalcParams do
    field :a, :i32
    field :b, :i32
  end

  params :OneParams do
    field :a, :i32
  end

  tool :add, params: :CalcParams, description: "a + b" do
    body do |a, b|
      (a + b).to_s
    end
  end

  tool :subtract, params: :CalcParams, description: "a - b" do
    body do |a, b|
      (a - b).to_s
    end
  end

  tool :multiply, params: :CalcParams, description: "a * b" do
    body do |a, b|
      (a * b).to_s
    end
  end

  tool :divide, params: :CalcParams, description: "a / b, rounding down like Ruby" do
    body do |a, b|
      (a / b).to_s
    end
  end

  tool :divide_like_rust, params: :CalcParams, description: "a / b, truncating toward zero like Rust" do
    body do |a, b|
      (Rust::Int32(a) / Rust::Int32(b)).to_s
    end
  end

  tool :remainder_like_rust, params: :CalcParams, description: "a % b with Rust's sign rule (the sign of a); one Rust::Int32 operand is enough" do
    body do |a, b|
      (Rust::Int32(a) % b).to_s
    end
  end

  tool :modulo, params: :CalcParams, description: "a % b, with the sign of b like Ruby" do
    body do |a, b|
      (a % b).to_s
    end
  end

  tool :negate, params: :OneParams, description: "-a" do
    body do |a|
      (-a).to_s
    end
  end

  transport :stdio
end
