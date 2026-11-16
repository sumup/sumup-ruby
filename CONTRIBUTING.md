# Contributing

## Setup

Use Ruby 4.0 with Bundler and Rake, plus Go 1.26 or later for the generator.
`mise.toml` selects the development tools. The gem supports Ruby 3.3 and later;
applications using it do not need Go.

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
| `codegen/` | Separate Go module for API methods, models, signatures, events, samples, and generator tests |
| `lib/sumup/resources/`, `lib/sumup/types.rb` | Generated API surface |
| `lib/sumup/event_types.rb` | Generated event-to-resource mapping |
| `lib/sumup/client.rb`, `transport.rb`, `model.rb`, `events.rb`, `pagination.rb` | Shared runtime |
| `sig/` | Shipped RBS signatures; generated API signatures and handwritten runtime signatures |
| `test/` | Offline transport, contract, model, event, pagination, and sample tests |
| `examples/` | Runnable checkout, reader, OAuth, and Rack event applications |

## Generate

`sumup/apis` owns the API source. Its `make generate-specs` produces
`specs/openapi31.json`; `.github/sync.yaml` distributes that file to SDKs.
Change API schemas there and generator behavior here. Do not hand-edit generated
Ruby or RBS output.

```sh
bundle exec rake generate
bundle exec rake generate:check
go -C codegen test ./...
```

Generation is offline and deterministic. Only local OpenAPI references are
resolved. The generator honors `x-codegen.method_name`, combines path and
operation parameters, merges object inheritance, retains scalar aliases and
described references, and includes every public operation. As in the sibling
SDKs, `x-codegen.ignore` does not remove the Go reader checkout operation.

Code samples use the shared SDK catalogue format, including SDK version,
operation IDs, and named request examples. The catalogue is generated on demand
and is not committed. `rake test` and `rake examples` export a fresh catalogue
before executing its samples against fake transports.

```sh
bundle exec rake samples                    # Export to code-samples.json
bundle exec rake 'samples[/tmp/ruby.json]'   # Export to another path
```

## Checks

```sh
bundle exec rake test          # Minitest; no live API calls
bundle exec rake codegen:test  # Go generator tests and vet
bundle exec rake lint          # StandardRB
bundle exec rake format        # Apply StandardRB fixes
bundle exec rake signatures    # Validate RBS declarations
bundle exec rake examples      # Syntax and offline execution of every generated sample
bundle exec rake docs          # RDoc API documentation
bundle exec rake build         # Build pkg/sumup-VERSION.gem
```

`rake check` runs lint, signatures, generation checks, Go and Ruby tests, example
checks, and the gem build. Format Go sources with `go -C codegen fmt ./...` and regenerate;
the generated-file check compares its exact output. Add a small generator fixture
for schema-resolution bugs and test the generated behavior.

The tests use an injected transport and prohibit accidental requests by requiring
an explicit fake response. Transport tests replace Net::HTTP's connection factory
and restore it afterwards. Examples require sandbox credentials only when run
manually; CI never charges a card or calls the live API.

## Releases

Use Conventional Commits. Release Please prepares a draft release PR and updates
`lib/sumup/version.rb` and `CHANGELOG.md`. A published GitHub release triggers the
publish workflow, which verifies the tag matches the gem version, reruns checks,
and publishes via RubyGems Trusted Publishing with attestations.

The code-sample release workflow generates the catalogue from the release tag
and opens or updates a PR for `src/codesamples/ruby.json` in `sumup/sumup-developer`.
The release bot needs access to that repository. Adding a Ruby language tab to
the developer portal is a separate change.

Publish the first gem manually to establish ownership. The released trusted
publishing actions do not yet accept the owner ID required to create a new gem.

1. Keep the release manifest empty until the first release PR. Set
   `initial-version` to `0.0.1`, and merge the configuration into `main`.
2. Disable the Publish workflow in GitHub Actions, then merge the `0.0.1` release
   PR once checks pass. Publish its draft GitHub release as `v0.0.1`.
3. From a clean checkout of the `v0.0.1` tag, run:

   ```sh
   bundle install
   bundle exec rake check build
   gem signin
   gem push pkg/sumup-0.0.1.gem
   ```

4. On RubyGems, configure a trusted publisher on the existing `sumup` gem for
   repository `sumup/sumup-ruby` and workflow `publish.yaml`. Match the GitHub
   environment if one is configured. Re-enable the Publish workflow for future
   releases; do not rerun it for the manually uploaded version.

Configure `SUMUP_BOT_APP_ID` and `SUMUP_BOT_PRIVATE_KEY` for the release bot and
grant it access to the API sync automation and `sumup-developer`. No long-lived
RubyGems API key belongs in this repository.

## Design references

The API surface and signed-event contract follow the sibling SumUp SDKs.
[Stripe Ruby](https://github.com/stripe/stripe-ruby) informed instance-based
clients, per-call options, and error handling. [Square Ruby](https://github.com/square/square-ruby-sdk)
provided a comparison for generated resources and models. Retries remain off by
default, consistent with SumUp's existing clients. The generator uses a separate
Go module, following the other SumUp SDKs.
