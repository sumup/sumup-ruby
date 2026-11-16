# frozen_string_literal: true

require_relative "test_helper"

class TransportTest < Minitest::Test
  class Connection
    attr_accessor :use_ssl, :verify_mode, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :message

    def start
      yield self
    end

    def request(message)
      @message = message
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response["content-type"] = "application/json"
      response.body = '{"id":"checkout"}'
      response.instance_variable_set(:@read, true)
      response
    end
  end

  def test_default_transport_builds_http_request_and_disables_hidden_retries
    connection = Connection.new
    original = Net::HTTP.method(:new)
    arguments = nil
    Net::HTTP.singleton_class.remove_method(:new)
    Net::HTTP.define_singleton_method(:new) do |*values|
      arguments = values
      connection
    end
    begin
      client = SumUp::Client.new(api_key: "key", timeout: 20, open_timeout: 3)
      result = client.checkouts.get(checkout_id: "one")
      assert_equal "checkout", result.id
      assert_equal ["api.sumup.com", 443], arguments
      assert connection.use_ssl
      assert_equal OpenSSL::SSL::VERIFY_PEER, connection.verify_mode
      assert_equal 0, connection.max_retries
      assert_equal 3, connection.open_timeout
      assert_equal 20, connection.read_timeout
      assert_equal 20, connection.write_timeout
      assert_equal "GET", connection.message.method
      assert_equal "/v0.1/checkouts/one", connection.message.path
      assert_equal "Bearer key", connection.message["authorization"]
    ensure
      Net::HTTP.singleton_class.remove_method(:new)
      Net::HTTP.define_singleton_method(:new, original)
    end
  end
end
