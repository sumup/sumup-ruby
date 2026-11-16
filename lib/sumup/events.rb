# frozen_string_literal: true

require "openssl"
require "json"
require "time"

module SumUp
  class EventError < Error; end
  class EventSignatureError < EventError; end
  class EventTimestampError < EventSignatureError; end
  class EventSignatureExpiredError < EventSignatureError; end
  class EventPayloadError < EventError; end
  class EventCallbackError < EventError; end
  class EventObjectURLError < EventError; end

  class EventNotification
    attr_reader :id, :type, :created_at, :object

    def initialize(payload, client:)
      @payload = payload
      @client = client
      @id = payload.fetch("id").freeze
      @type = payload.fetch("type").freeze
      @created_at = Time.iso8601(payload.fetch("created_at"))
      @object = Types::EventObject.new(payload.fetch("object"))
      freeze
    end

    # Fetches current resource state, which can differ from its state at event creation.
    def fetch_object(options: nil)
      raise EventObjectURLError, "unknown event resource type" unless self.class.const_defined?(:OBJECT_TYPE, false)
      @client.request(method: "GET", path: object.url, options: options, response_type: self.class::OBJECT_TYPE)
    rescue ArgumentError => error
      raise EventObjectURLError, "invalid event resource URL", cause: error
    end

    def to_h
      Types.encode(@payload)
    end

    def inspect
      "#<#{self.class} type=#{type.inspect}>"
    end
  end

  class UnknownEvent < EventNotification; end

  module Events
    SIGNATURE_HEADER = "X-SumUp-Webhook-Signature"
    TOLERANCE_SECONDS = 300

    class << self
      # The signing protocol matches the sibling SDKs, including the fixed
      # five-minute window in both directions and the exact v1:<timestamp>:<body> bytes.
      def verify_signature(secret:, body:, signature:)
        validate_secret(secret)
        raw = raw_body(body)
        raise EventSignatureError, "missing event signature header" unless signature.is_a?(String) && !signature.empty?
        fields = signature.strip.split(",", -1)
        timestamp_field = fields.first
        unless timestamp_field&.match?(/\At=[0-9]+\z/)
          raise EventTimestampError, "invalid signing timestamp"
        end
        timestamp_text = timestamp_field.delete_prefix("t=")
        timestamp = Integer(timestamp_text, 10)
        raise EventTimestampError, "invalid signing timestamp" if timestamp > (2**53 - 1)
        if (Time.now.to_i - timestamp).abs > TOLERANCE_SECONDS
          raise EventSignatureExpiredError, "event timestamp outside the five-minute window"
        end
        unless fields.size == 2 && fields.last.match?(/\Av1=[0-9a-fA-F]{64}\z/)
          raise EventSignatureError, "invalid event signature header"
        end
        expected = OpenSSL::HMAC.digest("SHA256", secret, "v1:#{timestamp_text}:".b + raw.b)
        supplied = [fields.last.delete_prefix("v1=")].pack("H*")
        unless OpenSSL.fixed_length_secure_compare(expected, supplied)
          raise EventSignatureError, "invalid event signature"
        end
        true
      end

      def parse(secret:, body:, signature:, client:)
        verify_signature(secret: secret, body: body, signature: signature)
        parse_without_verification(body, client: client)
      end

      # Only for data verified before storage in a trusted queue.
      def parse_without_verification(body, client:)
        payload = JSON.parse(raw_body(body))
        unless payload.is_a?(Hash) && %w[id type created_at].all? { |field| payload[field].is_a?(String) && !payload[field].empty? }
          raise EventPayloadError, "invalid event envelope"
        end
        reference = payload["object"]
        unless reference.is_a?(Hash) && %w[id type url].all? { |field| reference[field].is_a?(String) && !reference[field].empty? }
          raise EventPayloadError, "invalid event resource reference"
        end
        # Event timestamps must include a timezone, independently of signature time.
        unless payload["created_at"].match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
          raise EventPayloadError, "event created_at must include a timezone"
        end
        klass = TYPES.fetch(payload["type"], UnknownEvent)
        if klass != UnknownEvent && reference["type"] != klass::RESOURCE_TYPE
          raise EventPayloadError, "event resource type does not match event type"
        end
        klass.new(payload, client: client)
      rescue JSON::ParserError, ArgumentError => error
        raise EventPayloadError, "invalid event payload", cause: error
      end

      def validate_secret(secret)
        raise EventSignatureError, "event signing secret is required" unless secret.is_a?(String) && !secret.empty?
      end

      private

      def raw_body(body)
        raise EventPayloadError, "event body must be an unchanged String of request bytes" unless body.is_a?(String)
        utf8 = body.dup.force_encoding(Encoding::UTF_8)
        raise EventPayloadError, "event body is not valid UTF-8" unless utf8.valid_encoding?
        utf8
      end
    end
  end

  # Registration is synchronized; callbacks run without the registration lock held.
  class EventsHandler
    def initialize(client:, secret:, fallback:)
      Events.validate_secret(secret)
      raise ArgumentError, "fallback must be callable" unless fallback.respond_to?(:call)
      @client = client
      @secret = secret.dup.freeze
      @fallback = fallback
      @callbacks = {}
      @mutex = Mutex.new
    end

    def on(type, callback = nil, &block)
      callback ||= block
      raise ArgumentError, "callback must be callable" unless callback.respond_to?(:call)
      raise ArgumentError, "event type must be a nonempty String" unless type.is_a?(String) && !type.empty?
      @mutex.synchronize do
        raise ArgumentError, "event callback already registered: #{type}" if @callbacks.key?(type)
        @callbacks[type] = callback
      end
      self
    end

    def parse(body, signature:)
      Events.parse(secret: @secret, body: body, signature: signature, client: @client)
    end

    # Wait for this method to return before acknowledging a delivery. Make callback
    # effects idempotent; a delivery can be repeated or arrive out of order.
    def handle(body, signature:)
      event = parse(body, signature: signature)
      callback = @mutex.synchronize { @callbacks.fetch(event.type, @fallback) }
      begin
        callback.call(event)
      rescue => error
        raise EventCallbackError, "event callback failed", cause: error
      end
      event
    end

    def inspect
      "#<SumUp::EventsHandler>"
    end
  end
end
