# frozen_string_literal: true

require "sumup"
require "securerandom"

client = SumUp::Client.new(api_key: ENV.fetch("SUMUP_API_KEY"))
checkout = client.checkouts.create(
  body: {
    checkout_reference: SecureRandom.uuid,
    amount: 19.99,
    currency: "EUR",
    merchant_code: ENV.fetch("SUMUP_MERCHANT_CODE"),
    description: "Ruby SDK example",
    hosted_checkout: {enabled: true}
  }
)

puts "Checkout: #{checkout.id}"
puts "Payment page: #{checkout.hosted_checkout_url}"
