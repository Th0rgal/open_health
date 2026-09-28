# Reviewed storage dependency

This is the `oura-store` crate from `Th0rgal/open_oura` revision
`b1b52a0da36a592d5fe8967b0024dcc40d5c746f`, with the iOS stability changes
also present in the sibling `open_oura` checkout. The root Cargo patch keeps
local and CI builds reproducible without publishing an intermediate upstream
revision or relying on a sibling directory.

Changes: system SQLite on iOS, read-only opening, mandatory WAL configuration,
full durability, transactional batch/checkpoint commits, extended SQLite errors,
streaming-query indexes (including the partial `idx_events_decoded_tag` behind the
iOS store digest), integrity checks, and regression tests.

After these changes are published upstream, replace the patch with the published
revision in the existing dependency pins and remove this directory. The protocol
crate remains pinned to the original compatible revision.
