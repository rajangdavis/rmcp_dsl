# expect: both complete the same arguments, so keep only one
server "t", version: "0.1.0" do
  params :P do
    field :id, :string, enum: ["1"]
  end

  resource :r, uri: "t://r/{id}", params: :P do
    body do |id|
      id
    end

    complete do |arg, typed|
      ["1"].select { |v| v.start_with?(typed) && arg == "id" }
    end
  end

  transport :stdio
end
