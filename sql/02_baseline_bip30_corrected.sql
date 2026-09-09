-- Canonical BIP30-corrected baseline
-- Snapshot: 2026-01-01
-- Dormancy threshold: 5 years

WITH ranked_utxo AS (
  SELECT
    created_tx_hash,
    created_vout,
    created_time,
    address,
    value_sats,
    ROW_NUMBER() OVER (
      PARTITION BY created_tx_hash, created_vout
      ORDER BY created_time DESC, address ASC, value_sats DESC
    ) AS occurrence_rank,
    COUNT(*) OVER (
      PARTITION BY created_tx_hash, created_vout
    ) AS occurrence_count
  FROM `sixth-wave-484005-t0.btc_eds_ljw.eds_utxo_20260101_t5`
),

corrected_utxo AS (
  SELECT
    created_tx_hash,
    created_vout,
    created_time,
    address,
    value_sats
  FROM ranked_utxo
  WHERE occurrence_count = 1
     OR occurrence_rank = 1
),

corrected_addr AS (
  SELECT
    address,
    SUM(value_sats) AS balance_sats
  FROM corrected_utxo
  GROUP BY address
),

positive AS (
  SELECT
    address,
    balance_sats
  FROM corrected_addr
  WHERE balance_sats > 0
),

totals AS (
  SELECT
    COUNT(*) AS positive_addresses,
    SUM(balance_sats) AS total_sats
  FROM positive
),

hhi_calc AS (
  SELECT
    SUM(
      POW(
        SAFE_DIVIDE(
          CAST(p.balance_sats AS FLOAT64),
          CAST(t.total_sats AS FLOAT64)
        ),
        2
      )
    ) AS baseline_hhi
  FROM positive p
  CROSS JOIN totals t
),

ordered AS (
  SELECT
    address,
    balance_sats,
    ROW_NUMBER() OVER (
      ORDER BY balance_sats DESC, address ASC
    ) AS holder_number,
    SUM(balance_sats) OVER (
      ORDER BY balance_sats DESC, address ASC
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_sats
  FROM positive
),

naka_calc AS (
  SELECT
    MIN(o.holder_number) AS baseline_nakamoto_33
  FROM ordered o
  CROSS JOIN totals t
  WHERE o.cumulative_sats * 100 >= t.total_sats * 33
)

SELECT
  DATE '2026-01-01' AS snapshot_date,
  5 AS dormancy_years,
  t.positive_addresses,
  t.total_sats,
  SAFE_DIVIDE(CAST(t.total_sats AS FLOAT64), 1e8) AS total_btc,
  h.baseline_hhi,
  n.baseline_nakamoto_33
FROM totals t
CROSS JOIN hhi_calc h
CROSS JOIN naka_calc n;
