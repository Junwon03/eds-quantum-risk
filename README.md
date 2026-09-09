# EDS Quantum Risk

Reproducibility repository for a working study of dormant Bitcoin supply, conditional remobilization, and ownership concentration.

This repository contains the **BIP30-corrected analysis release** based on the Bitcoin EDS snapshot dated **2026-01-01** with a **5-year dormancy threshold**.

The associated manuscript is currently in preparation. Accordingly, this repository freezes the computational analysis and supporting data without attempting to reproduce the final manuscript text, tables, or journal formatting.

---

## Current analysis status

**Canonical analysis version:** v3-bip30fix  
**Snapshot date:** 2026-01-01  
**Dormancy threshold:** 5 years  
**Final QC:** PASS

The current release supersedes the earlier pre-BIP30 computational outputs.

The previous repository state remains recoverable through Git history. It should not be used for current quantitative results.

---

## Research scope

The analysis studies how a conditional remobilization of historically dormant Bitcoin supply may alter ownership concentration under alternative redistribution pathways.

The empirical EDS population is defined conservatively using long-inactive, unspent legacy P2PK outputs whose public keys are already visible in their locking scripts.

The shock parameter \(\alpha\) represents the fraction of the EDS balance assumed to become mobile under a hypothetical stress scenario. It is a stress parameter, not an estimate of attack probability or timing.

Three redistribution pathways are evaluated:

- **pi_D — defensive dispersion:** activated balance is distributed equally among new recipient holders.
- **pi_T — theft aggregation:** activated balance is distributed equally among new attacker-controlled holders.
- **pi_I — incumbent concentration:** activated balance is transferred to the largest pre-shock incumbent holders.

The main specification uses:

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

Full-precision machine outputs are preserved in `results/`.

Minor differences in the final digits of FLOAT64 HHI values may occur because of floating-point summation order. These differences are far below the numerical tolerance used by the final QC checks and do not affect any reported directional result.

---

## BIP30 correction

The original EDS-derived UTXO table contained the two historical duplicate coinbase transaction IDs associated with the BIP30 exception:

- `d5d27987d2a3dfc724e359870c6644b40e497bdc0589a033220fe15429d88599`
- `e3bf3d07d4b0375638d5f1db5255fe07ba2c4cb067cd81b84ee974b6585fb468`

Each duplicate `txid:vout` appeared twice in the source representation.

To reproduce Bitcoin UTXO overwrite semantics, the corrected analysis retains the later occurrence for each duplicated outpoint. The correction removes an aggregate overcount of:

**10,000,000,000 sats = 100 BTC**

The resulting corrected UTXO population contains no duplicate outpoints.

The correction is reconstructed directly from the original source in the SQL analysis rather than silently modifying the historical source table.

See `docs/BIP30_CORRECTION.md` for the detailed audit note.

---

## Main findings encoded in the frozen outputs

The following statements refer only to the computational outputs contained in this release.

### Main stress analysis

Across the main alpha grid:

- pi_D lowers HHI and increases the Nakamoto coefficient.
- pi_T raises HHI and lowers the Nakamoto coefficient.
- pi_I raises HHI and lowers the Nakamoto coefficient.

These directional results are reproduced by the final QC query.

### Recipient granularity

Under pi_D, the concentration assessment depends on the number of new recipients.

At alpha = 10%:

- HHI first improves at **m = 1,569**
- Nakamoto remains below baseline through **m = 2,558**
- Nakamoto equals baseline at **m = 2,559**
- Nakamoto improves from **m = 2,560**

Thus, there is a recipient-granularity range in which HHI and the Nakamoto coefficient give different concentration assessments.

### Ownership robustness

The analysis is repeated under four observable ownership definitions:

- address level
- spending-history aggregation bound
- public-label aggregation
- combined aggregation bound

Across all 60 ownership-model × shock × pathway combinations, the qualitative directional result is unchanged.

These constructions should be interpreted as **observable aggregation bounds**, not as complete reconstruction of real-world beneficial ownership.

### Nakamoto-threshold sensitivity

The baseline Nakamoto coefficients are:

| Threshold | Baseline Nakamoto coefficient |
|---|---:|
| 25% | 8,412 |
| 33% | 11,162 |
| 50% | 17,004 |

Across the tested alpha grid, the qualitative direction of pi_D, pi_T, and pi_I remains unchanged under all three thresholds.

### Additional sensitivity analyses

The repository also contains:

- Top-500 / Top-1,000 / Top-2,000 / full-distribution sensitivity
- k = 1 / 3 / 5 sensitivity
- exact pi_D recipient-granularity boundaries
- Track-A ownership-mapping reconciliation
- final cross-query QC checks

The Top-N analysis shows that pi_D and pi_I have stable directional effects across population cutoffs, whereas pi_T is cutoff- and metric-sensitive at low shock intensities.

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
├── docs/
│   └── BIP30_CORRECTION.md
│
└── SHA256SUMS.txtx
