repository = Repository.find_or_create_by!(name: "rubydb-demo") do |record|
  record.description = "A tiny repository for testing RubyDB with Rails."
end

Issue.find_or_create_by!(repository: repository, title: "Try the demo") do |issue|
  issue.body = "Create an issue from the browser and check the Rails query path."
end

Commit.find_or_create_by!(sha: "0000001") do |commit|
  commit.repository = repository
  commit.message = "Initial demo commit"
  commit.author = "RubyDB"
end

puts "Seeded #{repository.name}"
