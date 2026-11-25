# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class ExamplesTest < Minitest::Test
  def run_example(name, response)
    @example_client = build_client(response)
    program = File.read(File.expand_path("../examples/#{name}.rb", __dir__))
      .sub('SumUp::Client.new(api_key: ENV.fetch("SUMUP_API_KEY"))', "TEST_CLIENT")
      .gsub('ENV.fetch("SUMUP_MERCHANT_CODE")', '"M123"')
      .gsub('ENV.fetch("SUMUP_READER_ID")', '"reader-1"')
    namespace = Module.new
    namespace.const_set(:TEST_CLIENT, @example_client)
    output, = capture_io { namespace.module_eval(program, name, 1) }
    output
  end

  def test_hosted_checkout_example
    output = run_example("checkout", json_response({"id" => "checkout-1", "hosted_checkout_url" => "https://checkout.sumup.com/pay/example"}, status: 201))
    assert_includes output, "Checkout: checkout-1"
    assert_equal({"enabled" => true}, JSON.parse(@transport.requests.last.body).fetch("hosted_checkout"))
  end

  def test_reader_checkout_example
    output = run_example("card_reader_checkout", json_response({"data" => {"client_transaction_id" => "transaction-1"}}, status: 201))
    assert_includes output, "Reader checkout started: transaction-1"
    assert_equal({"currency" => "EUR", "value" => 1999}, JSON.parse(@transport.requests.last.body).fetch("total_amount"))
  end

  def test_rack_example_rejects_invalid_requests_and_processes_verified_events
    @example_client = build_client(json_response({"id" => "checkout", "status" => "PAID"}))
    program = File.read(File.expand_path("../examples/events/app.rb", __dir__))
      .sub('SumUp::Client.new(api_key: ENV.fetch("SUMUP_API_KEY"))', "TEST_CLIENT")
      .sub('ENV.fetch("SUMUP_WEBHOOK_SECRET")', '"example-secret"')
    # Evaluate the application in an isolated namespace; no Rack server is started.
    namespace = Module.new
    namespace.const_set(:TEST_CLIENT, @example_client)
    namespace.module_eval(program, "examples/events/app.rb", 1)
    app = namespace.const_get(:SumUpEventsExample)
    body = JSON.generate({"id" => "event", "type" => "checkouts.paid", "created_at" => "2026-01-01T00:00:00Z",
                          "object" => {"id" => "checkout", "type" => "checkout", "url" => "https://api.sumup.com/v0.1/checkouts/checkout"}})
    env = {"PATH_INFO" => "/webhooks/sumup", "REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(body)}
    assert_equal 400, app.call(env).first
    env["rack.input"] = StringIO.new("x" * (1024 * 1024 + 1))
    assert_equal 413, app.call(env).first
    timestamp = Time.now.to_i
    digest = OpenSSL::HMAC.hexdigest("SHA256", "example-secret", "v1:#{timestamp}:#{body}")
    env["HTTP_X_SUMUP_WEBHOOK_SIGNATURE"] = "t=#{timestamp},v1=#{digest}"
    env["rack.input"] = StringIO.new(body)
    capture_io { assert_equal 204, app.call(env).first }
    assert_equal 1, @transport.requests.size
  end
end
