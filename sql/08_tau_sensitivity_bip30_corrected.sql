-- ============================================================
-- 08_tau_sensitivity_bip30_corrected.sql
--
-- Nakamoto-threshold sensitivity analysis using the
-- BIP30-corrected full positive-balance EDS distribution.
--
-- Settings:
--   snapshot  : 2026-01-01
--   dormancy  : 5 years
--   alpha     : 0.5%, 1%, 2%, 5%, 10%
--   pathways  : pi_D, pi_T, pi_I
--   pi_D      : m = 10,000 new recipients
--   pi_T      : k = 3 new attacker entities
--   pi_I      : k = 3 pre-shock top incumbents
--   tau       : 25%, 33%, 50%
--
-- Expected output:
--   3 tau × 5 alpha × 3 pathways = 45 rows
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

-- ------------------------------------------------------------
-- 2. Corrected positive address balances
-- ------------------------------------------------------------
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
-- 3. Baseline total
-- ------------------------------------------------------------
totals AS (
  SELECT
    COUNT(*) AS baseline_holder_count,
    SUM(balance_sats) AS total_sats
  FROM positive
),

-- ------------------------------------------------------------
-- 4. Pre-shock deterministic ranking
-- ------------------------------------------------------------
baseline_ranked AS (
  SELECT
    address,
    balance_sats,

    ROW_NUMBER() OVER (
      ORDER BY balance_sats DESC, address ASC
    ) AS baseline_rank

  FROM positive
),

baseline_ordered AS (
  SELECT
    address,
    balance_sats,
    baseline_rank,

    SUM(balance_sats) OVER (
      ORDER BY baseline_rank
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_sats

  FROM baseline_ranked
),

-- ------------------------------------------------------------
-- 5. Baseline HHI
-- ------------------------------------------------------------
baseline_hhi AS (
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

-- ------------------------------------------------------------
-- 6. Parameter grids
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

tau_grid AS (
  SELECT tau_threshold
  FROM UNNEST([
    NUMERIC '0.25',
    NUMERIC '0.33',
    NUMERIC '0.50'
  ]) AS tau_threshold
),

-- ------------------------------------------------------------
-- 7. Baseline Nakamoto coefficient for each tau
-- ------------------------------------------------------------
baseline_naka AS (
  SELECT
    g.tau_threshold,

    MIN(b.baseline_rank) AS baseline_nakamoto

  FROM baseline_ordered b
  CROSS JOIN totals t
  CROSS JOIN tau_grid g

  WHERE
    CAST(b.cumulative_sats AS NUMERIC)
      >= g.tau_threshold
         * CAST(t.total_sats AS NUMERIC)

  GROUP BY g.tau_threshold
),

-- ============================================================
-- 8. Construct post-shock distributions
-- ============================================================
scenario_balances AS (

  -- ==========================================================
  -- pi_D incumbents
  -- ==========================================================
  SELECT
    a.alpha,
    'pi_D' AS scenario,

    CONCAT(
      'incumbent:',
      p.address
    ) AS holder_id,

    CAST(p.balance_sats AS NUMERIC)
      * (NUMERIC '1' - a.alpha)
      AS post_balance_sats

  FROM positive p
  CROSS JOIN alpha_grid a


  UNION ALL


  -- ==========================================================
  -- pi_D: alpha share to 10,000 NEW recipients
  -- ==========================================================
  SELECT
    a.alpha,
    'pi_D' AS scenario,

    CONCAT(
      'new_dispersion:',
      LPAD(
        CAST(recipient_no AS STRING),
        5,
        '0'
      )
    ) AS holder_id,

    SAFE_DIVIDE(
      a.alpha
        * CAST(t.total_sats AS NUMERIC),
      NUMERIC '10000'
    ) AS post_balance_sats

  FROM alpha_grid a
  CROSS JOIN totals t
  CROSS JOIN UNNEST(
    GENERATE_ARRAY(1, 10000)
  ) AS recipient_no


  UNION ALL


  -- ==========================================================
  -- pi_T incumbents
  -- ==========================================================
  SELECT
    a.alpha,
    'pi_T' AS scenario,

    CONCAT(
      'incumbent:',
      p.address
    ) AS holder_id,

    CAST(p.balance_sats AS NUMERIC)
      * (NUMERIC '1' - a.alpha)
      AS post_balance_sats

  FROM positive p
  CROSS JOIN alpha_grid a


  UNION ALL


  -- ==========================================================
  -- pi_T: alpha share to 3 NEW attacker holders
  -- ==========================================================
  SELECT
    a.alpha,
    'pi_T' AS scenario,

    CONCAT(
      'new_attacker:',
      CAST(attacker_no AS STRING)
    ) AS holder_id,

    SAFE_DIVIDE(
      a.alpha
        * CAST(t.total_sats AS NUMERIC),
      NUMERIC '3'
    ) AS post_balance_sats

  FROM alpha_grid a
  CROSS JOIN totals t
  CROSS JOIN UNNEST(
    GENERATE_ARRAY(1, 3)
  ) AS attacker_no


  UNION ALL


  -- ==========================================================
  -- pi_I:
  -- alpha share to PRE-SHOCK top-3 incumbents
  -- ==========================================================
  SELECT
    a.alpha,
    'pi_I' AS scenario,

    CONCAT(
      'incumbent:',
      b.address
    ) AS holder_id,

    (
      CAST(b.balance_sats AS NUMERIC)
        * (NUMERIC '1' - a.alpha)
    )
    +
    CASE
      WHEN b.baseline_rank <= 3
      THEN
        SAFE_DIVIDE(
          a.alpha
            * CAST(t.total_sats AS NUMERIC),
          NUMERIC '3'
        )
      ELSE NUMERIC '0'
    END AS post_balance_sats

  FROM baseline_ranked b
  CROSS JOIN alpha_grid a
  CROSS JOIN totals t
),

-- ------------------------------------------------------------
-- 9. Scenario totals + HHI
-- ------------------------------------------------------------
scenario_summary AS (
  SELECT
    s.alpha,
    s.scenario,

    COUNT(*) AS holder_count,

    SUM(s.post_balance_sats) AS post_total_sats,

    SUM(
      POW(
        SAFE_DIVIDE(
          CAST(s.post_balance_sats AS FLOAT64),
          CAST(t.total_sats AS FLOAT64)
        ),
        2
      )
    ) AS hhi

  FROM scenario_balances s
  CROSS JOIN totals t

  WHERE s.post_balance_sats > 0

  GROUP BY
    s.alpha,
    s.scenario
),

-- ------------------------------------------------------------
-- 10. Rank each post-shock distribution once
-- ------------------------------------------------------------
scenario_ordered AS (
  SELECT
    alpha,
    scenario,
    holder_id,
    post_balance_sats,

    ROW_NUMBER() OVER (
      PARTITION BY alpha, scenario
      ORDER BY post_balance_sats DESC, holder_id ASC
    ) AS holder_number,

    SUM(post_balance_sats) OVER (
      PARTITION BY alpha, scenario
      ORDER BY post_balance_sats DESC, holder_id ASC
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_sats

  FROM scenario_balances

  WHERE post_balance_sats > 0
),

-- ------------------------------------------------------------
-- 11. Nakamoto coefficient for each tau × scenario
-- ------------------------------------------------------------
scenario_naka AS (
  SELECT
    o.alpha,
    o.scenario,
    g.tau_threshold,

    MIN(o.holder_number) AS nakamoto

  FROM scenario_ordered o
  CROSS JOIN totals t
  CROSS JOIN tau_grid g

  WHERE
    o.cumulative_sats
      >= g.tau_threshold
         * CAST(t.total_sats AS NUMERIC)

  GROUP BY
    o.alpha,
    o.scenario,
    g.tau_threshold
)

-- ============================================================
-- 12. Final 45-row output
-- ============================================================
SELECT
  CAST(
    n.tau_threshold * NUMERIC '100'
    AS FLOAT64
  ) AS tau_percent,

  CAST(
    s.alpha * NUMERIC '100'
    AS FLOAT64
  ) AS alpha_percent,

  s.scenario,

  t.baseline_holder_count,

  s.holder_count,

  t.total_sats AS baseline_total_sats,

  s.post_total_sats,

  s.post_total_sats
    - CAST(t.total_sats AS NUMERIC)
    AS supply_diff_sats,

  bh.baseline_hhi,

  s.hhi,

  s.hhi - bh.baseline_hhi
    AS delta_hhi,

  bn.baseline_nakamoto,

  n.nakamoto,

  n.nakamoto
    - bn.baseline_nakamoto
    AS delta_nakamoto,

  CASE
    WHEN n.nakamoto > bn.baseline_nakamoto
      THEN 'IMPROVED'
    WHEN n.nakamoto < bn.baseline_nakamoto
      THEN 'DETERIORATED'
    ELSE 'EQUAL'
  END AS naka_direction

FROM scenario_summary s

JOIN scenario_naka n
  USING (
    alpha,
    scenario
  )

JOIN baseline_naka bn
  USING (tau_threshold)

CROSS JOIN totals t
CROSS JOIN baseline_hhi bh

ORDER BY
  n.tau_threshold,
  s.alpha,

  CASE s.scenario
    WHEN 'pi_D' THEN 1
    WHEN 'pi_T' THEN 2
    WHEN 'pi_I' THEN 3
  END;
