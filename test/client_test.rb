# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  def test_checkout_creation_uses_bearer_auth_and_typed_response
    client = build_client(json_response({"id" => "checkout_1", "status" => "PENDING", "new_field" => false}, status: 201))
    result = client.checkouts.create(amount: 10.5, currency: "EUR", merchant_code: "M123", checkout_reference: "order-1")
    assert_instance_of SumUp::Types::Checkout, result
    assert_equal "checkout_1", result.id
    assert_equal false, result["new_field"]
    request = @transport.requests.fetch(0)
    assert_equal "POST", request.method
    assert_equal "https://api.sumup.com/v0.1/checkouts", request.uri.to_s
    assert_equal "Bearer test-key", request.headers.fetch("authorization")
    assert_match(/sumup-ruby\/#{Regexp.escape(SumUp::VERSION)}/, request.headers.fetch("user-agent"))
    assert_equal 10.5, JSON.parse(request.body).fetch("amount")
  end

  def test_model_request_body_retains_explicit_null
    client = build_client(json_response)
    body = SumUp::Types::CheckoutUpdateRequest.new(valid_until: nil)
    client.checkouts.update(checkout_id: "one", body: body)
    assert_equal({"valid_until" => nil}, JSON.parse(@transport.requests.last.body))
  end

  def test_body_and_keywords_are_mutually_exclusive
    client = build_client
    assert_raises(ArgumentError) { client.checkouts.create(body: {}, amount: 1) }
    assert_empty @transport.requests
  end

  def test_missing_required_body_fails_before_a_request
    client = build_client
    assert_raises(ArgumentError) { client.checkouts.create }
    assert_empty @transport.requests
  end

  def test_optional_body_can_be_omitted_for_a_full_refund
    client = build_client(json_response)
    client.transactions.refund(merchant_code: "M123", transaction_id: "one")
    assert_nil @transport.requests.last.body
  end

  def test_body_with_no_required_fields_can_be_empty
    client = build_client(json_response)
    client.checkouts.update(checkout_id: "one")
    assert_equal "{}", @transport.requests.last.body
  end

  def test_path_parameters_are_encoded_as_single_segments
    client = build_client(json_response)
    client.readers.get(merchant_code: "M /?#", reader_id: "r/1 +")
    assert_equal "/v0.1/merchants/M%20%2F%3F%23/readers/r%2F1%20%2B", @transport.requests.last.uri.path
  end

  def test_empty_path_parameters_are_rejected
    client = build_client
    [nil, ""].each { |id| assert_raises(ArgumentError) { client.checkouts.get(checkout_id: id) } }
  end

  def test_queries_use_wire_names_repeated_values_and_false
    client = build_client(json_response, json_response)
    client.transactions.list(merchant_code: "M123", users: ["a+b@example.com", "second"], statuses: ["FAILED"])
    assert_equal [["users[]", "a+b@example.com"], ["users[]", "second"], ["statuses[]", "FAILED"]], URI.decode_www_form(@transport.requests.last.uri.query)
    client.memberships.list(resource_attributes_sandbox: false, resource_id: "merchant/1")
    assert_equal [["resource.attributes.sandbox", "false"], ["resource.id", "merchant/1"]], URI.decode_www_form(@transport.requests.last.uri.query)
  end

  def test_request_options_override_auth_headers_and_timeouts_without_mutating_client
    client = build_client(json_response, json_response)
    client.checkouts.get(checkout_id: "one", options: {api_key: "merchant-token", headers: {"X-Trace" => "trace"}, timeout: 5, open_timeout: 2})
    request = @transport.requests.last
    assert_equal "Bearer merchant-token", request.headers.fetch("authorization")
    assert_equal "trace", request.headers.fetch("x-trace")
    assert_equal 5, request.read_timeout
    assert_equal 5, request.write_timeout
    assert_equal 2, request.open_timeout
    client.checkouts.get(checkout_id: "two")
    assert_equal "Bearer test-key", @transport.requests.last.headers.fetch("authorization")
    refute @transport.requests.last.headers.key?("x-trace")
  end

  def test_header_parameters_and_request_headers_are_merged
    client = build_client(json_response)
    client.readers.get(merchant_code: "M123", reader_id: "r1", if_modified_since: "date", options: {headers: {"X-Test" => "yes"}})
    assert_equal "date", @transport.requests.last.headers.fetch("if-modified-since")
    assert_equal "yes", @transport.requests.last.headers.fetch("x-test")
  end

  def test_with_response_preserves_metadata_and_raw_body
    client = build_client(json_response({"id" => "one"}, headers: {"X-Request-ID" => "request-1"}))
    response = client.checkouts.get_with_response(checkout_id: "one")
    assert_equal 200, response.status
    assert_equal "request-1", response.request_id
    assert_equal "one", response.data.id
    assert_equal({"id" => "one"}, JSON.parse(response.body))
  end

  def test_csv_exports_are_returned_as_strings
    csv = "id,amount\n1,2.50\n"
    client = build_client(SumUp::HTTPResponse.new(status: 200, headers: {"content-type" => "text/plain"}, body: csv))
    assert_equal csv, client.payouts.list(merchant_code: "M123", start_date: "2026-01-01", end_date: "2026-01-31", format: "csv")
  end

  def test_empty_response_is_nil
    client = build_client(SumUp::HTTPResponse.new(status: 204, headers: {}, body: ""))
    assert_nil client.customers.deactivate_payment_instrument(customer_id: "one", token: "token")
  end

  def test_success_status_selects_the_corresponding_checkout_model
    client = build_client(json_response({"next_step" => {"url" => "https://example.com", "method" => "POST"}}, status: 202))
    result = client.checkouts.process(checkout_id: "one", payment_type: "card")
    assert_instance_of SumUp::Types::CheckoutAccepted, result
    assert_equal "POST", result.next_step.method_value
  end

  def test_errors_retain_problem_details_and_legacy_bodies
    client = build_client(json_response({"type" => "https://example.com/problem", "title" => "Denied", "detail" => "private detail", "extension" => 1}, status: 403, headers: {"x-request-id" => "req"}))
    error = assert_raises(SumUp::PermissionDeniedError) { client.checkouts.get(checkout_id: "one") }
    assert_equal 403, error.status
    assert_equal "req", error.request_id
    assert_instance_of SumUp::Types::Problem, error.problem
    assert_equal "private detail", error.problem.detail
    assert_equal 1, error.body.fetch("extension")
    refute_includes error.message, "private detail"
  end

  def test_non_json_and_malformed_error_bodies_are_preserved
    ["text/plain", "application/json"].each do |type|
      client = build_client(SumUp::HTTPResponse.new(status: 502, headers: {"content-type" => type}, body: "gateway error"))
      error = assert_raises(SumUp::InternalServerError) { client.checkouts.get(checkout_id: "one") }
      assert_equal "gateway error", error.body
    end
  end

  def test_invalid_success_json_is_a_distinct_error
    client = build_client(SumUp::HTTPResponse.new(status: 200, headers: {"content-type" => "application/json"}, body: "{"))
    error = assert_raises(SumUp::InvalidResponseError) { client.checkouts.get(checkout_id: "one") }
    assert_instance_of JSON::ParserError, error.cause
  end

  def test_html_success_response_cannot_masquerade_as_an_api_object
    client = build_client(SumUp::HTTPResponse.new(status: 200, headers: {"content-type" => "text/html"}, body: "<h1>Proxy error</h1>"))
    assert_raises(SumUp::InvalidResponseError) { client.checkouts.get(checkout_id: "one") }
  end

  def test_error_bodies_preserve_all_json_value_shapes
    [[{"field" => "amount"}], "legacy error", 12, false, nil].each do |body|
      client = build_client(json_response(body, status: 400))
      error = assert_raises(SumUp::BadRequestError) { client.checkouts.get(checkout_id: "one") }
      body.nil? ? assert_nil(error.body) : assert_equal(body, error.body)
    end
  end

  def test_per_request_key_takes_precedence_over_default_authorization_header
    client = build_client(json_response, headers: {"Authorization" => "Bearer default"})
    client.checkouts.get(checkout_id: "one", options: {api_key: "override"})
    assert_equal "Bearer override", @transport.requests.last.headers.fetch("authorization")
  end

  def test_client_snapshots_credentials_and_header_values
    key = +"test-key"
    trace = +"trace"
    client = build_client(json_response, api_key: key, headers: {"X-Test" => trace})
    key.replace("changed")
    trace.replace("changed")
    client.checkouts.get(checkout_id: "one")
    assert_equal "Bearer test-key", @transport.requests.last.headers.fetch("authorization")
    assert_equal "trace", @transport.requests.last.headers.fetch("x-test")
  end

  def test_http_errors_are_typed
    {400 => SumUp::BadRequestError, 401 => SumUp::AuthenticationError, 404 => SumUp::NotFoundError,
     409 => SumUp::ConflictError, 422 => SumUp::UnprocessableEntityError, 429 => SumUp::RateLimitError,
     418 => SumUp::APIStatusError, 503 => SumUp::InternalServerError}.each do |status, klass|
      client = build_client(json_response(status: status))
      assert_raises(klass) { client.checkouts.get(checkout_id: "one") }
    end
  end

  def test_retries_are_disabled_by_default_including_writes
    client = build_client(json_response(status: 503), json_response)
    assert_raises(SumUp::InternalServerError) { client.checkouts.create(body: {}) }
    assert_equal 1, @transport.requests.size
  end

  def test_opt_in_retries_honor_retry_after_and_reuse_request
    delays = []
    client = build_client(json_response(status: 429, headers: {"Retry-After" => "2"}), json_response({"id" => "one"}, status: 201), max_retries: 1, sleeper: delays.method(:push))
    assert_equal "one", client.checkouts.create(body: {}).id
    assert_equal [2.0], delays
    assert_same @transport.requests.first, @transport.requests.last
  end

  def test_nonretryable_errors_are_not_retried
    client = build_client(json_response(status: 401), max_retries: 2)
    assert_raises(SumUp::AuthenticationError) { client.checkouts.get(checkout_id: "one") }
    assert_equal 1, @transport.requests.size
  end

  def test_request_retry_override_can_disable_client_retries
    client = build_client(json_response(status: 503), max_retries: 3)
    assert_raises(SumUp::InternalServerError) { client.checkouts.get(checkout_id: "one", options: {max_retries: 0}) }
    assert_equal 1, @transport.requests.size
  end

  def test_connection_errors_and_timeouts_keep_their_causes
    [[SocketError.new("failure"), SumUp::APIConnectionError], [Net::ReadTimeout.new, SumUp::APITimeoutError]].each do |cause, klass|
      client = build_client(cause)
      error = assert_raises(klass) { client.checkouts.get(checkout_id: "one") }
      assert_same cause, error.cause
    end
  end

  def test_network_retry_is_bounded
    delays = []
    client = build_client(SocketError.new, SocketError.new, max_retries: 1, sleeper: delays.method(:push))
    assert_raises(SumUp::APIConnectionError) { client.checkouts.get(checkout_id: "one") }
    assert_equal 2, @transport.requests.size
    assert_equal 1, delays.size
  end

  def test_credentials_never_follow_redirects_or_foreign_resource_urls
    client = build_client(SumUp::HTTPResponse.new(status: 302, headers: {"location" => "https://evil.example"}, body: ""))
    assert_raises(SumUp::APIStatusError) { client.checkouts.get(checkout_id: "one") }
    ["https://evil.example/a", "https://api.sumup.com.evil.example/a", "http://api.sumup.com/a", "//evil.example/a", "https://user@api.sumup.com/a"].each do |path|
      assert_raises(ArgumentError) { client.request(method: "GET", path: path) }
    end
    assert_equal 1, @transport.requests.size
  end

  def test_invalid_configuration_is_rejected
    [{timeout: 0}, {timeout: Float::NAN}, {max_retries: -1}, {max_retries: 0.5}, {base_url: "file:///tmp/key"}, {base_url: "https://user:secret@example.com"}].each do |options|
      assert_raises(ArgumentError) { SumUp::Client.new(**options) }
    end
  end

  def test_client_configuration_has_no_global_cross_tenant_state
    transports = [FakeTransport.new(json_response), FakeTransport.new(json_response)]
    clients = transports.each_with_index.map { |transport, index| SumUp::Client.new(api_key: "tenant-#{index}", transport: transport) }
    clients.map { |client| Thread.new { client.checkouts.get(checkout_id: "one") } }.each(&:value)
    assert_equal ["Bearer tenant-0", "Bearer tenant-1"], transports.map { |transport| transport.requests.last.headers.fetch("authorization") }
  end

  def test_inspection_does_not_disclose_credentials_or_payment_payloads
    client = build_client(json_response({"id" => "private-customer"}))
    response = client.checkouts.get_with_response(checkout_id: "private-checkout")
    values = [client, client.checkouts, @transport.requests.last, response, response.data, SumUp::RequestOptions.new(api_key: "test-key")]
    values.each do |value|
      refute_match(/test-key|private-customer|private-checkout/, value.inspect)
      refute_match(/test-key|private-customer|private-checkout/, value.to_s)
    end
  end
end
