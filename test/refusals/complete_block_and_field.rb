# expect: both complete the same arguments, so keep only one
server "t", version: "0.1.0" do
  helper :choices, args: [:string], returns: :string_list do |typed|
    ["a"].select { |v| v.start_with?(typed) }
  end

  params :P do
    field :id, :string, complete: :choices
  end

  resource :r, uri: "t://r/{id}", params: :P do
    body do |id|
      id
    end

    complete do |arg, typed|
      ["a"].select { |v| v.start_with?(typed) && arg == "id" }
    end
  end

  transport :stdio
end
