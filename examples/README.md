# Examples

Use a sandbox merchant account. Run the checkout examples from the repository
root after `bundle install`:

```sh
bundle exec ruby -Ilib examples/checkout.rb
bundle exec ruby -Ilib examples/card_reader_checkout.rb
```

Both read `SUMUP_API_KEY` and `SUMUP_MERCHANT_CODE`. The reader example also reads
`SUMUP_READER_ID` for a reader paired to that sandbox merchant. It starts a reader
payment; it does not wait for final payment confirmation. You can use Virtual Solo
for supported Cloud API testing without a physical reader.

The [OAuth example](oauth2/README.md) and [Rack event receiver](events/README.md)
have their own Gemfiles for optional framework dependencies.
