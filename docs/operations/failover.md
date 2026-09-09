# Failover procedure

Automatic election is intentionally disabled until fencing and partition
testing are complete. Failover is an operator-controlled procedure.

## Promote a replica safely

1. Confirm the primary is stopped or fenced and cannot accept writes.
2. Confirm the candidate replica is `SYNCED` and that received and replayed WAL
   positions are equal.
3. Compare the candidate replay position with the incident recovery point.
4. Promote only after the candidate passes the configured fencing checks.
5. Point clients at the promoted node and run read/write smoke queries.
6. Keep the old primary isolated until its data and fencing epoch are reviewed.

Promotion must fail closed when a replica is streaming, lagging, or missing a
required recovery point. Never force promotion to hide a WAL gap.

## Rejoin the old primary

Treat the old primary as a stale writer. Preserve its files, compare WAL and
catalog state, and rebuild or re-bootstrap it as a replica if divergence cannot
be proven absent. Re-enable it for writes only after a new fencing lease and a
clean recovery validation.

Record the old and new fencing epochs, replica LSNs, promotion time, observed
lag, and application error rate in the incident record.
