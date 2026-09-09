-- ============================================================
-- 03_main_stress_bip30_corrected.sql
--
-- Canonical main stress test
-- Source: eds_utxo_20260101_t5
-- BIP30 correction applied in-query
--
-- Main settings
--   snapshot   : 2026-01-01
--   dormancy   : 5 years
--   pi_D       : m = 10,000 new recipients
--   pi_T       : k = 3 new attacker entities
--   pi_I       : k = 3 pre-shock top incumbent holders
--   alpha      : 0.5%, 1%, 2%, 5%, 10%
--   Nakamoto   : tau = 0.33
-- ============================================================


WITH

-- ------------------------------------------------------------
-- 1. Reconstruct BIP30-corrected UTXO set
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
-- 2. Rebuild address-level balances
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

totals AS (
  SELECT
    SUM(balance_sats) AS total_sats
  FROM positive
),

-- ------------------------------------------------------------
-- 3. Rank PRE-SHOCK holders
--    Used only for pi_I incumbent selection
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
-- 4. Baseline metrics
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
    MIN(holder_number) AS baseline_nakamoto_33
  FROM baseline_ordered
  CROSS JOIN totals
  WHERE cumulative_sats * 100 >= total_sats * 33
),

-- ------------------------------------------------------------
-- 5. Alpha grid
--
-- NUMERIC is used intentionally so redistribution arithmetic
-- remains deterministic.
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

-- ============================================================
-- 6. Build all post-shock holder distributions
-- ============================================================
scenario_balances AS (

  -- ----------------------------------------------------------
  -- pi_D: defensive dispersion
  -- Existing holders retain (1-alpha)b_i
  -- Activated balance is divided equally among
  -- 10,000 NEW recipient addresses.
  -- ----------------------------------------------------------

  SELECT
    a.alpha,
    'pi_D' AS scenario,
    CONCAT('incumbent:', p.address) AS holder_id,

    CAST(p.balance_sats AS NUMERIC)
      * (NUMERIC '1' - a.alpha) AS post_balance_sats

  FROM positive p
  CROSS JOIN alpha_grid a


  UNION ALL


  SELECT
    a.alpha,
    'pi_D' AS scenario,

    CONCAT(
      'new_dispersion:',
      LPAD(CAST(recipient_no AS STRING), 5, '0')
    ) AS holder_id,

    SAFE_DIVIDE(
      a.alpha * CAST(t.total_sats AS NUMERIC),
      NUMERIC '10000'
    ) AS post_balance_sats

  FROM alpha_grid a
  CROSS JOIN totals t
  CROSS JOIN UNNEST(GENERATE_ARRAY(1, 10000)) AS recipient_no


  UNION ALL


  -- ----------------------------------------------------------
  -- pi_T: theft aggregation
  -- Existing holders retain (1-alpha)b_i
  -- Activated balance is divided equally among
  -- 3 NEW attacker-controlled entities.
  -- ----------------------------------------------------------

  SELECT
    a.alpha,
    'pi_T' AS scenario,
    CONCAT('incumbent:', p.address) AS holder_id,

    CAST(p.balance_sats AS NUMERIC)
      * (NUMERIC '1' - a.alpha) AS post_balance_sats

  FROM positive p
  CROSS JOIN alpha_grid a


  UNION ALL


  SELECT
    a.alpha,
    'pi_T' AS scenario,

    CONCAT(
      'new_attacker:',
      CAST(attacker_no AS STRING)
    ) AS holder_id,

    SAFE_DIVIDE(
      a.alpha * CAST(t.total_sats AS NUMERIC),
      NUMERIC '3'
    ) AS post_balance_sats

  FROM alpha_grid a
  CROSS JOIN totals t
  CROSS JOIN UNNEST(GENERATE_ARRAY(1, 3)) AS attacker_no


  UNION ALL


  -- ----------------------------------------------------------
  -- pi_I: managed institutional transition
  -- Activated balance is absorbed by the PRE-SHOCK
  -- top-3 incumbent holders.
  --
  -- No new holder IDs are created.
  -- ----------------------------------------------------------

  SELECT
    a.alpha,
    'pi_I' AS scenario,
    CONCAT('incumbent:', b.address) AS holder_id,

    (
      CAST(b.balance_sats AS NUMERIC)
        * (NUMERIC '1' - a.alpha)
    )
    +
    CASE
      WHEN b.baseline_rank <= 3 THEN
        SAFE_DIVIDE(
          a.alpha * CAST(t.total_sats AS NUMERIC),
          NUMERIC '3'
        )
      ELSE NUMERIC '0'
    END AS post_balance_sats

  FROM baseline_ranked b
  CROSS JOIN alpha_grid a
  CROSS JOIN totals t
),

-- ------------------------------------------------------------
-- 7. Scenario totals + HHI
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
-- 8. Actual-holder Nakamoto coefficient
--
-- IMPORTANT:
-- ROW_NUMBER(), not RANK().
-- Holder ID supplies deterministic tie ordering.
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

scenario_naka AS (
  SELECT
    o.alpha,
    o.scenario,

    MIN(o.holder_number) AS nakamoto_33

  FROM scenario_ordered o
  CROSS JOIN totals t

  WHERE
    o.cumulative_sats
      >= NUMERIC '0.33' * CAST(t.total_sats AS NUMERIC)

  GROUP BY
    o.alpha,
    o.scenario
)

-- ============================================================
-- 9. Final 15-row output
-- ============================================================
SELECT
  CAST(s.alpha * NUMERIC '100' AS FLOAT64)
    AS alpha_percent,

  s.scenario,

  s.holder_count,

  s.post_total_sats,

  s.post_total_sats
    - CAST(t.total_sats AS NUMERIC)
    AS supply_diff_sats,

  s.hhi,

  n.nakamoto_33,

  bh.baseline_hhi,

  bn.baseline_nakamoto_33,

  s.hhi - bh.baseline_hhi
    AS delta_hhi,

  n.nakamoto_33 - bn.baseline_nakamoto_33
    AS delta_nakamoto

FROM scenario_summary s

JOIN scenario_naka n
  USING (alpha, scenario)

CROSS JOIN totals t
CROSS JOIN baseline_hhi bh
CROSS JOIN baseline_naka bn

ORDER BY
  s.alpha,
  CASE s.scenario
    WHEN 'pi_D' THEN 1
    WHEN 'pi_T' THEN 2
    WHEN 'pi_I' THEN 3
  END;
