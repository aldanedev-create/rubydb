# Snapshots

Snapshots capture a consistent RubyDB state for inspection, backup validation,
branching, or staging. Create snapshots through the supported CLI/API and keep
the snapshot with its metadata and checksum.

Validate a snapshot by opening it in a separate directory. Do not treat a
snapshot as a replacement for an independently verified backup or replication.
Keep retention and deletion policies explicit for production data.
