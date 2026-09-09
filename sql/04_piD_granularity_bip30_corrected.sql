-- ============================================================
-- 04_piD_granularity_bip30_corrected.sql
--
-- Exact recipient-granularity boundaries for defensive
-- dispersion (pi_D), using the BIP30-corrected EDS baseline.
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
--   1) minimum m for HHI improvement
--   2) largest m where Naka equals baseline
--   3) minimum m for Naka improvement
--   4) minimum m where a fresh recipient falls below
--      the post-shock 50-BTC incumbent group
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
-- 2. Baseline ordering and cumulative balance
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
-- 3. Exact baseline aggregates
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
-- 4. Arrays used for efficient rank insertion
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
-- 5. Alpha × recipient-count grid
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

    -- Fresh recipient balance r is compared with
    -- (1-alpha)*baseline incumbent balance.
    --
    -- Because incumbent balances are integer satoshis,
    -- CEIL() converts the insertion threshold to the
    -- minimum original integer balance that precedes
    -- a new recipient.
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
-- 6. Number of incumbents ranked at or above a new recipient
--
-- RANGE_BUCKET() operates on the ascending baseline balance
-- array. Incumbents tied with a new recipient are placed first,
-- consistent with deterministic holder-ID ordering.
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
-- 7. HHI improvement flag
--
-- Under pi_D:
--
-- H_D = (1-alpha)^2 H_0 + alpha^2 / m
--
-- Instead of relying on rounded FLOAT64 HHI values,
-- compare the equivalent inequality using squared
-- satoshi balances.
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
-- 8. Calculate cumulative balance of the largest N0
--    and N0-1 post-shock holders.
--
-- We only need these two cumulative values to determine
-- whether the post-shock Nakamoto coefficient is:
--
--   < baseline
--   = baseline
--   > baseline
--
-- This avoids materializing every new recipient for every m.
-- ------------------------------------------------------------
top_sums AS (
  SELECT
    *,

    -- ----------------------------------------
    -- Sum of top N0 holders
    -- ----------------------------------------
    CASE

      -- All top-N0 positions remain incumbents.
      WHEN incumbents_before_new >= baseline_nakamoto_33
      THEN
        (NUMERIC '1' - alpha)
        * CAST(
            prefix_sums[
              SAFE_OFFSET(baseline_nakamoto_33 - 1)
            ]
            AS NUMERIC
          )

      -- Enough new recipients exist to fill all positions
      -- after incumbents that outrank them.
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

      -- All m new recipients enter the top N0,
      -- with the remaining positions occupied by incumbents.
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


    -- ----------------------------------------
    -- Sum of top N0-1 holders
    -- ----------------------------------------
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
-- 9. Classify Nakamoto relative to corrected baseline
-- ------------------------------------------------------------
classified AS (
  SELECT
    *,

    CASE

      -- Even the largest N0 holders do not reach 33%.
      -- Therefore more holders than baseline are required.
      WHEN cumulative_top_n0_sats
        < NUMERIC '0.33' * CAST(total_sats AS NUMERIC)
      THEN 'IMPROVED'

      -- N0-1 holders are below 33%, but N0 holders reach it.
      WHEN cumulative_top_n0_minus1_sats
        < NUMERIC '0.33' * CAST(total_sats AS NUMERIC)

       AND cumulative_top_n0_sats
        >= NUMERIC '0.33' * CAST(total_sats AS NUMERIC)
      THEN 'EQUAL'

      -- 33% is reached before N0 holders.
      ELSE 'DETERIORATED'

    END AS naka_status,

    (
      fresh_balance_sats
      <
      (NUMERIC '1' - alpha)
      * NUMERIC '5000000000'
    ) AS fresh_below_postshock_50btc

  FROM top_sums
)

-- ============================================================
-- 10. Exact boundary table
-- ============================================================
SELECT
  CAST(alpha * NUMERIC '100' AS FLOAT64)
    AS alpha_percent,

  MIN(
    IF(hhi_improved, m, NULL)
  ) AS min_m_hhi_improvement,

  MAX(
    IF(naka_status = 'EQUAL', m, NULL)
  ) AS max_m_naka_equal_baseline,

  MIN(
    IF(naka_status = 'IMPROVED', m, NULL)
  ) AS min_m_naka_improvement,

  MIN(
    IF(fresh_below_postshock_50btc, m, NULL)
  ) AS min_m_fresh_below_postshock_50btc,

  ANY_VALUE(baseline_nakamoto_33)
    AS baseline_nakamoto_33,

  ANY_VALUE(baseline_50btc_addresses)
    AS baseline_50btc_addresses,

  ANY_VALUE(total_sats)
    AS corrected_total_sats

FROM classified

GROUP BY alpha
ORDER BY alpha;
