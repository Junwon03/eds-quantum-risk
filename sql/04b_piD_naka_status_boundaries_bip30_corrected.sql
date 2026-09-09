-- ============================================================
-- 04b_piD_naka_status_boundaries_bip30_corrected.sql
--
-- Exact Nakamoto-status boundaries for defensive dispersion
-- (pi_D), using the BIP30-corrected EDS baseline.
--
-- Source:
--   eds_utxo_20260101_t5
--
-- Settings:
--   snapshot  : 2026-01-01
--   dormancy  : 5 years
--   alpha     : 0.5%, 1%, 2%, 5%, 10%
--   m sweep   : 1 ... 10,000 new recipients
--   Nakamoto  : tau = 0.33
--
-- Outputs:
--   1) last m where Nakamoto is worse than baseline
--   2) first m where Nakamoto equals baseline
--   3) last m where Nakamoto equals baseline
--   4) first m where Nakamoto improves
--   5) minimum m where HHI improves
-- ============================================================

WITH

-- ------------------------------------------------------------
-- 1. BIP30 correction
-- ------------------------------------------------------------
ranked_utxo AS (
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

-- ------------------------------------------------------------
-- 2. Baseline ordering
-- ------------------------------------------------------------
baseline_ranked AS (
  SELECT
    address,
    balance_sats,

    ROW_NUMBER() OVER (
      ORDER BY balance_sats DESC, address ASC
    ) AS holder_number

  FROM positive
),

baseline_ordered AS (
  SELECT
    address,
    balance_sats,
    holder_number,

    SUM(balance_sats) OVER (
      ORDER BY holder_number
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_sats

  FROM baseline_ranked
),

-- ------------------------------------------------------------
-- 3. Baseline aggregates
-- ------------------------------------------------------------
baseline_metrics AS (
  SELECT
    COUNT(*) AS n_holders,

    SUM(balance_sats) AS total_sats,

    SUM(
      CAST(balance_sats AS BIGNUMERIC)
      * CAST(balance_sats AS BIGNUMERIC)
    ) AS sum_square_sats,

    COUNTIF(balance_sats = 5000000000)
      AS baseline_50btc_addresses

  FROM positive
),

baseline_naka AS (
  SELECT
    MIN(o.holder_number) AS baseline_nakamoto_33

  FROM baseline_ordered o
  CROSS JOIN baseline_metrics b

  WHERE
    o.cumulative_sats * 100
      >= b.total_sats * 33
),

-- ------------------------------------------------------------
-- 4. Arrays for efficient rank insertion
-- ------------------------------------------------------------
balance_array AS (
  SELECT
    ARRAY_AGG(
      balance_sats
      ORDER BY balance_sats ASC, address ASC
    ) AS ascending_balances

  FROM positive
),

prefix_array AS (
  SELECT
    ARRAY_AGG(
      cumulative_sats
      ORDER BY holder_number
    ) AS prefix_sums

  FROM baseline_ordered
),

baseline_pack AS (
  SELECT
    b.n_holders,
    b.total_sats,
    b.sum_square_sats,
    b.baseline_50btc_addresses,
    n.baseline_nakamoto_33,
    ba.ascending_balances,
    pa.prefix_sums

  FROM baseline_metrics b
  CROSS JOIN baseline_naka n
  CROSS JOIN balance_array ba
  CROSS JOIN prefix_array pa
),

-- ------------------------------------------------------------
-- 5. Alpha grid
-- ------------------------------------------------------------
alpha_grid AS (
  SELECT alpha
  FROM UNNEST([
    NUMERIC '0.005',
    NUMERIC '0.01',
    NUMERIC '0.02',
    NUMERIC '0.05',
    NUMERIC '0.10'
  ]) AS alpha
),

-- ------------------------------------------------------------
-- 6. Recipient-granularity grid
-- ------------------------------------------------------------
m_grid AS (
  SELECT m
  FROM UNNEST(GENERATE_ARRAY(1, 10000)) AS m
),

grid_raw AS (
  SELECT
    a.alpha,
    m.m,
    b.*,

    SAFE_DIVIDE(
      a.alpha * CAST(b.total_sats AS NUMERIC),
      CAST(m.m AS NUMERIC)
    ) AS fresh_balance_sats,

    CAST(
      CEIL(
        SAFE_DIVIDE(
          a.alpha * CAST(b.total_sats AS NUMERIC),
          CAST(m.m AS NUMERIC)
          * (NUMERIC '1' - a.alpha)
        )
      )
      AS INT64
    ) AS min_original_balance_to_precede

  FROM alpha_grid a
  CROSS JOIN m_grid m
  CROSS JOIN baseline_pack b
),

-- ------------------------------------------------------------
-- 7. Number of incumbents ahead of each new recipient
-- ------------------------------------------------------------
grid_rank AS (
  SELECT
    *,

    n_holders
      - RANGE_BUCKET(
          min_original_balance_to_precede - 1,
          ascending_balances
        )
      AS incumbents_before_new

  FROM grid_raw
),

-- ------------------------------------------------------------
-- 8. Exact HHI-improvement flag
--
-- pi_D:
-- H_D = (1-alpha)^2 H_0 + alpha^2 / m
-- ------------------------------------------------------------
grid_hhi AS (
  SELECT
    *,

    (
      CAST(m AS BIGNUMERIC)
      * CAST(NUMERIC '1' - alpha AS BIGNUMERIC)
      * CAST(NUMERIC '1' - alpha AS BIGNUMERIC)
      * sum_square_sats

      +

      CAST(alpha AS BIGNUMERIC)
      * CAST(alpha AS BIGNUMERIC)
      * CAST(total_sats AS BIGNUMERIC)
      * CAST(total_sats AS BIGNUMERIC)

      <

      CAST(m AS BIGNUMERIC)
      * sum_square_sats
    ) AS hhi_improved

  FROM grid_rank
),

-- ------------------------------------------------------------
-- 9. Cumulative balance of top N0 and top N0-1 holders
--
-- N0 = corrected baseline Nakamoto coefficient
-- ------------------------------------------------------------
top_sums AS (
  SELECT
    *,

    -- ========================================================
    -- Top N0 cumulative balance
    -- ========================================================
    CASE

      -- New recipients rank below top N0 entirely.
      WHEN incumbents_before_new >= baseline_nakamoto_33
      THEN
        (NUMERIC '1' - alpha)
        * CAST(
            prefix_sums[
              SAFE_OFFSET(baseline_nakamoto_33 - 1)
            ]
            AS NUMERIC
          )

      -- New recipients fill all remaining positions
      -- inside the top N0.
      WHEN m >= baseline_nakamoto_33 - incumbents_before_new
      THEN
        (NUMERIC '1' - alpha)
        *
        CASE
          WHEN incumbents_before_new = 0
            THEN NUMERIC '0'
          ELSE
            CAST(
              prefix_sums[
                SAFE_OFFSET(incumbents_before_new - 1)
              ]
              AS NUMERIC
            )
        END

        +

        CAST(
          baseline_nakamoto_33 - incumbents_before_new
          AS NUMERIC
        )
        * fresh_balance_sats

      -- All m new recipients enter top N0,
      -- and the rest are incumbents.
      ELSE
        (NUMERIC '1' - alpha)
        *
        CASE
          WHEN baseline_nakamoto_33 - m = 0
            THEN NUMERIC '0'
          ELSE
            CAST(
              prefix_sums[
                SAFE_OFFSET(
                  baseline_nakamoto_33 - m - 1
                )
              ]
              AS NUMERIC
            )
        END

        +

        CAST(m AS NUMERIC)
        * fresh_balance_sats

    END AS cumulative_top_n0_sats,


    -- ========================================================
    -- Top N0-1 cumulative balance
    -- ========================================================
    CASE

      WHEN incumbents_before_new
        >= baseline_nakamoto_33 - 1
      THEN
        (NUMERIC '1' - alpha)
        * CAST(
            prefix_sums[
              SAFE_OFFSET(baseline_nakamoto_33 - 2)
            ]
            AS NUMERIC
          )

      WHEN m >=
        (baseline_nakamoto_33 - 1)
        - incumbents_before_new
      THEN
        (NUMERIC '1' - alpha)
        *
        CASE
          WHEN incumbents_before_new = 0
            THEN NUMERIC '0'
          ELSE
            CAST(
              prefix_sums[
                SAFE_OFFSET(incumbents_before_new - 1)
              ]
              AS NUMERIC
            )
        END

        +

        CAST(
          (baseline_nakamoto_33 - 1)
          - incumbents_before_new
          AS NUMERIC
        )
        * fresh_balance_sats

      ELSE
        (NUMERIC '1' - alpha)
        *
        CASE
          WHEN (baseline_nakamoto_33 - 1) - m = 0
            THEN NUMERIC '0'
          ELSE
            CAST(
              prefix_sums[
                SAFE_OFFSET(
                  (baseline_nakamoto_33 - 1)
                  - m - 1
                )
              ]
              AS NUMERIC
            )
        END

        +

        CAST(m AS NUMERIC)
        * fresh_balance_sats

    END AS cumulative_top_n0_minus1_sats

  FROM grid_hhi
),

-- ------------------------------------------------------------
-- 10. Classify Nakamoto relative to baseline
-- ------------------------------------------------------------
classified AS (
  SELECT
    *,

    CASE

      -- Top N0 still below 33%:
      -- requires MORE holders than baseline.
      WHEN cumulative_top_n0_sats
        < NUMERIC '0.33' * CAST(total_sats AS NUMERIC)
      THEN 'IMPROVED'

      -- Top N0-1 below 33%, but top N0 reaches threshold:
      -- exactly equal to baseline Nakamoto.
      WHEN cumulative_top_n0_minus1_sats
        < NUMERIC '0.33' * CAST(total_sats AS NUMERIC)

       AND cumulative_top_n0_sats
        >= NUMERIC '0.33' * CAST(total_sats AS NUMERIC)
      THEN 'EQUAL'

      -- Threshold already reached before N0 holders.
      ELSE 'DETERIORATED'

    END AS naka_status

  FROM top_sums
)

-- ============================================================
-- 11. Final exact Nakamoto-status boundaries
-- ============================================================
SELECT
  CAST(alpha * NUMERIC '100' AS FLOAT64)
    AS alpha_percent,

  MAX(
    IF(naka_status = 'DETERIORATED', m, NULL)
  ) AS max_m_naka_deteriorated,

  MIN(
    IF(naka_status = 'EQUAL', m, NULL)
  ) AS min_m_naka_equal,

  MAX(
    IF(naka_status = 'EQUAL', m, NULL)
  ) AS max_m_naka_equal,

  MIN(
    IF(naka_status = 'IMPROVED', m, NULL)
  ) AS min_m_naka_improved,

  MIN(
    IF(hhi_improved, m, NULL)
  ) AS min_m_hhi_improved,

  ANY_VALUE(baseline_nakamoto_33)
    AS baseline_nakamoto_33,

  ANY_VALUE(total_sats)
    AS corrected_total_sats

FROM classified

GROUP BY alpha
ORDER BY alpha;
