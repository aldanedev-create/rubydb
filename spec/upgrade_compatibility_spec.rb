# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "upgrade compatibility" do
  it "refuses to open an unknown storage page format" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "database.rdb")
      manager = RubyDB::Storage::FileManager.new(path)
      manager.create_or_open
      manager.file.seek(32)
      manager.file.write([99].pack("I>"))
      manager.file.flush

      expect { manager.send(:validate_file) }
        .to raise_error(RubyDB::CorruptionError, /Unsupported storage page format version/)
    ensure
      manager&.close
    end
  end

  it "reloads configuration without deadlocking" do
    config = RubyDB::Configuration::Config.instance
    config.load
    thread = Thread.new { config.reload }
    expect(thread.join(2)).to be_a(Thread)
    expect(thread.alive?).to be(false)
  end

  it "loads the production template from environment-controlled settings" do
    previous = {
      "RUBYDB_USERNAME" => ENV["RUBYDB_USERNAME"],
      "RUBYDB_PASSWORD" => ENV["RUBYDB_PASSWORD"],
      "RUBYDB_SSL_ENABLED" => ENV["RUBYDB_SSL_ENABLED"]
    }
    ENV["RUBYDB_USERNAME"] = "deploy"
    ENV["RUBYDB_PASSWORD"] = "test-secret"
    ENV["RUBYDB_SSL_ENABLED"] = "false"

    config = RubyDB::Configuration::Config.instance
    config.environment = :production
    loaded = config.load(File.expand_path("../config/production.yml", __dir__))
    expect(loaded.dig(:server, :host)).to eq("127.0.0.1")
    expect(loaded.dig(:auth, :credentials, :username)).to eq("deploy")
    expect(loaded.dig(:ssl, :enabled)).to be(false)
  ensure
    previous&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
