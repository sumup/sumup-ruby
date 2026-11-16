# OAuth authorization code with PKCE

Register a SumUp OAuth application with the exact callback URL
`http://127.0.0.1:4567/callback`. Set `SUMUP_CLIENT_ID`, `SUMUP_CLIENT_SECRET`, and,
if the token response does not identify the merchant, `SUMUP_MERCHANT_CODE`.
`SUMUP_SCOPES` defaults to `user.profile_readonly`.

```sh
cd examples/oauth2
bundle install
bundle exec ruby main.rb
```

Open the printed URL and authorize a sandbox merchant. The example validates
state, exchanges the code using PKCE through the `oauth2` library, and retrieves
the merchant with the SDK. It prints no access or refresh tokens. Request logging
is disabled so authorization codes do not enter access logs.

This one-user example keeps the token in memory and exits after success. In an
application, persist tokens securely per connected merchant. Track `expires_in`,
refresh with the OAuth library, persist the latest refresh token when returned,
and ask the merchant to reconnect if refresh fails with `invalid_grant`. Handle
refresh concurrency in the application. The API SDK accepts the resulting access
token; it does not own session storage or refresh scheduling.
