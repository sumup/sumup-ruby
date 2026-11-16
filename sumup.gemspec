# frozen_string_literal: true

require_relative "lib/sumup/version"

Gem::Specification.new do |spec|
  spec.name = "sumup"
  spec.version = SumUp::VERSION
  spec.authors = ["SumUp"]
  spec.email = ["integration@sumup.com"]
  spec.summary = "Ruby SDK for the SumUp API"
  spec.description = "Generated resource clients, models, and signed event handling for SumUp's public API."
  spec.homepage = "https://developer.sumup.com"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "README.md", "CHANGELOG.md", "LICENSE"]
  spec.require_paths = ["lib"]
  spec.metadata = {
    "source_code_uri" => "https://github.com/sumup/sumup-ruby",
    "bug_tracker_uri" => "https://github.com/sumup/sumup-ruby/issues",
    "changelog_uri" => "https://github.com/sumup/sumup-ruby/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://developer.sumup.com",
    "rubygems_mfa_required" => "true",
    "allowed_push_host" => "https://rubygems.org"
  }
  spec.add_dependency "json", ">= 2.7", "< 3"
  spec.add_dependency "net-http", ">= 0.4", "< 1"
  spec.add_dependency "openssl", ">= 3.2", "< 5"
end
