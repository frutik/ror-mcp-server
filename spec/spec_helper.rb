# frozen_string_literal: true

require "ror_mcp_server"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
  # spec/dummy and spec/parity are apps, not spec files.
  config.exclude_pattern = "{dummy,parity}/**/*_spec.rb"
end
