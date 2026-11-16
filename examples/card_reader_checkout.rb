# frozen_string_literal: true

require "sumup"

client = SumUp::Client.new(api_key: ENV.fetch("SUMUP_API_KEY"))
result = client.readers.create_checkout(
  merchant_code: ENV.fetch("SUMUP_MERCHANT_CODE"),
  reader_id: ENV.fetch("SUMUP_READER_ID"),
  total_amount: {currency: "EUR", minor_unit: 2, value: 1999},
  description: "Ruby SDK example"
)

puts "Reader checkout started: #{result.data.client_transaction_id}"
puts "Verify the final transaction through its notification and the API."
