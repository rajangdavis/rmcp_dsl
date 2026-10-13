# frozen_string_literal: true

# Records for test/test_records.rb: Row is a Rust struct in rust/rows.rs, and its fields are declared here so a DSL
# body can read them.
module Rows
  extend T::Sig
  extend RmcpDsl::BindingDsl

  class Row < RmcpDsl::Opaque
    type_rust "rows::Row", wire: true
    field :text, String
    field :href, T.nilable(String)
    field :rank, I64
  end

  sig { params(count: I64).returns(T::Array[Row]) }
  rust "rows::make(count)"
  no_reference "the rows are built in rust/rows.rs"
  def self.make(count); end
end
