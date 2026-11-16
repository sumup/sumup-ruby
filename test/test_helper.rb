# frozen_string_literal: true

require "minitest/autorun"
require "sumup"

class FakeTransport
  attr_reader :requests

  def initialize(*responses, &handler)
    @responses = responses
    @handler = handler
    @requests = []
  end

  def call(request)
    @requests << request
    response = @handler ? @handler.call(request) : @responses.shift
    raise response if response.is_a?(Exception)
    raise "unexpected HTTP request" unless response
    response
  end
end

module TestResponses
  def json_response(value = {}, status: 200, headers: {})
    SumUp::HTTPResponse.new(status: status, headers: {"content-type" => "application/json"}.merge(headers), body: JSON.generate(value))
  end

  def build_client(*responses, **options, &handler)
    @transport = FakeTransport.new(*responses, &handler)
    SumUp::Client.new(api_key: "test-key", transport: @transport, **options)
  end
end

class Minitest::Test
  include TestResponses
end
