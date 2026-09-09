-- ============================================================
-- 06_k_sensitivity_bip30_corrected.sql
--
-- k-sensitivity analysis using the BIP30-corrected
-- full positive-balance EDS distribution.
--
-- Settings:
--   snapshot : 2026-01-01
--   dormancy : 5 years
--   alpha    : 0.5%, 1%, 2%, 5%, 10%
--   k        : 1, 3, 5
--   pathways : pi_T, pi_I
--   Nakamoto : tau = 0.33
--
-- pi_T:
--   activated balance is divided equally among k
--   NEW attacker-controlled holders.
--
-- pi_I:
--   activated balance is divided equally among the
--   PRE-SHOCK top-k incumbent holders.
--
-- Expected output:
--   5 alpha × 3 k × 2 pathways = 30 rows
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
-- 2. Corrected address balances
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
-- 3. Pre-shock deterministic holder ranking
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

-- ------------------------------------------------------------
-- 4. Baseline total
-- ------------------------------------------------------------
totals AS (
  SELECT
    COUNT(*) AS baseline_holder_count,
    SUM(balance_sats) AS total_sats

  FROM positive
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
-- 6. Baseline Nakamoto(33%)
-- ------------------------------------------------------------
baseline_ordered AS (
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

baseline_naka AS (
  SELECT
    MIN(o.holder_number) AS baseline_nakamoto_33

  FROM baseline_ordered o
  CROSS JOIN totals t

  WHERE
    CAST(o.cumulative_sats AS NUMERIC)
      >= NUMERIC '0.33'
         * CAST(t.total_sats AS NUMERIC)
),

-- ------------------------------------------------------------
-- 7. Parameter grids
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

k_grid AS (
  SELECT k
  FROM UNNEST([1, 3, 5]) AS k
),

-- ============================================================
-- 8. Construct post-shock holder distributions
-- ============================================================
scenario_balances AS (

  -- ==========================================================
  -- pi_T incumbents
  -- ==========================================================
  SELECT
    a.alpha,
    k.k,
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
  CROSS JOIN k_grid k


  UNION ALL


  -- ==========================================================
  -- pi_T new attacker holders
  -- ==========================================================
  SELECT
    a.alpha,
    k.k,
    'pi_T' AS scenario,

    CONCAT(
      'new_attacker:',
      LPAD(CAST(attacker_no AS STRING), 2, '0')
    ) AS holder_id,

    SAFE_DIVIDE(
      a.alpha * CAST(t.total_sats AS NUMERIC),
      CAST(k.k AS NUMERIC)
    ) AS post_balance_sats

  FROM alpha_grid a
  CROSS JOIN k_grid k
  CROSS JOIN totals t
  CROSS JOIN UNNEST(
    GENERATE_ARRAY(1, k.k)
  ) AS attacker_no


  UNION ALL


  -- ==========================================================
  -- pi_I
  --
  -- No new holders.
  -- alpha share distributed equally among PRE-SHOCK
  -- top-k incumbent holders.
  -- ==========================================================
  SELECT
    a.alpha,
    k.k,
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
      WHEN b.baseline_rank <= k.k
      THEN
        SAFE_DIVIDE(
          a.alpha * CAST(t.total_sats AS NUMERIC),
          CAST(k.k AS NUMERIC)
        )
      ELSE NUMERIC '0'
    END AS post_balance_sats

  FROM baseline_ranked b
  CROSS JOIN alpha_grid a
  CROSS JOIN k_grid k
  CROSS JOIN totals t
),

-- ------------------------------------------------------------
-- 9. Scenario totals and HHI
-- ------------------------------------------------------------
scenario_summary AS (
  SELECT
    s.alpha,
    s.k,
    s.scenario,

    COUNT(*) AS holder_count,

    SUM(
      s.post_balance_sats
    ) AS post_total_sats,

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
    s.k,
    s.scenario
),

-- ------------------------------------------------------------
-- 10. Scenario Nakamoto
-- ------------------------------------------------------------
scenario_ordered AS (
  SELECT
    alpha,
    k,
    scenario,
    holder_id,
    post_balance_sats,

    ROW_NUMBER() OVER (
      PARTITION BY alpha, k, scenario
      ORDER BY post_balance_sats DESC, holder_id ASC
    ) AS holder_number,

    SUM(post_balance_sats) OVER (
      PARTITION BY alpha, k, scenario
      ORDER BY post_balance_sats DESC, holder_id ASC
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_sats

  FROM scenario_balances

  WHERE post_balance_sats > 0
),

scenario_naka AS (
  SELECT
    o.alpha,
    o.k,
    o.scenario,

    MIN(o.holder_number) AS nakamoto_33

  FROM scenario_ordered o
  CROSS JOIN totals t

  WHERE
    o.cumulative_sats
      >= NUMERIC '0.33'
         * CAST(t.total_sats AS NUMERIC)

  GROUP BY
    o.alpha,
    o.k,
    o.scenario
)

-- ============================================================
-- 11. Final output
-- ============================================================
SELECT
  CAST(
    s.alpha * NUMERIC '100'
    AS FLOAT64
  ) AS alpha_percent,

  s.k,

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

  bn.baseline_nakamoto_33,

  n.nakamoto_33,

  n.nakamoto_33
    - bn.baseline_nakamoto_33
    AS delta_nakamoto,

  CASE
    WHEN s.hhi < bh.baseline_hhi
      THEN 'IMPROVED'
    WHEN s.hhi > bh.baseline_hhi
      THEN 'DETERIORATED'
    ELSE 'EQUAL'
  END AS hhi_direction,

  CASE
    WHEN n.nakamoto_33 > bn.baseline_nakamoto_33
      THEN 'IMPROVED'
    WHEN n.nakamoto_33 < bn.baseline_nakamoto_33
      THEN 'DETERIORATED'
    ELSE 'EQUAL'
  END AS naka_direction

FROM scenario_summary s

JOIN scenario_naka n
  USING (
    alpha,
    k,
    scenario
  )

CROSS JOIN totals t
CROSS JOIN baseline_hhi bh
CROSS JOIN baseline_naka bn

ORDER BY
  s.alpha,
  s.k,

  CASE s.scenario
    WHEN 'pi_T' THEN 1
    WHEN 'pi_I' THEN 2
  END;
