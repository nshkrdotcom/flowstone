# Security & Safety Review

This document highlights issues that can become security vulnerabilities or operational hazards in production BEAM systems.

## 1) Unbounded Atom Creation (`String.to_atom/1`)

The following code paths convert strings to atoms:
- `FlowStone.Workers.AssetWorker.perform/1` (`lib/flowstone/workers/asset_worker.ex`)
- `FlowStone.Lineage` in-memory queries (`lib/flowstone/lineage.ex`)
- `FlowStone.LineagePersistence` repo queries (`lib/flowstone/lineage_persistence.ex`)

**Why this is risky**
- Atoms are not garbage collected; converting untrusted strings to atoms can crash the VM.

**Recommendation**
- Prefer strings for asset identifiers at runtime boundaries (Oban args, DB query results).
- If atoms are required, use `String.to_existing_atom/1` and validate names against a registry of known assets.

## 2) SQL Injection / Unsafe SQL Construction in Postgres IO

`FlowStone.IO.Postgres` constructs SQL with interpolated identifiers:

- `table = config[:table] || "flowstone_#{asset}"`
- `partition_col = config[:partition_column] || "partition"`
- queries built via `"SELECT ... FROM #{table} WHERE #{partition_col} = $1"`

See: `lib/flowstone/io/postgres.ex`.

**Risk**
- If `config[:table]` or `config[:partition_column]` is influenced by external input, this becomes a SQL injection vector.

**Recommendation**
- Validate/whitelist identifier inputs, or use safer query construction (Ecto schemas/queries or quoted identifiers).
- Avoid “table-per-asset” defaults unless the system also owns migrations and lifecycle for those tables.

## 3) `:erlang.binary_to_term/1` Without `[:safe]`

`FlowStone.IO.Postgres.decode/2` supports `format: :binary` and calls `:erlang.binary_to_term(data)`.

See: `lib/flowstone/io/postgres.ex`.

**Risk**
- Decoding untrusted Erlang terms can lead to memory blowups and other unsafe behavior.

**Recommendation**
- Use `:erlang.binary_to_term(binary, [:safe])`.
- Consider avoiding binary term storage entirely for any data that can cross trust boundaries.

## 4) Partition Serialization Collisions

`FlowStone.Partition.serialize/1` joins tuples with `"|"`, and `deserialize/1` treats any string containing `"|"` as a composite partition.

See: `lib/flowstone/partition.ex`.

**Risk**
- Any partition string that naturally contains `"|"` will be misinterpreted as a tuple on deserialize.

**Recommendation**
- Prefer an unambiguous encoding (e.g. JSON array, length-prefixing, or base64 of a binary encoding).

