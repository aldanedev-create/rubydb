class Rubydb < Formula
  desc "Developer-first relational database for Ruby"
  homepage "https://github.com/aldanedev-create/rubydb"
  url "https://github.com/aldanedev-create/rubydb/archive/refs/tags/v0.1.0.tar.gz"
  version "0.1.0"
  license "MIT"

  depends_on "ruby@3.3"

  def install
    system "gem", "build", "rubydb.gemspec"
    system "gem", "install", "--no-document", *Dir["rubydb-*.gem"]
    bin.install "exe/rubydb"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/rubydb --version")
  end
end
