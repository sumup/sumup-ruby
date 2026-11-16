# frozen_string_literal: true

require "rake/testtask"
require "bundler/gem_tasks"

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.warning = true
end

desc "Generate resources, models, RBS signatures, and event types"
task :generate do
  sh "go", "-C", "codegen", "run", ".", "generate"
end

desc "Export the SDK code sample catalogue (optional output path)"
task :samples, [:output] do |_, args|
  sh "go", "-C", "codegen", "run", ".", "samples", "--out", File.expand_path(args[:output] || "code-samples.json")
end

task test: :samples

namespace :generate do
  desc "Check generated files without changing the working tree"
  task :check do
    sh "go", "-C", "codegen", "run", ".", "generate", "--check"
  end
end

namespace :codegen do
  desc "Test and vet the Go generator"
  task :test do
    sh "go", "-C", "codegen", "test", "./..."
    sh "go", "-C", "codegen", "vet", "./..."
  end
end

desc "Check Ruby style with StandardRB"
task :lint do
  sh "standardrb"
end

desc "Format Ruby sources with StandardRB"
task :format do
  sh "standardrb --fix"
end

desc "Validate shipped RBS signatures"
task :signatures do
  sh "rbs -I sig validate"
end

desc "Generate API documentation"
task :docs do
  sh "rdoc --main README.md --title 'SumUp Ruby SDK' README.md lib"
end

desc "Check runnable examples and operation code samples"
task examples: :samples do
  Dir["examples/**/*.rb"].each { |path| ruby "-c", path }
  ruby "-Ilib:test", "test/samples_test.rb"
end

desc "Run all checks required by CI"
task check: [:lint, :signatures, "generate:check", "codegen:test", :test, :examples, :build]

task default: :check
