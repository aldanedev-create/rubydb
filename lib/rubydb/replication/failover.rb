# frozen_string_literal: true

# Failover is defined alongside the replication-slot catalog. This public
# require target keeps direct consumers independent of load order.
require_relative "replication_slot"
