# frozen_string_literal: true

require "sumup"
require "oauth2"
require "webrick"
require "securerandom"
require "base64"
require "digest"
require "openssl"

redirect_uri = "http://127.0.0.1:4567/callback"
oauth = OAuth2::Client.new(
  ENV.fetch("SUMUP_CLIENT_ID"), ENV.fetch("SUMUP_CLIENT_SECRET"),
  site: "https://api.sumup.com", authorize_url: "/authorize", token_url: "/token",
  auth_scheme: :request_body
)
state = SecureRandom.hex(32)
verifier = SecureRandom.urlsafe_base64(48)
challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)

server = WEBrick::HTTPServer.new(
  Port: 4567, BindAddress: "127.0.0.1", AccessLog: [],
  Logger: WEBrick::Log.new(File::NULL)
)
server.mount_proc("/callback") do |request, response|
  supplied_state = request.query["state"].to_s
  unless supplied_state.bytesize == state.bytesize && OpenSSL.fixed_length_secure_compare(state, supplied_state)
    response.status = 400
    response.body = "Invalid OAuth state."
    next
  end
  if request.query["error"] || request.query["code"].to_s.empty?
    response.status = 400
    response.body = "Authorization was not completed."
    next
  end
  begin
    token = oauth.auth_code.get_token(request.query.fetch("code"), redirect_uri: redirect_uri, code_verifier: verifier)
    client = SumUp::Client.new(api_key: token.token)
    merchant_code = token.params.fetch("merchant_code") { ENV.fetch("SUMUP_MERCHANT_CODE") }
    merchant = client.merchants.get(merchant_code: merchant_code)
    puts "Connected merchant: #{merchant_code} (#{merchant.class})"
    response.body = "Connected. You can close this window."
    server.shutdown
  rescue OAuth2::Error, SumUp::Error, KeyError
    response.status = 500
    response.body = "Could not complete authorization. Check the app configuration and try again."
  end
end

puts "Open this URL to connect a sandbox merchant:"
puts oauth.auth_code.authorize_url(
  redirect_uri: redirect_uri, state: state,
  scope: ENV.fetch("SUMUP_SCOPES", "user.profile_readonly"),
  code_challenge: challenge, code_challenge_method: "S256"
)
trap("INT") { server.shutdown }
server.start
