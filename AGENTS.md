# Repository guidelines

- Use Ruby 4.0 for development; preserve Ruby 3.3 compatibility.
- Public code lives under `lib/`, signatures under `sig/`, tests under `test/`.
- `sumup/apis` owns the OpenAPI source. Change `codegen/` for generated defects,
  run `bundle exec rake generate`, and inspect output. Never edit generated files.
- The generator is a separate Go module under `codegen/`; run its tests with
  `go -C codegen test ./...`. Go is required for development, not by gem consumers.
- Keep transport and event logic in shared runtime files. Resource classes expose
  the method names specified by `x-codegen.method_name`.
- Use StandardRB, Minitest, Rake, and RBS. Run `bundle exec rake check` for changes.
- Tests must use fake transports and must not make live API requests.
- Preserve unknown response fields and enum values, explicit nulls, the distinct
  event-signature protocol, and the default of zero retries.
- Keep README examples focused on integrators. Generation and release mechanics
  belong in CONTRIBUTING.md.
- Preserve unrelated work. Commit and publish only when explicitly requested.
