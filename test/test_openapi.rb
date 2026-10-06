# frozen_string_literal: true

# The OpenAPI planner: documents in, one plan per operation out, and a clear error for everything it cannot take.
#
#   ruby -Ilib test/test_openapi.rb
require "minitest/autorun"
require "tmpdir"
require "json"
require "rmcp_dsl"

class TestOpenApi < Minitest::Test
  FIXTURES = File.expand_path("fixtures/openapi", __dir__)
  PETSTORE = File.join(FIXTURES, "petstore.json")
  SHOP = File.join(FIXTURES, "shop31.yaml")

  def plans(path = PETSTORE, **filters)
    RmcpDsl::OpenApi.plan(RmcpDsl::OpenApi.load(path), path, **filters)
  end

  def by_name(list) = list.to_h { |pl| [pl.name, pl] }

  # A document written to a file, for the refusals.
  def refuse(doc, ext: "json", **filters)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "spec.#{ext}")
      File.write(path, doc.is_a?(String) ? doc : JSON.generate(doc))
      return assert_raises(RmcpDsl::CompileError) { plans(path, **filters) }.message
    end
  end

  ID = { "name" => "id", "in" => "path", "required" => true, "schema" => { "type" => "string" } }.freeze

  # One operation on /x/{id}; its path parameter is always declared, and `operation` adds to the operation.
  def minimal(operation, extra = {})
    op = { "responses" => {} }.merge(operation)
    op["parameters"] = [ID] + (operation["parameters"] || [])
    { "openapi" => "3.0.0", "paths" => { "/x/{id}" => { "get" => op } } }.merge(extra)
  end

  def test_one_plan_per_operation_named_from_the_operation_id
    names = plans.map(&:name)
    assert_equal %w[list_pets create_pet get_pet_by_id put_pets_pet_id delete_pet].sort, names.sort
  end

  def test_an_operation_without_an_id_is_named_from_its_method_and_path
    assert_equal "put_pets_pet_id", by_name(plans).fetch("put_pets_pet_id").name
  end

  def test_description_is_the_summary_and_the_description_or_the_request_line
    list = by_name(plans)
    assert_equal "List pets\n\nReturns the pets, newest first.", list["list_pets"].description
    assert_equal "DELETE /pets/{petId}", list["delete_pet"].description
  end

  def test_annotations_follow_the_method
    list = by_name(plans)
    assert_equal({ "open_world" => true, "read_only" => true }, list["list_pets"].annotations)
    assert_equal({ "open_world" => true, "idempotent" => true }, list["delete_pet"].annotations)
    assert_equal({ "open_world" => true, "idempotent" => true }, list["put_pets_pet_id"].annotations)
    assert_equal({ "open_world" => true }, list["create_pet"].annotations)
  end

  def test_parameters_become_typed_fields_with_their_constraints
    fields = by_name(plans).fetch("list_pets").fields.to_h { |f| [f["name"], f] }
    assert_equal({ "name" => "limit", "type" => "i64", "min" => 1, "max" => 100, "description" => "How many to return", "optional" => true }, fields["limit"])
    assert_equal %w[available sold], fields["status"]["enum"]
    assert_equal "string_list", fields["tag"]["type"]
  end

  def test_a_path_parameter_shared_by_the_path_item_is_required_on_each_operation
    fields = by_name(plans).fetch("get_pet_by_id").fields.to_h { |f| [f["name"], f] }
    assert_equal "i64", fields["pet_id"]["type"]
    refute fields["pet_id"]["optional"]
    assert_equal "uuid", fields["x_request_id"]["format"]
    assert fields["x_request_id"]["optional"]
  end

  def test_the_request_says_where_each_field_goes
    req = by_name(plans).fetch("get_pet_by_id").request
    assert_equal "GET", req["method"]
    assert_equal [%w[petId pet_id]], req["path_params"]
    assert_equal [{ "name" => "X-Request-Id", "field" => "x_request_id", "list" => false }], req["headers"]
    list = by_name(plans).fetch("list_pets").request
    assert_equal({ "name" => "tag", "field" => "tag", "list" => true, "explode" => true }, list["query"].last)
  end

  def test_the_schema_is_published_with_required_and_a_bundled_ref
    schema = by_name(plans).fetch("create_pet").schema
    assert_equal "object", schema["type"]
    assert_equal ["body"], schema["required"]
    assert_equal({ "$ref" => "#/$defs/Pet" }, schema["properties"]["body"])
    assert_equal %w[Owner Pet], schema["$defs"].keys.sort
    assert_equal "#/$defs/Owner", schema["$defs"]["Pet"]["properties"]["owner"]["$ref"]
    assert_equal "#/$defs/Pet", schema["$defs"]["Owner"]["properties"]["pets"]["items"]["$ref"] # a cycle ends
  end

  def test_openapi_30_is_published_as_json_schema_2020_12
    defs = by_name(plans).fetch("create_pet").schema["$defs"]
    assert_equal ["string", "null"], defs["Pet"]["properties"]["tag"]["type"] # nullable
    limit = by_name(plans).fetch("list_pets").schema["properties"]["limit"]
    assert_equal [20], limit["examples"]
    refute limit.key?("example")
  end

  def test_the_body_is_one_optional_or_required_opaque_field
    create = by_name(plans).fetch("create_pet")
    body = create.fields.find { |f| f["name"] == "body" }
    assert_equal "OpenApi::Value", body["type"]
    refute body["optional"]
    assert_equal "body", create.request["body"]
    replace = by_name(plans).fetch("put_pets_pet_id").fields.find { |f| f["name"] == "body" }
    assert replace["optional"]
  end

  def test_yaml_31_documents_work_and_colliding_names_get_the_place_as_a_suffix
    shop = by_name(plans(SHOP))
    item = shop.fetch("get_item")
    assert_equal %w[id id_query fields price type_], item.fields.map { |f| f["name"] }
    assert_equal [%w[id id]], item.request["path_params"]
    assert_equal "id_query", item.request["query"].first["field"]
    fields = item.fields.to_h { |f| [f["name"], f] }
    assert_equal({ "name" => "fields", "type" => "i64_list", "min_items" => 1, "optional" => true }, fields["fields"])
    assert_equal 0, fields["price"]["exclusive_min"], "the exclusive bound becomes an exclusive_min"
    refute fields["price"].key?("min"), "the redundant inclusive bound is dropped"
    assert_equal "string", fields["type_"]["type"] # a Rust keyword gets an underscore; the document says `type`
    assert_equal 1, fields["id"]["min_length"]
  end

  def test_include_tags_and_exclude_filter_the_operations
    assert_equal %w[delete_pet], plans(include_tags: ["admin"]).map(&:name)
    list = plans(exclude: ["deletePet", "put_pets_pet_id"]).map(&:name)
    refute_includes list, "delete_pet"
    refute_includes list, "put_pets_pet_id"
  end

  def test_unknown_filter_names_are_listed
    assert_includes refuse(JSON.parse(File.read(PETSTORE)), include_tags: ["nope"]), "`include_tags:` names \"nope\""
    msg = refuse(JSON.parse(File.read(PETSTORE)), exclude: ["deletePett"])
    assert_includes msg, "`exclude:` names \"deletePett\""
    assert_includes msg, "operations: "
    assert_includes refuse(JSON.parse(File.read(PETSTORE)), include_tags: ["admin"], exclude: ["deletePet"]), "the filters leave no operation"
  end

  def test_files_that_are_not_openapi_are_refused_with_a_pointer
    assert_includes refuse("{ nope"), "is not valid JSON"
    assert_includes refuse("a: [", ext: "yaml"), "is not valid YAML"
    assert_includes refuse([1]), "must hold one object"
    assert_includes refuse({ "swagger" => "2.0" }), "Swagger 2.0 document; only OpenAPI 3.0 and 3.1"
    assert_includes refuse({ "openapi" => "4.0.0", "paths" => {} }), "only 3.0.x and 3.1.x"
    assert_includes refuse({ "info" => {} }), "has no `openapi` version"
    assert_includes refuse({ "openapi" => "3.0.0" }), "has no `paths`"
    assert_includes refuse({ "openapi" => "3.0.0", "paths" => { "/a" => {} } }), "has no operations"
  end

  def test_what_cannot_be_a_tool_is_refused_with_the_operation
    assert_includes refuse(minimal("parameters" => [{ "name" => "c", "in" => "cookie", "schema" => { "type" => "string" } }])), "GET /x/{id} has the cookie parameter `c`"
    assert_includes refuse(minimal("parameters" => [{ "name" => "o", "in" => "query", "schema" => { "type" => "object" } }])), "the query parameter `o` has a schema of type \"object\""
    assert_includes refuse(minimal("parameters" => [{ "name" => "a", "in" => "query", "schema" => { "type" => "array", "items" => { "type" => "object" } } }])), "an array of object"
    assert_includes refuse(minimal("requestBody" => { "content" => { "application/x-www-form-urlencoded" => { "schema" => {} } } })), "only application/json bodies are supported"
    assert_includes refuse(minimal("parameters" => [{ "name" => "q", "in" => "query", "style" => "deepObject", "schema" => { "type" => "string" } }])), "only the default style (form)"
    only_path = { "openapi" => "3.0.0", "paths" => { "/x/{id}" => { "get" => { "responses" => {} } } } }
    assert_includes refuse(only_path), "has {id} in its path but no path parameter"
  end

  def test_references_outside_the_document_are_refused
    msg = refuse(minimal("parameters" => [{ "$ref" => "other.json#/x" }]))
    assert_includes msg, "outside the document"
    msg = refuse(minimal("requestBody" => { "content" => { "application/json" => { "schema" => { "$ref" => "#/components/schemas/Nope" } } } }))
    assert_includes msg, "points at nothing"
  end

  def test_two_operations_with_one_tool_name_are_refused
    doc = { "openapi" => "3.0.0", "paths" => { "/a" => { "get" => { "operationId" => "same" } }, "/b" => { "get" => { "operationId" => "same" } } } }
    assert_includes refuse(doc), "two operations would be the tool of the same name"
  end

  def test_names_are_made_safe
    assert_equal "get_users_id", RmcpDsl::OpenApi::Naming.field("GET /users/{id}")
    assert_equal "user_id", RmcpDsl::OpenApi::Naming.field("userID")
    assert_equal "x_request_id", RmcpDsl::OpenApi::Naming.field("X-Request-Id")
    assert_equal "filter_status", RmcpDsl::OpenApi::Naming.field("filter[status]")
    assert_equal "type_", RmcpDsl::OpenApi::Naming.field("type")
    assert_equal "op_2fa", RmcpDsl::OpenApi::Naming.field("2fa")
  end
end
