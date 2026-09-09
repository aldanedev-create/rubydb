# Pages and file layout

RubyDB stores fixed-size pages containing validated headers, checksums, and
typed records. Page allocation, metadata, table data, and index pages are
managed by the storage layer; callers must not edit database files directly.

The page format is versioned. Unknown formats, invalid page sizes, malformed
headers, and checksum failures fail closed during open or recovery. Keep the
database, WAL, catalog metadata, and lock files together when copying or
restoring a database. See [storage format](../../spec/storage/format.md) and
[upgrade guidance](../operations/upgrades.md).
