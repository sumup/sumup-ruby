# frozen_string_literal: true

require "net/http"
require "openssl"

module SumUp
  # Request passed to custom transports. Headers can contain credentials.
  Request = Data.define(:method, :uri, :headers, :body, :open_timeout, :read_timeout, :write_timeout) do
    def inspect
      "#<SumUp::Request method=#{method}>"
    end
    alias_method :to_s, :inspect
  end

  # Transport response, before JSON decoding. Header names are normalized by Client.
  HTTPResponse = Data.define(:status, :headers, :body) do
    def inspect
      "#<SumUp::HTTPResponse status=#{status}>"
    end
    alias_method :to_s, :inspect
  end

  class NetHTTPTransport
    def call(request)
      uri = request.uri
      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = request.open_timeout
      http.read_timeout = request.read_timeout
      http.write_timeout = request.write_timeout
      # Retry policy belongs to Client, including the decision to retry writes.
      http.max_retries = 0
      message = Net::HTTPGenericRequest.new(request.method, !request.body.nil?, true, uri.request_uri, request.headers)
      message.body = request.body
      response = http.start { |connection| connection.request(message) }
      HTTPResponse.new(status: response.code.to_i, headers: response.to_hash.transform_values { |values| values.join(", ") }, body: response.body.to_s)
    end
  end
end
