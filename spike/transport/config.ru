# frozen_string_literal: true

# Serve the transport spike for the parity client:
#   bundle exec rackup spike/transport/config.ru -p 3766
#   .venv/bin/python spec/parity/client/mcp_parity.py check --http-only --base-url http://127.0.0.1:3766
require_relative "spike"

run TransportSpike.app
