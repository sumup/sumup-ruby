# frozen_string_literal: true

require_relative "generator"

if $PROGRAM_NAME == __FILE__
  root = File.expand_path("..", __dir__)
  spec = JSON.parse(File.read(File.join(root, "openapi.json")))
  SumUpCodegen::Generator.new(spec).write(root, check: ARGV.include?("--check"))
end
