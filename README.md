# SumUp Ruby SDK

Ruby client for the [SumUp API](https://developer.sumup.com/api/), with generated
resource methods, models, RBS signatures, and signed event handling.

Requires Ruby 3.3 or later. The CI matrix targets Ruby 3.3, 3.4, and 4.0.

This SDK has not been published yet. To use the local checkout, add it to your
application's Gemfile:

```ruby
gem "sumup", path: "../sumup-ruby"
```

After the first release, install it from RubyGems:

```ruby
gem "sumup", "~> 0.1"
```

## Create a checkout

Create a [sandbox merchant](https://developer.sumup.com/online-payments/testing/)
and an [API key](https://developer.sumup.com/tools/authorization/api-keys/).

```ruby
require "sumup"
require "securerandom"

client = SumUp::Client.new(api_key: ENV.fetch("SUMUP_API_KEY"))

checkout = client.checkouts.create(
  checkout_reference: SecureRandom.uuid,
  amount: 19.99,
  currency: "EUR",
  merchant_code: ENV.fetch("SUMUP_MERCHANT_CODE"),
  description: "Order 1234",
  hosted_checkout: {enabled: true}
)

puts checkout.id
puts checkout.hosted_checkout_url
```

The result contains the checkout ID and, when Hosted Checkout is enabled, its
payment-page URL. Use [Hosted Checkout or the Payment Widget](https://developer.sumup.com/online-payments/checkouts/)
to collect payment details. Retrieve the checkout on your server to verify its
status before fulfilling an order. Keep API keys and OAuth tokens on your server.

The sandbox uses `https://api.sumup.com` too; the authenticated merchant determines
whether a payment uses sandbox or real funds.

## Resources

The client exposes `checkouts`, `customers`, `transactions`, `payouts`, `receipts`,
`readers`, `memberships`, `members`, `roles`, `merchants`, `sales`, and `tokens`.
Methods follow the resource naming used by the other SumUp SDKs, such as
`checkouts.create`, `transactions.refund`, and `readers.create_checkout`.

Pass request bodies as keyword arguments, a Hash, or a generated request model:

```ruby
request = SumUp::Types::CheckoutUpdateRequest.new(description: "Updated order")
checkout = client.checkouts.update(checkout_id: checkout.id, body: request)
```

Use keyword arguments for path and query parameters. Array query parameters
are encoded with their API names, including repeated `statuses[]` values:

```ruby
page = client.transactions.list(
  merchant_code: ENV.fetch("SUMUP_MERCHANT_CODE"),
  statuses: ["SUCCESSFUL", "REFUNDED"],
  limit: 20
)
page.items.each { |transaction| puts transaction.transaction_code }
```

API objects live under `SumUp::Types`. Access their fields with Ruby methods or
`object["wire_name"]`; `to_h` and `to_json` retain unknown fields and explicit
nulls. `key?` distinguishes omitted fields from null values. Fields that conflict
with Ruby object methods have a `_value` suffix, such as `next_step.method_value`.
Known enum constants are strings, such as `SumUp::Types::Currency::EUR`; new API
enum values remain valid strings. Dates and timestamps in responses remain
strings as supplied by the API. Amount units follow each API's contract: online
checkout amounts use major units, while reader checkout amounts use minor units.

## Accept a payment on a reader

Use a paired reader and the credentials required by the
[Cloud API](https://developer.sumup.com/terminal-payments/cloud-api/):

```ruby
result = client.readers.create_checkout(
  merchant_code: ENV.fetch("SUMUP_MERCHANT_CODE"),
  reader_id: ENV.fetch("SUMUP_READER_ID"),
  total_amount: {currency: "EUR", minor_unit: 2, value: 1999},
  description: "Order 1234"
)

puts result.data.client_transaction_id
```

Starting a reader checkout does not mean the payment succeeded. Follow its
status notifications and verify the transaction through the API.

## Pagination

Single-page methods return the API's page object. Lazy enumerators are available
for sales, sales search, transaction history, members, and memberships:

```ruby
client.sales.each(merchant_code: ENV.fetch("SUMUP_MERCHANT_CODE")) do |sale|
  puts sale.id
end

client.transactions.each(
  merchant_code: ENV.fetch("SUMUP_MERCHANT_CODE"),
  statuses: ["SUCCESSFUL"]
).take(10)
```

`sales.search_each` accepts the same arguments as `sales.search`. Enumeration
fetches pages only as needed and preserves pagination references. Endpoints
without a documented continuation mechanism expose their single-page method.

## OAuth and request options

Pass an OAuth access token through `api_key` when acting on behalf of another
merchant. Use an established OAuth library for authorization, token storage, and
refresh; the SDK does not manage OAuth sessions. See the
[runnable OAuth example](examples/oauth2/README.md).

Configure clients independently; the SDK has no global merchant credentials.
Per-request overrides leave the shared client unchanged:

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

Client defaults are a 10-second connection timeout, 60-second read/write
timeouts, and **zero automatic retries**. You can set `max_retries` on the client
or request options to retry connection failures, timeouts, and transient HTTP
responses (408, 409, 429, 500, 502, 503, 504), with exponential backoff and jitter.
`Retry-After` is honored up to 60 seconds. Enabling retries applies to writes too:
enable them only when the operation is safe to repeat. An arbitrary idempotency
header does not make an unsupported API operation idempotent.

For proxies, instrumentation, or tests, pass a `transport:` object implementing
`call(SumUp::Request) -> SumUp::HTTPResponse`. The default uses Net::HTTP with
certificate verification and no additional transport-level retries. Responses
are read fully into memory, including CSV payout exports. Redirects are not followed.

## Response metadata and errors

Every operation has a `_with_response` variant:

```ruby
response = client.checkouts.get_with_response(checkout_id: "CHECKOUT_ID")
puts response.status
puts response.request_id
checkout = response.data
```

The wrapper also exposes response headers and the raw body. CSV payout exports
are returned as strings; empty successful responses return `nil`.

```ruby
begin
  client.checkouts.get(checkout_id: "CHECKOUT_ID")
rescue SumUp::RateLimitError => error
  warn "Rate limited (HTTP #{error.status})"
rescue SumUp::APIError => error
  warn "API request failed (HTTP #{error.status}, request #{error.request_id})"
rescue SumUp::APIConnectionError => error
  warn "Connection failed: #{error.class}"
end
```

HTTP errors have distinct classes for bad requests, authentication, permissions,
missing resources, conflicts, validation, rate limits, and server failures.
`APIError#body` preserves JSON objects, arrays, scalar values, and non-JSON error
bodies. `problem` exposes a typed Problem when one is returned. Connection and
timeout errors retain the original exception as `cause`.

Default inspection and error messages omit credentials and response payloads.
Access bodies explicitly when diagnosing a request; they can contain payment or
personal data.

## Signed events

Verify signed event notifications using the unchanged request bytes and complete
`X-SumUp-Webhook-Signature` header:

```ruby
handler = client.events_handler(
  secret: ENV.fetch("SUMUP_WEBHOOK_SECRET"),
  fallback: ->(event) { warn "Unhandled event: #{event.type}" }
)

handler.on(SumUp::CheckoutPaidEvent::TYPE) do |event|
  checkout = event.fetch_object
  # Deduplicate by event.id and verify the current checkout before fulfillment.
end

handler.handle(raw_request_body, signature: signature_header)
```

The handler verifies the HMAC and a fixed five-minute signing-time window,
validates the envelope, and dispatches known event types. Unknown events use the
fallback. Fetching an event's resource is explicit and restricted to the client's
API origin. `fetch_object` returns current state; it does not return a historical
snapshot. Brief resource propagation delays can produce a 404 after a notification.

Await successful handling before returning a 2xx response. Reject invalid
signatures or payloads with 400; return 5xx when a callback fails so delivery can
be retried. Callbacks must tolerate repeated and out-of-order deliveries. Callback
exceptions are wrapped in `EventCallbackError` with the original `cause`.

For queues, call `SumUp::Events.verify_signature` before storing a delivery, then
use `client.parse_event_notification_without_verification` only for trusted,
previously verified data. Your HTTP server owns body-size limits.

Legacy checkout `return_url` callbacks use a different payload and verification
flow; follow the [checkout webhook guide](https://developer.sumup.com/online-payments/webhooks/).

See [CONTRIBUTING.md](CONTRIBUTING.md) for generation, validation, and releases.
