# frozen_string_literal: true

require_relative "test_helper"

class SamplesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CATALOG = JSON.parse(File.read(File.join(ROOT, "code-samples.json")))
  SPEC = JSON.parse(File.read(File.join(ROOT, "openapi.json")))

  def test_catalog_uses_the_shared_sdk_sample_format
    assert_equal 1, CATALOG.fetch("schemaVersion")
    assert_equal "ruby", CATALOG.fetch("language")
    assert_equal({"module" => "sumup", "version" => SumUp::VERSION}, CATALOG.fetch("sdk"))
    expected = SPEC.fetch("paths").values.flat_map { |item| item.values.filter_map { |operation| operation["operationId"] if operation.is_a?(Hash) } }
    assert_equal expected.sort, CATALOG.fetch("samples").map { |sample| sample.fetch("operationId") }.uniq.sort
    assert_operator CATALOG.fetch("samples").size, :>, expected.size
  end

  CATALOG.fetch("samples").each do |sample|
    define_method("test_#{sample.fetch("id").gsub(/\W/, "_")}") do
      operation = SPEC.fetch("paths").fetch(sample.fetch("path")).fetch(sample.fetch("httpMethod").downcase)
      status = operation.fetch("responses").keys.find { |code| code.start_with?("2") }.to_i
      @test_client = build_client(json_response({}, status: status))
      code = sample.fetch("sample").sub('SumUp::Client.new(api_key: ENV.fetch("SUMUP_API_KEY"))', "TEST_CLIENT")
      namespace = Module.new
      namespace.const_set(:TEST_CLIENT, @test_client)
      namespace.module_eval(code, sample.fetch("id"), 1)
      request = @transport.requests.fetch(0)
      assert_equal sample.fetch("httpMethod"), request.method
      template = Regexp.escape(sample.fetch("path")).gsub(/\\\{[^}]+\\\}/, "[^/]+")
      assert_match(/\A#{template}\z/, request.uri.path)
      assert_equal 1, @transport.requests.size
      assert_equal "Bearer test-key", request.headers.fetch("authorization")
    end
  end
end
