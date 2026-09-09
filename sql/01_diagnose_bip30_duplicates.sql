-- ============================================================
-- Diagnose zero-value rows and duplicate outpoints
-- in the original 2026-01-01 / 5-year EDS source
-- ============================================================


-- 1. Non-positive address-balance rows
SELECT
  address,
  balance_sats
FROM `sixth-wave-484005-t0.btc_eds_ljw.eds_addrbal_20260101_t5`
WHERE balance_sats <= 0
ORDER BY balance_sats, address;


-- 2. Non-positive UTXO rows
SELECT
  created_tx_hash,
  created_vout,
  created_time,
  address,
  value_sats
FROM `sixth-wave-484005-t0.btc_eds_ljw.eds_utxo_20260101_t5`
WHERE value_sats <= 0
ORDER BY value_sats, created_tx_hash, created_vout;


-- 3. Duplicate outpoint groups and their contents
SELECT
  created_tx_hash,
  created_vout,
  COUNT(*) AS row_count,
  SUM(value_sats) AS summed_value_sats,
  ARRAY_AGG(
    STRUCT(
      created_time,
      address,
      value_sats
    )
    ORDER BY created_time, address, value_sats
  ) AS rows_in_group
FROM `sixth-wave-484005-t0.btc_eds_ljw.eds_utxo_20260101_t5`
GROUP BY created_tx_hash, created_vout
HAVING COUNT(*) > 1
ORDER BY created_tx_hash, created_vout;


-- 4. Critical check:
-- Count duplicate outpoints carrying positive BTC
SELECT
  COUNT(*) AS positive_duplicate_groups,
  SUM(group_value_sats) AS positive_duplicate_sats
FROM (
  SELECT
    created_tx_hash,
    created_vout,
    SUM(value_sats) AS group_value_sats
  FROM `sixth-wave-484005-t0.btc_eds_ljw.eds_utxo_20260101_t5`
  GROUP BY created_tx_hash, created_vout
  HAVING COUNT(*) > 1
     AND SUM(value_sats) > 0
);
