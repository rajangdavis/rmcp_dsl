# expect: only applies to a resource template
server "t", version: "0.1.0" do
  resource :r, uri: "t://r" do
    body do
      "x"
    end

    complete do |arg, typed|
      ["a"].select { |v| v.start_with?(typed) && arg == "id" }
    end
  end

  transport :stdio
end
