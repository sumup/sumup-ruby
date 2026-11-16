# Contributing

## Setup

Use Ruby 4.0 for development, with Bundler and Rake. `mise.toml` and
`.ruby-version` select the development series. The gem supports Ruby 3.3 and later.

```sh
mise install
bundle install
bundle exec rake check
```

The library does not commit an application lockfile. Dependency bounds in the
Gemfile and gemspec define the supported range; consumers resolve their own
versions. Use `bundle update` when validating an update against current releases.

## Layout

| Path | Responsibility |
| --- | --- |
| `openapi.json` | Checked-in input from `sumup/apis/specs/openapi31.json` |
| `codegen/` | Ruby generator for API methods, models, signatures, events, and samples |
| `lib/sumup/resources/`, `lib/sumup/types.rb` | Generated API surface |
| `lib/sumup/event_types.rb` | Generated event-to-resource mapping |
| `lib/sumup/client.rb`, `transport.rb`, `model.rb`, `events.rb`, `pagination.rb` | Shared runtime |
| `sig/` | Shipped RBS signatures; generated API signatures and handwritten runtime signatures |
| `test/` | Offline transport, contract, model, event, pagination, and generator tests |
| `examples/` | Runnable checkout, reader, OAuth, and Rack event applications |

## Generate

`sumup/apis` owns the API source. Its `make generate-specs` produces
`specs/openapi31.json`; `.github/sync.yaml` distributes that file to SDKs.
Change API schemas there and generator behavior here. Do not hand-edit generated
Ruby or RBS output.

```sh
bundle exec rake generate
bundle exec rake generate:check
```

Generation is offline and deterministic. Only local OpenAPI references are
resolved. The generator honors `x-codegen.method_name`, combines path and
operation parameters, merges object inheritance, retains scalar aliases and
described references, and includes every public operation. As in the sibling
SDKs, `x-codegen.ignore` does not remove the Go reader checkout operation.

`code-samples.json` uses the shared SDK catalogue format, including SDK version,
operation IDs, and named request examples. Regenerate it when releasing a new
version. Portal integration consumes a released catalogue; adding a Ruby language
tab to the developer portal is a separate change.

## Checks

```sh
bundle exec rake test          # Minitest; no live API calls
bundle exec rake lint          # StandardRB
bundle exec rake format        # Apply StandardRB fixes
bundle exec rake signatures    # Validate RBS declarations
bundle exec rake examples      # Syntax and offline execution of every generated sample
bundle exec rake docs          # RDoc API documentation
bundle exec rake build         # Build pkg/sumup-VERSION.gem
```

`rake check` runs lint, signatures, generation checks, tests, example checks, and
the gem build. When changing generated code, format the generator and regenerate;
the generated-file check compares its exact output. Add a small generator fixture
for schema-resolution bugs and test the generated behavior.

The tests use an injected transport and prohibit accidental requests by requiring
an explicit fake response. Transport tests replace Net::HTTP's connection factory
and restore it afterwards. Examples require sandbox credentials only when run
manually; CI never charges a card or calls the live API.

## Releases

Use Conventional Commits. Release Please prepares a draft release PR and updates
`lib/sumup/version.rb` and `CHANGELOG.md`. Regenerate code samples on the release
PR before merging. A published GitHub release triggers the publish workflow,
which verifies the tag matches the gem version, reruns checks, and publishes via
RubyGems Trusted Publishing with attestations.

Before the first release, create the `sumup/sumup-ruby` GitHub repository,
establish ownership of the `sumup` gem name, configure the `rubygems` GitHub
environment, and register `.github/workflows/publish.yaml` as a trusted publisher
on RubyGems. The first push may require an initial RubyGems release to establish
ownership. Configure `SUMUP_BOT_APP_ID` and `SUMUP_BOT_PRIVATE_KEY` for the release
bot and grant the repository access to the existing API sync automation. No
long-lived RubyGems API key belongs in this repository.

## Design references

The API surface and signed-event contract follow the sibling SumUp SDKs.
[Stripe Ruby](https://github.com/stripe/stripe-ruby) informed instance-based
clients, per-call options, and error handling. [Square Ruby](https://github.com/square/square-ruby-sdk)
provided a comparison for generated resources and models. Retries remain off by
default, consistent with SumUp's existing clients. The generator is Ruby-native
so contributors need one language toolchain.
