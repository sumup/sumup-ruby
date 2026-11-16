# frozen_string_literal: true

require "sumup"

module SumUpEventsExample
  MAX_BODY_SIZE = 1024 * 1024
  CLIENT = SumUp::Client.new(api_key: ENV.fetch("SUMUP_API_KEY"))
  HANDLER = CLIENT.events_handler(
    secret: ENV.fetch("SUMUP_WEBHOOK_SECRET"),
    fallback: ->(event) { warn "Unhandled event: #{event.type}" }
  )
  HANDLER.on(SumUp::CheckoutPaidEvent::TYPE) do |event|
    checkout = event.fetch_object
    puts "Verified checkout status: #{checkout.status}"
    # Persist event.id and your order update atomically before acknowledging.
  end

  def self.call(env)
    return [404, {}, []] unless env["PATH_INFO"] == "/webhooks/sumup" && env["REQUEST_METHOD"] == "POST"
    body = env.fetch("rack.input").read(MAX_BODY_SIZE + 1)
    return [413, {}, []] if body.bytesize > MAX_BODY_SIZE

    HANDLER.handle(body, signature: env["HTTP_X_SUMUP_WEBHOOK_SIGNATURE"])
    [204, {}, []]
  rescue SumUp::EventSignatureError, SumUp::EventPayloadError
    [400, {"content-type" => "text/plain"}, ["Invalid event."]]
  rescue SumUp::EventCallbackError
    [500, {"content-type" => "text/plain"}, ["Event processing failed."]]
  end
end
