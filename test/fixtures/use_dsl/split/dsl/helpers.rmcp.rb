fragment do
  helper :shout, args: [:string], returns: :string do |text|
    "#{text.upcase}!"
  end
end
