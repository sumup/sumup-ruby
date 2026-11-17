<div align="center">

# SumUp Ruby SDK

[![RubyGems](https://img.shields.io/gem/v/sumup)](https://rubygems.org/gems/sumup)
[![CI](https://github.com/sumup/sumup-ruby/actions/workflows/ci.yaml/badge.svg)](https://github.com/sumup/sumup-ruby/actions/workflows/ci.yaml)
[![Ruby](https://img.shields.io/badge/Ruby-3.3%2B-ruby?logo=ruby)](sumup.gemspec)
[![Documentation](https://img.shields.io/badge/SumUp-documentation-white)](https://developer.sumup.com)
[![License](https://img.shields.io/github/license/sumup/sumup-ruby)](LICENSE)

</div>

Use the SumUp Ruby SDK to create checkouts, manage card readers, and access the
[SumUp API](https://developer.sumup.com/api/). Requires Ruby 3.3 or later.

## Installation

Add the SDK to your application's Gemfile:

```ruby
gem "sumup"
```

Then run `bundle install`.

## Usage

Create a [sandbox merchant](https://developer.sumup.com/online-payments/testing/)
and an [API key](https://developer.sumup.com/tools/authorization/api-keys/).
Set `SUMUP_API_KEY` and `SUMUP_MERCHANT_CODE` in your environment.

### Create a checkout

```ruby
require "sumup"
require "securerandom"

client = SumUp::Client.new(api_key: ENV.fetch("SUMUP_API_KEY"))

checkout = client.checkouts.create(
  body: {
    checkout_reference: SecureRandom.uuid,
    amount: 19.99,
    currency: "EUR",
    merchant_code: ENV.fetch("SUMUP_MERCHANT_CODE"),
    description: "Order 1234",
    hosted_checkout: {enabled: true}
  }
)

puts checkout.id
puts checkout.hosted_checkout_url
```

Send the customer to `hosted_checkout_url` to pay. Retrieve the checkout on your
server to verify its status before fulfilling the order. Keep credentials on your
server. Sandbox merchants use the same API URL as live merchants.

Pass request bodies through `body:` as a Hash or a model from `SumUp::Types`.
Response fields are available as Ruby methods or through `object["field_name"]`;
`to_h` preserves unknown fields and explicit nulls. RBS signatures are included.

### Accept a payment on a reader

Use a paired reader and the credentials required by the
[Cloud API](https://developer.sumup.com/terminal-payments/cloud-api/):

```ruby
result = client.readers.create_checkout(
  merchant_code: ENV.fetch("SUMUP_MERCHANT_CODE"),
  reader_id: ENV.fetch("SUMUP_READER_ID"),
  body: {
    total_amount: {currency: "EUR", minor_unit: 2, value: 1999},
    description: "Order 1234"
  }
)

puts result.data.client_transaction_id
```

Online checkout amounts use major units (`19.99` EUR); reader amounts use minor
units (`1999` cents). Starting a reader checkout does not confirm payment. Follow
its status notifications and verify the transaction through the API.

### Handle errors

```ruby
begin
  checkout = client.checkouts.get(checkout_id: "CHECKOUT_ID")
rescue SumUp::RateLimitError => error
  warn "Rate limited (HTTP #{error.status})"
rescue SumUp::APIError => error
  warn "API request failed (HTTP #{error.status}, request #{error.request_id})"
rescue SumUp::APIConnectionError => error
  warn "Connection failed: #{error.class}"
end
```

API errors expose `status`, `request_id`, and `body`, plus a typed `problem` when
returned by the API. Treat error bodies as sensitive data.

Every operation also has a `_with_response` variant for response metadata:

```ruby
response = client.checkouts.get_with_response(checkout_id: "CHECKOUT_ID")
puts response.status
puts response.request_id
checkout = response.data
```

### Paginate results

Use lazy enumerators for sales, sales search, transaction history, members, and
memberships. Pages are fetched as needed:

```ruby
client.transactions.each(
  merchant_code: ENV.fetch("SUMUP_MERCHANT_CODE"),
  statuses: ["SUCCESSFUL"]
).take(10).each { |transaction| puts transaction.transaction_code }
```

### Configure requests

Pass an OAuth access token through `api_key` to act on behalf of another merchant.
Your application owns authorization, token storage, and refresh; see the
[OAuth example](examples/oauth2/).

Override credentials, timeouts, or headers for an individual request:

```ruby
checkout = client.checkouts.get(
  checkout_id: "CHECKOUT_ID",
  options: {
    api_key: merchant_access_token,
    timeout: 15,
    headers: {"X-Correlation-ID" => "order-1234"}
  }
)
```

Defaults are a 10-second connection timeout, 60-second read/write timeouts, and
**zero automatic retries**. Set `max_retries` on the client or request to enable
retries for transient failures. Retries also apply to writes; enable them only
when the operation is safe to repeat.

### Handle signed events

Pass the unchanged request body and complete `X-SumUp-Webhook-Signature` header
to the handler:

```ruby
handler = client.events_handler(
  secret: ENV.fetch("SUMUP_WEBHOOK_SECRET"),
  fallback: ->(event) { warn "Unhandled event: #{event.type}" }
)

handler.on(SumUp::CheckoutPaidEvent::TYPE) do |event|
  checkout = event.fetch_object
  # Deduplicate by event.id and verify the checkout before fulfillment.
end

handler.handle(raw_request_body, signature: signature_header)
```

The handler verifies the signature before calling your callbacks. `fetch_object`
retrieves the resource's current state. Return 2xx after processing succeeds, 400
for invalid signatures or payloads, and 5xx for callback failures so delivery can
be retried. Callbacks must tolerate repeated and out-of-order deliveries.

Signed events are separate from legacy checkout `return_url` callbacks. See the
[Rack event receiver](examples/events/) for a complete route and the
[checkout webhook guide](https://developer.sumup.com/online-payments/webhooks/)
for legacy callbacks.

## Examples and documentation

- [Create a checkout](examples/checkout.rb)
- [Create a reader checkout](examples/card_reader_checkout.rb)
- [Connect a merchant with OAuth](examples/oauth2/)
- [Receive signed events](examples/events/)
- [API reference](https://developer.sumup.com/api/)
- [Contributing](CONTRIBUTING.md)

## Support

For bugs and feature requests, [open an issue](https://github.com/sumup/sumup-ruby/issues).
For integration help, contact [integration@sumup.com](mailto:integration@sumup.com).

## License

Licensed under [Apache 2.0](LICENSE).
