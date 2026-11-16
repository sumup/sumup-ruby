# Rack event receiver

Set `SUMUP_API_KEY` for a sandbox merchant and `SUMUP_WEBHOOK_SECRET` for the
signed event destination, then start the local application:

```sh
cd examples/events
bundle install
bundle exec rackup -o 127.0.0.1 -p 4242
```

Forward your destination to `/webhooks/sumup` through your development tunnel.
The receiver reads raw bytes before JSON processing, limits requests to 1 MiB,
verifies the signed envelope, and waits for the callback before acknowledging.
Invalid events return 400, oversized bodies return 413, and callback failures
return 500 so the delivery can be retried.

The checkout callback fetches current state; it does not fulfill an order. Add
durable event-ID deduplication and transaction-safe order updates in your
application. This example does not handle legacy checkout `return_url` callbacks.
