# frozen_string_literal: true

namespace :ror_mcp do
  desc "Print each MCP server's tools, collections and description size (ror_mcp:describe[server])"
  task :describe, [:server] => :environment do |_task, args|
    RorMcp::Inspector.describe(args[:server])
  end

  desc "Validate MCP collections, toolsets and description budgets; exits 1 on problems (for CI)"
  task :check, [:server] => :environment do |_task, args|
    exit(1) unless RorMcp::Inspector.check(args[:server])
  end
end
