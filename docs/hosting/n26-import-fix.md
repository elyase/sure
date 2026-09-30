# N26 and Revolut transaction identity fixes

This fork contains focused Enable Banking importer changes for N26 and Revolut.
Other institutions retain upstream behavior.

N26 history can contain distinct, identical-looking booked payments without
transaction IDs or entry references. The importer now preserves the number of
occurrences in the complete paginated response and assigns stable local IDs.
The first occurrence keeps its existing content ID. Distinct bank references
are retained, and credits and debits sharing a reference have separate local
identities. Existing identities are reused across incremental sync windows.

Rows with stable references are refreshed when the provider updates settlement
details. User edits and import locks remain protected by the existing entry
processor. Conflicting movements sharing a reference and direction within one
response cause a visible sync failure instead of silently discarding a row.

The `_sure_external_id` field is local import metadata. Original bank fields
remain intact. Keep this metadata with stored snapshots when upgrading.

For Revolut, content deduplication includes the bank's entry reference. This
preserves distinct payments with identical dates, amounts and descriptions when
`transaction_id` is absent, while removing repeated copies of the same record.
Existing entry IDs and the usual incremental merge remain unchanged. The
regression covers pagination, overlapping pages and reordered repeat imports.
The additional N26 identity rules described above remain specific to N26.

This addresses the observed N26 cases associated with upstream issues
[#2720](https://github.com/we-promise/sure/issues/2720) and
[#3497](https://github.com/we-promise/sure/issues/3497). It is not a general solution
for every bank's rotating identifiers. ID-less identity remains dependent on
stable transaction contents and complete pagination.

Previously omitted transactions require a full historical response to recover;
ordinary incremental sync cannot restore records outside its requested window.
Back up the database and preserve the original provider response before recovery.
Verify entry multiplicity and transaction nets against the bank, then repeat the
import to ensure it does not create additional entries.

The local overlay build uses the pinned upstream image and changes only three
Ruby files:

```sh
container build --platform linux/arm64 --cpus 2 --memory 2G \
  --file Containerfile.n26 --build-arg PATCH_COMMIT_SHA="$(git rev-parse HEAD)" \
  --tag sure:n26-local .
```

Run the Enable Banking model and importer tests before deployment. Validate
Linux/amd64 separately before using that architecture. No bank credentials or
financial records belong in this repository or build context.
