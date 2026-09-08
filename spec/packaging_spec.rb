# frozen_string_literal: true

require "spec_helper"

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
end
