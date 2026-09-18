# frozen_string_literal: true

# Embedded RubyDB has one process-local database owner. Keep the local demo at
# one application thread; use a managed RubyDB server for concurrent workers.
threads_count = Integer(ENV.fetch("RAILS_MAX_THREADS", "1"), 10)
threads threads_count, threads_count

port ENV.fetch("PORT", "3000")
environment ENV.fetch("RAILS_ENV", "development")

plugin :tmp_restart
