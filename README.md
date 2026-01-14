 # EDS-Based Stress Testing of Bitcoin Under Quantum Security Risk

This repository provides the data and code necessary to reproduce the empirical results of the paper:

**“Quantum Security Risks and the Decentralization Paradox of Bitcoin”**  
SSRN preprint, December 25, 2025

The study introduces **Exposed Dormant Supply (EDS)** as a measurable pre-shock vulnerability pool and conducts structural stress tests to evaluate how exogenous cryptographic shocks (e.g., post-quantum threats) may affect concentration and governance outcomes in Bitcoin.

---

## Overview

Rather than predicting the timing of quantum-capable adversaries, this project focuses on **structural sensitivity**:
- Which parts of the Bitcoin supply are *exposed* under a cryptographic break,
- How much of that supply is activated (α),
- And where the activated supply concentrates (allocation patterns).

The analysis is designed as a **stress-test framework**, not a point forecast.

---

## Data Source

All computations are based on the public dataset:

- **Google BigQuery**
  - `bigquery-public-data.crypto_bitcoin.transactions`

No raw blockchain transaction data is redistributed in this repository.  
Only **aggregated outputs** and **small verification samples** are included.

---

## Repository Structure


- `data/raw/` contains CSV files **directly downloaded from BigQuery**.
- No manual modification has been applied to these files.

---

## Core Concepts

### Exposed Dormant Supply (EDS)

EDS is defined as the subset of dormant Bitcoin outputs that are vulnerable under a cryptographic break:

- Dormancy thresholds: **5 / 10 / 15 years**
- Exposure condition:
  - P2PK outputs
  - (Extensions discussed in the paper)

EDS is constructed as:

\[
EDS(T) = \sum_{i \in Dormant(T) \cap Exposed} value(UTXO_i)
\]

---

### Stress-Test Parameters

- **Activation rate (α)**: fraction of EDS activated by a shock  
  - α ∈ {0.5%, 1%, 2%, 5%, 10%}

- **Allocation patterns (π)**:
  - πᴰ: Defensive dispersion (self-custody migration)
  - πᵀ: Theft aggregation (malicious concentration)
  - πᴵ: Institutional absorption (custodial / managed channels)

---

## Metrics

The following outcome metrics are reported:

- **Herfindahl–Hirschman Index (HHI)**  
  Measures concentration of redistributed supply.

- **Nakamoto Coefficient (τ = 33%)**  
  Minimum number of addresses required to control 33% of supply.

All metrics are computed at the **address level**, implying a conservative lower bound on true concentration.

---

## SQL Pipeline

- `01_eds_p2pk_extract.sql`  
  Constructs Exposed Dormant Supply (EDS) from P2PK UTXOs under multiple dormancy thresholds.

- `02_stress_test_hhi.sql`  
  Implements structural stress tests by reallocating EDS under alternative allocation paths and computing HHI.

- `03_stress_test_nakamoto.sql`  
  Computes Nakamoto coefficients (33%) from post-shock distributions to assess governance concentration.

---

## Reproducibility

1. Execute the SQL scripts in the `sql/` directory using Google BigQuery.
2. Export the query results as CSV files.
3. The exported CSV files correspond to those provided in `data/raw/`.

The figures in the paper are generated directly from the CSV files in `data/raw/metrics/`.

---

## Notes on Interpretation

- The analysis is **structural and conditional**, not predictive.
- Results demonstrate how concentration outcomes depend on allocation pathways rather than shock size alone.
- Institutional absorption may increase operational robustness while simultaneously introducing centralized fragility.

---

## License

This repository is intended for academic and research use.  
Please cite the accompanying paper when using these materials.

---

## AI Usage Disclosure

AI-based tools (GPT-5.2) were used to assist with:
- drafting and refactoring SQL queries,
- organizing the data processing pipeline,
- and improving clarity and consistency of documentation.

All analytical design, parameter choices, interpretations, and conclusions are the sole responsibility of the author.  
The AI tools were not used to generate data, fabricate results, or make substantive research decisions.
<img width="451" height="690" alt="image" src="https://github.com/user-attachments/assets/c995da5d-9f24-4984-b7e9-ef162f518298" />
