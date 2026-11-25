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
| `lib/sumup/resources/`, `lib/sumup/types.rb`, `lib/sumup/types/` | Generated resources, shared models, and scoped models |
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

Use Conventional Commits. Release Please opens or updates a release PR with the
next version and changelog. Once its checks pass, merge the release PR. Release
Please creates the tag and publishes the GitHub release automatically, triggering
the Publish workflow to upload the gem through RubyGems Trusted Publishing with
attestations. No local build, manual upload, or draft-release publication is needed.

The Publish workflow checks out the release tag, verifies it matches
`lib/sumup/version.rb`, and runs `rake check` before uploading. Keep the workflow
enabled in GitHub Actions. `.release-please-manifest.json` tracks the last released
version; let Release Please update it and the version file.

The code-sample release workflow generates the catalogue from the release tag
and opens or updates a PR for `src/codesamples/ruby.json` in `sumup/sumup-developer`.
The release bot needs access to that repository. Adding a Ruby language tab to
the developer portal is a separate change.

RubyGems must have a trusted publisher on the existing `sumup` gem for repository
`sumup/sumup-ruby` and workflow `publish.yaml`. Match the GitHub environment if
one is configured. The first version, `0.0.1`, was uploaded manually to establish
ownership; subsequent versions use the standard publishing action.

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
