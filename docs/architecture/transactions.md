# Transactions

Transactions group mutations into a commit or rollback boundary. WAL commit and
flush ordering precede durable acknowledgement. MVCC determines visibility,
while lock management protects conflicting writes and resolves wait-for cycles.

Supported controls include `BEGIN`, `COMMIT`, `ROLLBACK`, savepoints, and
rollback to savepoint. A deadlock victim is rolled back and must retry the whole
application unit as appropriate. Test isolation and recovery together; a green
single-thread transaction test does not prove concurrent correctness.

## Copy/paste atomic order placement

Keep inventory and the order record in one transaction so an application error
does not publish only half of the business operation.

```ruby
require "rubydb"

db = RubyDB.open("tmp/transaction-example.rdb")
begin
  db.execute("CREATE TABLE IF NOT EXISTS inventory (sku TEXT PRIMARY KEY, stock INTEGER NOT NULL)")
  db.execute("CREATE TABLE IF NOT EXISTS orders (id INTEGER PRIMARY KEY, sku TEXT NOT NULL)")
  db.transaction do
    db.execute("UPDATE inventory SET stock = stock - 1 WHERE sku = 'coffee' AND stock > 0")
    db.execute("INSERT INTO orders (id, sku) VALUES (1, 'coffee')")
  end
ensure
  db.close
end
```
