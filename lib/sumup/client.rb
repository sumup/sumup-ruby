# frozen_string_literal: true

require "uri"
require "json"
require "time"

module SumUp
  UNSET = Object.new.freeze

  # Per-call overrides. No configuration is changed on the shared Client.
  class RequestOptions
    attr_reader :headers, :api_key, :timeout, :open_timeout, :max_retries

    def initialize(headers: {}, api_key: nil, timeout: nil, open_timeout: nil, max_retries: nil)
      @headers = headers.to_h { |key, value| [key.to_s, value.to_s.dup.freeze] }.freeze
      @api_key = api_key&.dup&.freeze
      @timeout = timeout
      @open_timeout = open_timeout
      @max_retries = max_retries
    end

    def inspect
      "#<SumUp::RequestOptions>"
    end
  end

  # Decoded data plus status, headers, raw body, and request identifier.
  Response = Data.define(:data, :status, :headers, :body) do
    def request_id
      headers["x-request-id"] || headers["x-correlation-id"]
    end

    def inspect
      "#<SumUp::Response status=#{status}>"
    end
    alias_method :to_s, :inspect
  end

  class Client
    DEFAULT_BASE_URL = "https://api.sumup.com"
    RETRY_STATUSES = [408, 409, 429, 500, 502, 503, 504].freeze

    attr_reader :base_url

    # api_key accepts either an API key or an OAuth access token.
    # Retries default to zero, as they do in the other SumUp SDKs. Enabling
    # retries also retries writes: only opt in when the operation is safe to repeat.
    def initialize(api_key: nil, base_url: DEFAULT_BASE_URL, timeout: 60, open_timeout: 10,
      max_retries: 0, transport: NetHTTPTransport.new, headers: {}, sleeper: Kernel.method(:sleep))
      @base_url = base_url.to_s.delete_suffix("/").freeze
      uri = URI.parse(@base_url)
      unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
        raise ArgumentError, "base_url must be an HTTP(S) URL without credentials, query, or fragment"
      end
      @api_key = api_key&.dup&.freeze
      @timeout = positive(timeout, "timeout")
      @open_timeout = positive(open_timeout, "open_timeout")
      @max_retries = retries(max_retries)
      @transport = transport
      @headers = normalize_headers(headers).freeze
      @sleeper = sleeper
      @resources = self.class::RESOURCES.to_h { |name, klass| [name, klass.new(self)] }.freeze
    rescue URI::InvalidURIError
      raise ArgumentError, "invalid base_url"
    end

    def inspect
      "#<SumUp::Client>"
    end

    # Low-level escape hatch for API operations not yet present in this release.
    # Absolute URLs are accepted only for the client's configured API origin.
    def request(method:, path:, query: {}, body: UNSET, options: nil, response_type: nil, with_response: false)
      options = RequestOptions.new(**options) if options.is_a?(Hash)
      options ||= RequestOptions.new
      raise ArgumentError, "options must be RequestOptions or a Hash" unless options.is_a?(RequestOptions)
      uri = request_uri(path, query)
      headers = {
        "accept" => "application/problem+json, application/json",
        "content-type" => "application/json",
        "user-agent" => "sumup-ruby/#{VERSION} Ruby/#{RUBY_VERSION}"
      }
      headers["authorization"] = "Bearer #{@api_key}" if @api_key
      headers.merge!(@headers)
      headers["authorization"] = "Bearer #{options.api_key}" if options.api_key
      headers.merge!(normalize_headers(options.headers))
      message = Request.new(method: method.to_s.upcase, uri: uri, headers: headers.freeze,
        body: body.equal?(UNSET) ? nil : JSON.generate(Types.encode(body)),
        open_timeout: positive(options.open_timeout || @open_timeout, "open_timeout"),
        read_timeout: positive(options.timeout || @timeout, "timeout"),
        write_timeout: positive(options.timeout || @timeout, "timeout"))
      raw = perform(message, retries(options.max_retries || @max_retries))
      response_headers = normalize_headers(raw.headers).freeze
      response_type = response_type.fetch(raw.status) { [:union, response_type.values.uniq] } if response_type.is_a?(Hash)
      decoded = decode_body(raw, response_headers, response_type)
      unless (200...300).cover?(raw.status)
        error_class = (raw.status >= 500) ? InternalServerError : STATUS_ERRORS.fetch(raw.status, APIStatusError)
        raise error_class.new(status: raw.status, body: decoded, headers: response_headers)
      end
      data = Types.decode(decoded, response_type)
      with_response ? Response.new(data: data, status: raw.status, headers: response_headers, body: raw.body) : data
    end

    def events_handler(secret:, fallback:, &block)
      handler = EventsHandler.new(client: self, secret: secret, fallback: fallback)
      block&.call(handler)
      handler
    end

    def parse_event_notification_without_verification(body)
      Events.parse_without_verification(body, client: self)
    end

    private

    def positive(value, name)
      raise ArgumentError, "#{name} must be a positive finite number" unless value.is_a?(Numeric) && value.finite? && value.positive?
      value
    end

    def retries(value)
      raise ArgumentError, "max_retries must be a non-negative integer" unless value.is_a?(Integer) && value >= 0
      value
    end

    def normalize_headers(headers)
      headers.to_h { |key, value| [key.to_s.downcase, value.to_s.dup.freeze] }
    end

    def request_uri(path, query)
      candidate = URI.parse(path.to_s)
      uri = if candidate.absolute?
        origin = URI.parse(base_url)
        unless [candidate.scheme, candidate.hostname&.downcase, candidate.port] == [origin.scheme, origin.hostname&.downcase, origin.port]
          raise ArgumentError, "resource URL must use the configured API origin"
        end
        candidate
      else
        raise ArgumentError, "path must begin with a single slash" unless path.to_s.start_with?("/") && !path.to_s.start_with?("//")
        URI.parse(base_url + path.to_s)
      end
      raise ArgumentError, "resource URL cannot contain credentials or a fragment" if uri.userinfo || uri.fragment
      pairs = query.reject { |_, value| value.equal?(UNSET) }.flat_map do |key, value|
        Array(value).map { |item| [key.to_s, query_value(item)] }
      end
      uri.query = [uri.query, URI.encode_www_form(pairs)].reject { |part| part.nil? || part.empty? }.join("&")
      uri.query = nil if uri.query == ""
      uri
    rescue URI::InvalidURIError
      raise ArgumentError, "invalid resource URL"
    end

    def query_value(value)
      case value
      when String, Numeric, true, false then value.to_s
      when Time, Date, DateTime then value.iso8601
      else raise ArgumentError, "query values must be strings, numbers, booleans, dates, or arrays of those values"
      end
    end

    def perform(request, max_retries)
      attempt = 0
      loop do
        begin
          response = @transport.call(request)
          return response unless attempt < max_retries && RETRY_STATUSES.include?(response.status)
          delay = retry_delay(response.headers, attempt)
        rescue Timeout::Error
          raise APITimeoutError, "SumUp request timed out" if attempt >= max_retries
          delay = retry_delay({}, attempt)
        rescue IOError, SocketError, SystemCallError, OpenSSL::SSL::SSLError
          raise APIConnectionError, "Could not connect to the SumUp API" if attempt >= max_retries
          delay = retry_delay({}, attempt)
        end
        @sleeper.call(delay)
        attempt += 1
      end
    end

    def retry_delay(headers, attempt)
      value = normalize_headers(headers)["retry-after"]
      if value
        delay = parse_retry_after(value)
        return [delay, 60].min if delay&.finite? && delay >= 0
      end
      [0.5 * (2**[attempt, 7].min), 30].min * (0.75 + Random.rand * 0.25)
    end

    def parse_retry_after(value)
      Float(value, exception: false) || Time.httpdate(value) - Time.now
    rescue ArgumentError
      nil
    end

    def decode_body(raw, headers, response_type)
      return nil if [204, 205].include?(raw.status) || raw.body.nil? || raw.body.empty?
      unless headers.fetch("content-type", "").downcase.include?("json")
        if (200...300).cover?(raw.status) && response_type && !accepts_text?(response_type)
          raise InvalidResponseError, "SumUp returned a non-JSON response"
        end
        return raw.body
      end
      JSON.parse(raw.body)
    rescue JSON::ParserError
      return raw.body unless (200...300).cover?(raw.status)
      raise InvalidResponseError, "SumUp returned invalid JSON"
    end

    def accepts_text?(type)
      type == :string || type == :any || (type.is_a?(Array) && type.first == :union && type.last.any? { |variant| accepts_text?(variant) })
    end
  end
end
