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

The fork now includes upstream main at `20352e1a` (September 30, 2026),
including bank-specific consent duration support with a default ceiling of 180
days. Existing bank consents retain their original expiry until reauthorization.

Build the complete source using Apple's container runtime. The old three-file
v0.7.4 overlay is retired because it omits upstream dependencies, assets and
migrations. The helper archives tracked source into a flat build context to
avoid Apple's recursive context-transfer issues. It uses upstream's Dockerfile
with only the source-copy step replaced by archive extraction.

```sh
bin/build-apple-container localhost/elyase/sure:main-integrated
```

The build budget is 4 CPUs and 6 GiB.

Back up PostgreSQL and rehearse pending migrations on an isolated database copy
before replacing the web and worker containers. Preserve database and storage
volumes, credentials, and existing bank sessions. Runtime services use 1 CPU and
1 GiB each for web and worker; tests use 2 CPUs and 3 GiB.

Run the Enable Banking model and importer tests before deployment. Validate
Linux/amd64 separately before using that architecture. No bank credentials or
financial records belong in this repository or build context.
