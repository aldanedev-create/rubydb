# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "deployment packaging" do
  let(:root) { File.expand_path("..", __dir__) }

  it "ships publishable gem metadata without placeholder ownership" do
    specification = Gem::Specification.load(File.join(root, "rubydb.gemspec"))

    expect(specification.authors).to eq(["Aldane Hutchinson"])
    expect(specification.email).to eq(["aldanehutchinson5@gmail.com"])
    expect(specification.homepage).to eq("https://github.com/aldanedev-create/rubydb")
    expect(specification.metadata.fetch("changelog_uri")).to include("/CHANGELOG.md")
  end

  it "provides a non-root Docker image with a persistent data volume" do
    dockerfile = File.read(File.join(root, "packaging/docker/Dockerfile"))
    expect(dockerfile).to include("USER rubydb")
    expect(dockerfile).to include('VOLUME ["/var/lib/rubydb"]')
    expect(dockerfile).to include("HEALTHCHECK")
  end

  it "uses exec and strict shell behavior in the container entrypoint" do
    entrypoint = File.read(File.join(root, "packaging/docker/entrypoint.sh"))
    expect(entrypoint).to include("set -eu")
    expect(entrypoint).to include("exec rubydb start")
  end

  it "hardens the systemd service and restarts failed servers" do
    service = File.read(File.join(root, "packaging/systemd/rubydb.service"))
    expect(service).to include("Restart=on-failure")
    expect(service).to include("NoNewPrivileges=true")
    expect(service).to include("ProtectSystem=strict")
  end

  it "fails closed when a release tag has no matching changelog or version" do
    script = File.join(root, "scripts/release_check")
    stdout, stderr, status = Open3.capture3(
      {"GITHUB_REF_NAME" => "v999.999.999"},
      RbConfig.ruby, script
    )

    expect(status).not_to be_success
    expect("#{stdout}\n#{stderr}").to include("does not match RubyDB::VERSION")
  end

  it "accepts the current tagged version and reviewed changelog entry" do
    script = File.join(root, "scripts/release_check")
    stdout, stderr, status = Open3.capture3(
      {"GITHUB_REF_NAME" => "v#{RubyDB::VERSION}"},
      RbConfig.ruby, script
    )

    expect(status).to be_success, stderr
    expect(stdout).to include("Release preflight passed")
  end
end
