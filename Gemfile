# frozen_string_literal: true

source "https://rubygems.org"

gemspec

eval_gemfile "gemfiles/common.gemfile"
gem "sqlite3", ">= 2.1"

group :development do
  gem "rubocop", "~> 1.81", require: false
  gem "rubocop-rspec", "~> 3.7", require: false
end
