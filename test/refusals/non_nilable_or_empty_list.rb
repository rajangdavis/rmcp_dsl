# expect: is not nilable, so `||` gives `[]` no element type
server "t", version: "0.1.0" do
  params :P do
    field :names, :string_list
  end

  tool :x, params: :P, description: "d" do
    body do |names|
      listed = names || []
      listed.join(", ")
    end
  end

  transport :stdio
end
