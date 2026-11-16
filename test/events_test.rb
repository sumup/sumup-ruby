# frozen_string_literal: true

require_relative "test_helper"

class EventsTest < Minitest::Test
  def setup
    @client = build_client(json_response({"id" => "member", "status" => "active"}))
    @secret = "test-signing-secret"
    @body = JSON.generate({
      "id" => "event-1", "type" => "members.updated", "created_at" => "2026-01-01T12:00:00Z",
      "object" => {"id" => "member", "type" => "member", "url" => "https://api.sumup.com/v0.1/merchants/M123/members/member"}
    })
  end

  def signature(body = @body, timestamp: Time.now.to_i.to_s)
    digest = OpenSSL::HMAC.hexdigest("SHA256", @secret, "v1:#{timestamp}:".b + body.b)
    "t=#{timestamp},v1=#{digest}"
  end

  def parse(body = @body, header: signature(body))
    SumUp::Events.parse(secret: @secret, body: body, signature: header, client: @client)
  end

  def test_verified_event_has_typed_metadata_and_resource_fetching
    event = parse
    assert_instance_of SumUp::MemberUpdatedEvent, event
    assert_equal "event-1", event.id
    assert_equal Time.utc(2026, 1, 1, 12), event.created_at
    assert_equal "member", event.object.id
    assert_empty @transport.requests
    assert_instance_of SumUp::Types::Member, event.fetch_object
    assert_equal "Bearer test-key", @transport.requests.last.headers.fetch("authorization")
  end

  def test_signature_uses_exact_raw_bytes_and_timestamp_spelling
    header = signature(@body, timestamp: "0#{Time.now.to_i}")
    assert parse(header: header)
    assert_raises(SumUp::EventSignatureError) { parse(@body + " ", header: header) }
  end

  def test_signature_accepts_binary_utf8_input_and_uppercase_hex
    body = @body.sub("event-1", "event-é").b
    header = signature(body)
    prefix, digest = header.split("v1=")
    assert_equal "event-é", parse(body, header: prefix + "v1=" + digest.upcase).id
  end

  def test_invalid_utf8_is_rejected
    body = "\xff".b
    assert_raises(SumUp::EventPayloadError) { parse(body, header: signature(body)) }
  end

  def test_old_and_future_signing_timestamps_are_rejected
    [-301, 301].each do |offset|
      assert_raises(SumUp::EventSignatureExpiredError) { parse(header: signature(timestamp: (Time.now.to_i + offset).to_s)) }
    end
  end

  def test_missing_and_malformed_signature_headers_are_rejected
    [nil, "", "v1=abc", "t=abc,v1=abc", "t=-1,v1=abc", "t=#{2**53},v1=abc"].each do |header|
      assert_raises(SumUp::EventSignatureError) { parse(header: header) }
    end
    ["t=#{Time.now.to_i}", "t=#{Time.now.to_i},v1=abc", "#{signature},extra=bad"].each do |header|
      assert_raises(SumUp::EventSignatureError) { parse(header: header) }
    end
  end

  def test_wrong_secret_is_rejected
    assert_raises(SumUp::EventSignatureError) { SumUp::Events.verify_signature(secret: "wrong", body: @body, signature: signature) }
    assert_raises(SumUp::EventSignatureError) { SumUp::Events.verify_signature(secret: "", body: @body, signature: signature) }
  end

  def test_envelope_is_validated_after_signature_verification
    ["{", "null", "[]", "{}", @body.sub("2026-01-01T12:00:00Z", "2026-01-01T12:00:00"), @body.sub('"type":"member"', '"type":"reader"')].each do |body|
      assert_raises(SumUp::EventPayloadError) { parse(body) }
    end
  end

  def test_unknown_events_preserve_data_and_use_fallback
    body = @body.sub("members.updated", "future.created")
    received = []
    handler = @client.events_handler(secret: @secret, fallback: received.method(:push))
    event = handler.handle(body, signature: signature(body))
    assert_instance_of SumUp::UnknownEvent, event
    assert_equal JSON.parse(body), event.to_h
    assert_same event, received.first
    assert_raises(SumUp::EventObjectURLError) { event.fetch_object }
  end

  def test_dispatch_waits_for_callback_and_does_not_call_fallback
    received = []
    handler = @client.events_handler(secret: @secret, fallback: ->(_) { flunk "fallback called" })
    assert_same handler, handler.on(SumUp::MemberUpdatedEvent::TYPE) { |event| received << event.id }
    handler.handle(@body, signature: signature)
    assert_equal ["event-1"], received
    assert_raises(ArgumentError) { handler.on("members.updated") { |_| } }
  end

  def test_callback_failures_have_a_separate_error_and_cause
    cause = RuntimeError.new("processing failed")
    handler = @client.events_handler(secret: @secret, fallback: ->(_) { raise cause })
    error = assert_raises(SumUp::EventCallbackError) { handler.handle(@body, signature: signature) }
    assert_same cause, error.cause
  end

  def test_invalid_events_never_call_callbacks
    called = false
    handler = @client.events_handler(secret: @secret, fallback: ->(_) { called = true })
    assert_raises(SumUp::EventSignatureError) { handler.handle(@body, signature: "") }
    refute called
  end

  def test_resource_urls_cannot_send_credentials_to_other_origins
    body = @body.sub("https://api.sumup.com/", "https://attacker.example/")
    event = parse(body)
    assert_raises(SumUp::EventObjectURLError) { event.fetch_object }
    assert_empty @transport.requests
  end

  def test_unverified_queue_parser_is_explicit
    event = @client.parse_event_notification_without_verification(@body)
    assert_instance_of SumUp::MemberUpdatedEvent, event
    assert_equal "event-1", event.id
  end

  def test_configuration_and_inspection
    assert_raises(ArgumentError) { @client.events_handler(secret: @secret, fallback: nil) }
    handler = @client.events_handler(secret: @secret, fallback: ->(_) {})
    assert_raises(ArgumentError) { handler.on("members.updated") }
    refute_includes handler.inspect, @secret
    refute_includes parse.inspect, "event-1"
  end
end
