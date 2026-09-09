# BIP30 Correction Note

## Scope

This note documents the BIP30-related correction applied to the
2026-01-01, 5-year dormant Bitcoin EDS analysis.

The correction affects the reconstructed UTXO and address-balance
populations and all downstream concentration analyses.

## Issue identified

The original EDS-derived UTXO source contained two duplicate
`txid:vout` groups corresponding to the historical duplicate
coinbase transactions associated with BIP30:

- `d5d27987d2a3dfc724e359870c6644b40e497bdc0589a033220fe15429d88599:0`
- `e3bf3d07d4b0375638d5f1db5255fe07ba2c4cb067cd81b84ee974b6585fb468:0`

Each outpoint appeared twice in the source representation.

Treating both historical occurrences as simultaneously existing UTXOs
overcounts the EDS balance.

## Correction rule

For each duplicated BIP30 outpoint, the corrected reconstruction retains
the later occurrence.

This reproduces the relevant Bitcoin UTXO overwrite semantics for these
historical duplicate coinbase transactions.

No other duplicate outpoints remain after correction.

## Quantitative effect

The original source contained:

- 2 duplicated positive outpoint groups
- 100 BTC of aggregate excess balance

After correction:

- corrected UTXO rows: 42,232
- duplicate outpoint groups: 0
- corrected address rows: 37,566
- positive-balance addresses: 37,564
- corrected EDS balance: 171,831,920,736,257 sats
- corrected EDS balance: 1,718,319.20736257 BTC

The correction reduces the affected balances by a total of:

**10,000,000,000 sats = 100 BTC**

## Track-A ownership mapping

Two addresses in the pre-existing Track-A ownership mapping have
balance differences attributable to the BIP30 correction.

Each affected address changes from 100 BTC in the historical balance
field to 50 BTC in the corrected reconstruction.

The ownership-membership structure itself is unchanged.

For corrected ownership analyses, Track-A membership is preserved while
balances are rejoined from the BIP30-corrected source.

## Reproducibility

The historical source is not silently overwritten.

The correction is reconstructed explicitly in the SQL workflow so that
the original condition and the correction rule remain auditable.

Relevant files include:

- `sql/01_diagnose_bip30_duplicates.sql`
- `sql/02_baseline_bip30_corrected.sql`
- `sql/03_main_stress_bip30_corrected.sql`
- `sql/07a_trackA_reconcile_bip30_corrected.sql`
- `sql/09_final_qc_bip30_corrected.sql`

The frozen final QC output is stored in:

- `results/final_qc_bip30_corrected.csv`

Its canonical status is:

**PASS**

## Versioning

The BIP30-corrected computational release supersedes the earlier
pre-BIP30 quantitative outputs.

Earlier repository states are retained through Git history and the
`pre-bip30-v2` tag for auditability.

They should not be used as the current quantitative results.
