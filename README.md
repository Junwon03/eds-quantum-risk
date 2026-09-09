# EDS Quantum Risk

Reproducibility repository for a working study of dormant Bitcoin supply, conditional remobilization, and ownership concentration.

This repository contains the **BIP30-corrected analysis package** for the Bitcoin EDS snapshot dated **2026-01-01** with a **5-year dormancy threshold**.

The associated manuscript is still in preparation. This repository therefore documents the data, SQL calculations, frozen outputs, and correction history used in the analysis, without attempting to reproduce the final manuscript text or journal formatting.

---

## Current analysis status

**Canonical analysis version:** v3-bip30fix  
**Snapshot date:** 2026-01-01  
**Dormancy threshold:** 5 years  
**Final QC:** PASS

This version supersedes the earlier pre-BIP30 quantitative outputs.

Earlier repository states remain available through Git history and the `pre-bip30-v2` tag for audit purposes, but they should not be used as the current quantitative results.

---

## Research scope

The analysis studies how a conditional remobilization of historically dormant Bitcoin supply may alter ownership concentration under alternative redistribution pathways.

The empirical EDS population is defined conservatively as long-inactive, unspent legacy P2PK outputs whose public keys are already visible on-chain in their locking scripts.

The shock parameter \(\alpha\) represents the fraction of EDS balance assumed to become mobile in a hypothetical stress scenario. It is a **stress parameter**, not an estimate of attack probability or timing.

Three redistribution pathways are evaluated:

- **pi_D — defensive dispersion:** activated balance is distributed equally among new recipient holders.
- **pi_T — theft aggregation:** activated balance is distributed equally among new attacker-controlled holders.
- **pi_I — incumbent concentration:** activated balance is transferred to the largest pre-shock incumbent holders.

Main settings:

- alpha = 0.5%, 1%, 2%, 5%, 10%
- pi_D: m = 10,000 new recipients
- pi_T: k = 3 new attacker-controlled holders
- pi_I: k = 3 pre-shock incumbent holders
- Nakamoto ownership threshold: tau = 33%

---

## Canonical corrected baseline

After BIP30 correction:

| Quantity | Value |
|---|---:|
| Corrected UTXO rows | 42,232 |
| Address rows | 37,566 |
| Positive-balance addresses | 37,564 |
| EDS balance | 171,831,920,736,257 sats |
| EDS balance | 1,718,319.20736257 BTC |
| Baseline HHI | approximately 3.35594904336e-05 |
| Nakamoto coefficient, tau = 33% | 11,162 |

Full-precision outputs are preserved in `results/`.

Minor differences in the final digits of FLOAT64 HHI values may occur because of floating-point summation order. They do not affect the reported directional results.

---

## Concentration calculations

### Herfindahl-Hirschman Index

For holder shares \(s_i\),

\[
HHI = \sum_i s_i^2
\]

Higher HHI indicates greater balance concentration.

### Nakamoto coefficient

For threshold \(\tau\), holders are sorted by balance from largest to smallest and the coefficient is

\[
N_\tau = \min \left\{ n : \sum_{i=1}^{n} s_{(i)} \ge \tau \right\}
\]

The main analysis uses \(\tau = 0.33\).

A lower Nakamoto coefficient indicates that fewer holders are required to reach the specified ownership threshold.

---

## BIP30 correction

The original EDS-derived UTXO source contained the two historical duplicate coinbase transaction IDs associated with the BIP30 exception:

- `d5d27987d2a3dfc724e359870c6644b40e497bdc0589a033220fe15429d88599`
- `e3bf3d07d4b0375638d5f1db5255fe07ba2c4cb067cd81b84ee974b6585fb468`

Each duplicate `txid:vout` appeared twice in the source representation.

To reproduce the relevant Bitcoin UTXO overwrite semantics, the corrected reconstruction retains the later occurrence for each duplicated outpoint.

The correction removes an aggregate overcount of:

**10,000,000,000 sats = 100 BTC**

After correction, no duplicate outpoints remain in the corrected UTXO population.

The original BigQuery source was not silently overwritten. The diagnosis and correction logic are retained in SQL for auditability.

See `docs/BIP30_CORRECTION.md` for the detailed correction note.

---

## Repository structure

```text
.
├── README.md
├── data/
│   ├── eds_utxo_20260101_t5_bip30fix.csv
│   ├── eds_addrbal_20260101_t5_bip30fix.csv
│   └── trackA_entity_membership_v1.csv
│
├── results/
│   ├── baseline_bip30_corrected.csv
│   ├── main_stress_bip30_corrected.csv
│   ├── piD_granularity_bip30_corrected.csv
│   ├── piD_naka_boundaries_bip30_corrected.csv
│   ├── topN_sensitivity_bip30_corrected.csv
│   ├── k_sensitivity_bip30_corrected.csv
│   ├── trackA_reconcile_bip30_corrected.csv
│   ├── ownership_robustness_bip30_corrected.csv
│   ├── tau_sensitivity_bip30_corrected.csv
│   └── final_qc_bip30_corrected.csv
│
├── sql/
│   ├── 00_inspect_eds_schema.sql
│   ├── 01_diagnose_bip30_duplicates.sql
│   ├── 02_baseline_bip30_corrected.sql
│   ├── 03_main_stress_bip30_corrected.sql
│   ├── 04_piD_granularity_bip30_corrected.sql
│   ├── 04b_piD_naka_status_boundaries_bip30_corrected.sql
│   ├── 05_topN_sensitivity_bip30_corrected.sql
│   ├── 06_k_sensitivity_bip30_corrected.sql
│   ├── 07a_trackA_reconcile_bip30_corrected.sql
│   ├── 07b_ownership_robustness_bip30_corrected.sql
│   ├── 08_tau_sensitivity_bip30_corrected.sql
│   └── 09_final_qc_bip30_corrected.sql
│
└── docs/
    └── BIP30_CORRECTION.md
```

---

## Reproducing the analysis in Google BigQuery

The analysis was conducted with **Google BigQuery Standard SQL**.

A separate Python implementation is not required to reproduce the reported calculations. The SQL files in `sql/` are the analysis code used for the study, and the corresponding frozen outputs are provided in `results/`.

### 1. Create a BigQuery dataset

In Google Cloud Console:

1. Open **BigQuery**.
2. Select or create a Google Cloud project.
3. Create a dataset in a location compatible with your workflow.
4. Import the CSV files from `data/` as BigQuery tables.

Recommended table names:

```text
eds_utxo_20260101_t5_bip30fix
eds_addrbal_20260101_t5_bip30fix
trackA_entity_membership_v1
```

When importing the CSV files, preserve integer balance fields such as `balance_sats` or value-in-satoshis fields as integer or exact numeric types where possible.

### 2. Update project and dataset identifiers

The SQL files preserve the project and dataset identifiers used during the original analysis.

Before running them in another BigQuery environment, replace references such as

```sql
`sixth-wave-484005-t0.btc_eds_ljw.<table_name>`
```

with the corresponding project, dataset, and table names in your own BigQuery environment.

### 3. Reproduce the corrected analysis

The corrected CSV files in `data/` are the frozen analysis population required to reproduce the current reported results.

The principal analysis files are:

| SQL file | Purpose | Frozen output |
|---|---|---|
| `02_baseline_bip30_corrected.sql` | Corrected baseline HHI and Nakamoto coefficient | `results/baseline_bip30_corrected.csv` |
| `03_main_stress_bip30_corrected.sql` | Main 15 stress scenarios | `results/main_stress_bip30_corrected.csv` |
| `04_piD_granularity_bip30_corrected.sql` | pi_D recipient-granularity analysis | `results/piD_granularity_bip30_corrected.csv` |
| `04b_piD_naka_status_boundaries_bip30_corrected.sql` | Exact Nakamoto status boundaries | `results/piD_naka_boundaries_bip30_corrected.csv` |
| `05_topN_sensitivity_bip30_corrected.sql` | Top-N population sensitivity | `results/topN_sensitivity_bip30_corrected.csv` |
| `06_k_sensitivity_bip30_corrected.sql` | k = 1, 3, 5 sensitivity | `results/k_sensitivity_bip30_corrected.csv` |
| `07a_trackA_reconcile_bip30_corrected.sql` | Track-A reconciliation | `results/trackA_reconcile_bip30_corrected.csv` |
| `07b_ownership_robustness_bip30_corrected.sql` | Ownership-definition robustness | `results/ownership_robustness_bip30_corrected.csv` |
| `08_tau_sensitivity_bip30_corrected.sql` | tau = 25%, 33%, 50% sensitivity | `results/tau_sensitivity_bip30_corrected.csv` |
| `09_final_qc_bip30_corrected.sql` | Final audit query against the original pre-correction BigQuery source | `results/final_qc_bip30_corrected.csv` |

To reproduce the current corrected analytical results, run the relevant analysis queries from `02_baseline_bip30_corrected.sql` through `08_tau_sensitivity_bip30_corrected.sql` in BigQuery and compare their outputs with the corresponding CSV files in `results/`.

`09_final_qc_bip30_corrected.sql` is retained as a final audit query and is not fully reproducible from the corrected CSV exports alone because part of its QC logic verifies properties of the original pre-correction BigQuery source.

### 4. Audit of the original pre-correction source

`00_inspect_eds_schema.sql` and `01_diagnose_bip30_duplicates.sql`, together with the BIP30-correction logic retained in the subsequent analysis scripts, document how the historical source issue was identified and corrected.

`09_final_qc_bip30_corrected.sql` is the final audit query executed against the original pre-correction BigQuery source. Its overall `PASS` status includes verification that the original source contained exactly two historical BIP30 duplicate outpoint groups.

Because the repository provides the frozen **BIP30-corrected** analysis population rather than the complete original pre-correction BigQuery table, the overall `PASS` status of `09_final_qc_bip30_corrected.sql` cannot be reproduced from the corrected CSV exports alone. The frozen output in `results/final_qc_bip30_corrected.csv` is therefore retained as an audit record of the final QC execution.

The original pre-correction BigQuery table is not required to reproduce the current corrected analytical results. Those results can be reproduced from the CSV files in `data/` using the relevant analysis queries from `02_baseline_bip30_corrected.sql` through `08_tau_sensitivity_bip30_corrected.sql`.

In other words:

- `data/` provides the frozen BIP30-corrected analysis population required to reproduce the current analytical results.
- `sql/02` through `sql/08` contain the BigQuery calculations used to reproduce the corrected baseline, stress tests, robustness analyses, and sensitivity analyses.
- `results/` provides the frozen outputs against which those reproduced results can be checked.
- `sql/00`, `sql/01`, and `sql/09` preserve the original-source inspection, BIP30 diagnosis, and final QC audit trail.

---

## Main computational results

The following statements describe the frozen outputs contained in this repository.

### Main stress analysis

Across the main alpha grid:

- pi_D lowers HHI and increases the Nakamoto coefficient.
- pi_T raises HHI and lowers the Nakamoto coefficient.
- pi_I raises HHI and lowers the Nakamoto coefficient.

### Recipient granularity

Under pi_D, the concentration assessment depends on the number of new recipients.

At alpha = 10%:

- HHI first improves at **m = 1,569**
- Nakamoto remains below baseline through **m = 2,558**
- Nakamoto equals baseline at **m = 2,559**
- Nakamoto improves from **m = 2,560**

Thus, HHI and the Nakamoto coefficient can give different concentration assessments over an intermediate recipient-granularity range.

### Ownership robustness

The analysis is repeated under four observable ownership definitions:

- address level
- spending-history aggregation bound
- public-label aggregation
- combined aggregation bound

Across all 60 ownership-model × shock × pathway combinations, the qualitative directional result is unchanged.

These constructions are **observable aggregation bounds**, not a complete reconstruction of real-world beneficial ownership.

### Nakamoto-threshold sensitivity

| Threshold | Baseline Nakamoto coefficient |
|---|---:|
| 25% | 8,412 |
| 33% | 11,162 |
| 50% | 17,004 |

Across the tested alpha grid, the qualitative direction of pi_D, pi_T, and pi_I remains unchanged under all three thresholds.

### Top-N and k sensitivity

The repository additionally contains:

- Top-500 / Top-1,000 / Top-2,000 / full-distribution sensitivity
- k = 1 / 3 / 5 sensitivity

The directional effects of pi_D and pi_I are robust to the tested Top-N population cutoffs, whereas pi_T is cutoff- and metric-sensitive at low shock intensities.

---

## Final QC

The frozen final quality-control output is:

**PASS**

`results/final_qc_bip30_corrected.csv` checks the core source correction, baseline values, main scenario structure, directional results, alpha = 10% cross-checks, granularity result, Nakamoto-threshold sensitivity, and Track-A reconciliation.

Canonical QC values include:

- original duplicate outpoint groups: 2
- corrected UTXO rows: 42,232
- corrected duplicate outpoint groups: 0
- positive addresses: 37,564
- corrected total balance: 171,831,920,736,257 sats
- baseline Nakamoto coefficient at 33%: 11,162
- main scenario rows: 15
- alpha = 10% minimum m for HHI improvement: 1,569

---

## Data and provenance notes

The CSV files in `data/` are frozen exports used in the current corrected analysis.

`trackA_entity_membership_v1.csv` preserves the ownership-mapping membership structure developed before the BIP30 correction. Its historical `balance_sats` field is not treated as the canonical corrected balance.

For the corrected ownership analysis, balances are reconstructed from the BIP30-corrected source and joined to Track-A membership by address.

Two Track-A addresses have the expected 50 BTC balance reduction caused by the BIP30 correction. The membership structure itself is unchanged.

---

## Interpretation limits

This repository does not estimate:

- the probability of a quantum attack
- the date or timing of a cryptographic break
- market-price effects
- liquidity effects
- realized theft behavior
- complete real-world entity ownership
- governance quality

The scenarios are conditional accounting stress tests over the EDS ownership distribution.

HHI and Nakamoto coefficients measure numerical ownership concentration under the stated holder definitions. They should not be interpreted as complete measures of decentralization, governance, security, or systemic financial impact.

---

## Manuscript status

The associated manuscript is currently in preparation.

The final manuscript title, citation, journal information, and persistent archival identifier will be added when the submission package is finalized.

Working research theme:

**Dormant Bitcoin supply, redistribution pathways, recipient granularity, and concentration risk.**

---

## Citation

Citation metadata will be added when the archival release and manuscript metadata are finalized.

Until then, users should identify the repository version or release tag used in their analysis.

---

## Contact

Repository maintained by **Junwon Lee**.
