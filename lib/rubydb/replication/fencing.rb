# frozen_string_literal: true

require "json"
require "fileutils"

module RubyDB
  module Replication
    # File-backed fencing lease. The fence path must live on storage shared by
    # all nodes that can write the same database. Epoch changes are atomic and
    # stale writers fail closed when their lease no longer matches.
    class FencingLease
      attr_reader :path, :node_id, :epoch

      def initialize(path, node_id)
        @path = path
        @node_id = node_id.to_s
        @epoch = nil
      end

      def acquire!
        FileUtils.mkdir_p(File.dirname(@path))
        File.open("#{@path}.lock", "a+") do |lock|
          lock.flock(File::LOCK_EX)
          current = read_record
          @epoch = current ? current.fetch("epoch").to_i + 1 : 1
          temporary = "#{@path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
          File.write(temporary, JSON.generate(node_id: @node_id, epoch: @epoch, updated_at: Time.now.utc.iso8601))
          File.rename(temporary, @path)
        ensure
          File.delete(temporary) if defined?(temporary) && File.file?(temporary)
          lock.flock(File::LOCK_UN)
        end
        self
      rescue KeyError, JSON::ParserError, SystemCallError => e
        raise RubyDB::ReplicationError, "Unable to acquire fencing lease: #{e.message}"
      end

      def valid?
        return false unless @epoch
        record = read_record
        record && record["node_id"].to_s == @node_id && record["epoch"].to_i == @epoch
      rescue JSON::ParserError, SystemCallError
        false
      end

      def assert_valid!
        raise RubyDB::ReplicationError, "Fencing lease is missing or stale" unless valid?
        true
      end

      private

      def read_record
        return nil unless File.file?(@path)
        JSON.parse(File.read(@path))
      end
    end
  end
end
