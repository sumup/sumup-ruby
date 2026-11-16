# frozen_string_literal: true

require_relative "test_helper"
require_relative "../codegen/generator"
require "tmpdir"

class GeneratorTest < Minitest::Test
  def fixture(schemas: {}, path_item: nil)
    {
      "openapi" => "3.1.0", "info" => {"version" => "1.0.0"},
      "components" => {"schemas" => schemas},
      "paths" => {"/widgets/{id}" => path_item || {
        "parameters" => [{"name" => "id", "in" => "path", "required" => true, "schema" => {"type" => "string"}}],
        "get" => {"operationId" => "GetWidget", "description" => "Read the merchant’s widget", "tags" => ["Widgets"], "x-codegen" => {"method_name" => "get"},
                  "responses" => {"200" => {"content" => {"application/json" => {"schema" => {"type" => "object"}}}}}}
      }}
    }
  end

  def generate(**options)
    SumUpCodegen::Generator.new(fixture(**options)).generate
  end

  def test_described_refs_and_annotation_allof_preserve_named_types
    files = generate(schemas: {
      "Amount" => {"type" => "integer"},
      "Amounts" => {"type" => "array", "items" => {"$ref" => "#/components/schemas/Amount"}},
      "Widget" => {"type" => "object", "properties" => {
        "amount" => {"$ref" => "#/components/schemas/Amount", "description" => "Amount"},
        "amounts" => {"allOf" => [{"$ref" => "#/components/schemas/Amounts"}], "description" => "Values"}
      }}
    })
    source = files.fetch("lib/sumup/types.rb")
    assert_includes source, "field :amount, :integer"
    assert_includes source, "field :amounts, [:array, :integer]"
    assert_includes files.fetch("sig/sumup/types.rbs"), "attr_reader amounts: (Array[Integer])?"
  end

  def test_allof_inheritance_and_recursive_references_are_preserved
    files = generate(schemas: {
      "Base" => {"type" => "object", "required" => ["id"], "properties" => {"id" => {"type" => "string"}}},
      "Node" => {"allOf" => [{"$ref" => "#/components/schemas/Base"}, {"type" => "object", "properties" => {"child" => {"$ref" => "#/components/schemas/Node"}}}]}
    })
    source = files.fetch("lib/sumup/types.rb").split("class Node < Model").last
    assert_includes source, 'field :id, :string, wire: "id", required: true'
    assert_includes source, 'field :child, [:model, "Node"]'
  end

  def test_equivalent_scalar_aliases_do_not_degrade_to_untyped
    files = generate(schemas: {
      "Amount" => {"type" => "integer"},
      "Count" => {"type" => "integer"},
      "Widget" => {"properties" => {"count" => {"$ref" => "#/components/schemas/Count"}}}
    })
    assert_includes files.fetch("lib/sumup/types.rb"), "field :count, :integer"
  end

  def test_request_signatures_accept_model_instances_and_nested_hashes
    generator = SumUpCodegen::Generator.new(JSON.parse(File.read(File.expand_path("../openapi.json", __dir__))))
    signatures = generator.generate.fetch("sig/sumup/resources/readers.rbs")
    assert_includes signatures, "total_amount: Types::CreateReaderCheckoutRequestTotalAmount | Hash[Symbol | String, untyped]"
  end

  def test_nullable_scalar_and_primitive_union_types_are_not_objects
    files = generate(schemas: {"Widget" => {"properties" => {
      "optional" => {"type" => ["string", "null"]},
      "country" => {"oneOf" => [{"type" => "string", "enum" => ["DE"]}, {"type" => "string"}]}
    }}})
    assert_includes files.fetch("lib/sumup/types.rb"), "field :optional, [:union, [:string, :nil]]"
    assert_includes files.fetch("lib/sumup/types.rb"), "field :country, [:union, [:string]]"
    refute_includes files.fetch("lib/sumup/types.rb"), "class WidgetCountry"
  end

  def test_path_level_parameters_and_operation_overrides_are_merged
    item = fixture.fetch("paths").values.first
    item["get"]["parameters"] = [{"name" => "id", "in" => "path", "required" => true, "schema" => {"type" => "integer"}},
      {"name" => "resource.id", "in" => "query", "schema" => {"type" => "string"}}]
    files = generate(path_item: item)
    source = files.fetch("lib/sumup/resources/widgets.rb")
    assert_includes source, "def get(id:, resource_id: UNSET, options: nil)"
    assert_includes source, '"resource.id" => resource_id'
    assert_includes files.fetch("sig/sumup/resources/widgets.rbs"), "id: Integer"
  end

  def test_response_type_literals_have_stable_spacing_across_ruby_versions
    source = generate.fetch("lib/sumup/resources/widgets.rb")
    assert_includes source, "response_type: {200 => [:map, :any]}"
  end

  def test_external_references_fail_explicitly
    error = assert_raises(RuntimeError) { generate(schemas: {"Widget" => {"$ref" => "https://example.com/schema"}}) }
    assert_match(/local references/, error.message)
  end

  def test_output_is_deterministic_and_check_detects_changes_and_stale_files
    generator = SumUpCodegen::Generator.new(fixture)
    assert_equal generator.generate, generator.generate
    Dir.mktmpdir("sumup-ruby-codegen") do |directory|
      generator.write(directory).each do |path, contents|
        assert_equal contents.b, File.binread(File.join(directory, path)), path
      end
      generator.write(directory, check: true)
      stale = File.join(directory, "lib/sumup/resources/stale.rb")
      File.write(stale, "old output")
      assert_raises(RuntimeError) { generator.write(directory, check: true) }
      generator.write(directory)
      refute File.exist?(stale)
      File.write(File.join(directory, "lib/sumup/types.rb"), "changed")
      assert_raises(RuntimeError) { generator.write(directory, check: true) }
    end
  end

  def test_current_spec_covers_every_operation_and_event
    spec = JSON.parse(File.read(File.expand_path("../openapi.json", __dir__)))
    generator = SumUpCodegen::Generator.new(spec)
    files = generator.generate
    expected = spec.fetch("paths").values.flat_map { |item| item.slice(*SumUpCodegen::Generator::METHODS).values.map { |operation| operation.fetch("operationId") } }
    assert_equal expected.sort, generator.operations.map { |operation| operation[:id] }.sort
    assert_equal spec.fetch("webhooks").keys.sort, SumUp::Events::TYPES.keys.sort
    files.each do |path, contents|
      RubyVM::InstructionSequence.compile(contents, path) if path.end_with?(".rb")
    end
    assert_equal files, SumUpCodegen::Generator.new(spec).generate
  end

  def test_generated_output_matches_checked_in_files
    root = File.expand_path("..", __dir__)
    generator = SumUpCodegen::Generator.new(JSON.parse(File.read(File.join(root, "openapi.json"))))
    generator.write(root, check: true)
  end
end
