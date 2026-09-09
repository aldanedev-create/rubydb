# frozen_string_literal: true

# This example deliberately uses RubyDB's embedded engine. For a separately
# managed database service, use the adapter's host/port/credentials settings
# in database.yml instead.
require "rubydb"
require "active_record/connection_adapters/rubydb_adapter"
