-- ============================================================
-- 05_topN_sensitivity_bip30_corrected.sql
--
-- Top-N sensitivity analysis using BIP30-corrected EDS.
--
-- Populations:
--   Top 500
--   Top 1,000
--   Top 2,000
--   Full positive-balance distribution
--
-- IMPORTANT:
-- Each population is internally normalized to its own total.
--
-- Stress settings:
--   alpha = 0.5%, 1%, 2%, 5%, 10%
--   pi_D  = 10,000 new recipients
--   pi_T  = 3 new attacker entities
--   pi_I  = 3 pre-shock top incumbent holders
--   Nakamoto threshold = 33%
--
-- Expected output:
--   4 populations × 5 alpha × 3 pathways = 60 rows
-- ============================================================

WITH

-- ------------------------------------------------------------
-- 1. BIP30-corrected UTXO set
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
-- 2. Address-level positive balances
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
-- 3. Rank corrected full distribution once
--
-- ROW_NUMBER is used deliberately.
-- address ASC provides deterministic tie ordering.
-- ------------------------------------------------------------
full_ranked AS (
  SELECT
    address,
    balance_sats,

    ROW_NUMBER() OVER (
      ORDER BY balance_sats DESC, address ASC
    ) AS full_rank

  FROM positive
),

-- ------------------------------------------------------------
-- 4. Define sensitivity populations
-- ------------------------------------------------------------
cutoff_defs AS (
  SELECT 'Top500' AS population, 500 AS cutoff_n, 1 AS population_order
  UNION ALL
  SELECT 'Top1000', 1000, 2
  UNION ALL
  SELECT 'Top2000', 2000, 3
  UNION ALL
  SELECT 'Full', NULL, 4
),

-- ------------------------------------------------------------
-- 5. Construct each internally-normalized population
-- ------------------------------------------------------------
population_members AS (
  SELECT
    c.population,
    c.population_order,
    c.cutoff_n,

    f.address,
    f.balance_sats,
    f.full_rank

  FROM cutoff_defs c
  CROSS JOIN full_ranked f

  WHERE c.cutoff_n IS NULL
     OR f.full_rank <= c.cutoff_n
),

-- ------------------------------------------------------------
-- 6. Pre-shock rank WITHIN each population
-- ------------------------------------------------------------
population_ranked AS (
  SELECT
    population,
    population_order,
    cutoff_n,
    address,
    balance_sats,
    full_rank,

    ROW_NUMBER() OVER (
      PARTITION BY population
      ORDER BY balance_sats DESC, address ASC
    ) AS population_rank

  FROM population_members
),

-- ------------------------------------------------------------
-- 7. Population totals
-- ------------------------------------------------------------
population_totals AS (
  SELECT
    population,
    population_order,

    COUNT(*) AS baseline_holder_count,
    SUM(balance_sats) AS baseline_total_sats

  FROM population_ranked

  GROUP BY
    population,
    population_order
),

-- ------------------------------------------------------------
-- 8. Baseline HHI for each population
-- ------------------------------------------------------------
baseline_hhi AS (
  SELECT
    p.population,

    SUM(
      POW(
        SAFE_DIVIDE(
          CAST(p.balance_sats AS FLOAT64),
          CAST(t.baseline_total_sats AS FLOAT64)
        ),
        2
      )
    ) AS baseline_hhi

  FROM population_ranked p

  JOIN population_totals t
    USING (population)

  GROUP BY p.population
),

-- ------------------------------------------------------------
-- 9. Baseline Nakamoto(33%) for each population
-- ------------------------------------------------------------
baseline_ordered AS (
  SELECT
    population,
    address,
    balance_sats,
    population_rank AS holder_number,

    SUM(balance_sats) OVER (
      PARTITION BY population
      ORDER BY population_rank
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_sats

  FROM population_ranked
),

baseline_naka AS (
  SELECT
    o.population,

    MIN(o.holder_number) AS baseline_nakamoto_33

  FROM baseline_ordered o

  JOIN population_totals t
    USING (population)

  WHERE
    CAST(o.cumulative_sats AS NUMERIC)
      >= NUMERIC '0.33'
         * CAST(t.baseline_total_sats AS NUMERIC)

  GROUP BY o.population
),

-- ------------------------------------------------------------
-- 10. Alpha grid
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
-- 11. Build post-shock distributions
-- ============================================================
scenario_balances AS (

  -- ==========================================================
  -- pi_D
  -- Existing holders retain (1-alpha).
  -- alpha share goes to 10,000 NEW recipients.
  -- ==========================================================

  SELECT
    p.population,
    p.population_order,
    a.alpha,

    'pi_D' AS scenario,

    CONCAT(
      'incumbent:',
      p.address
    ) AS holder_id,

    CAST(p.balance_sats AS NUMERIC)
      * (NUMERIC '1' - a.alpha)
      AS post_balance_sats

  FROM population_ranked p
  CROSS JOIN alpha_grid a


  UNION ALL


  SELECT
    t.population,
    t.population_order,
    a.alpha,

    'pi_D' AS scenario,

    CONCAT(
      'new_dispersion:',
      LPAD(CAST(recipient_no AS STRING), 5, '0')
    ) AS holder_id,

    SAFE_DIVIDE(
      a.alpha
        * CAST(t.baseline_total_sats AS NUMERIC),
      NUMERIC '10000'
    ) AS post_balance_sats

  FROM population_totals t
  CROSS JOIN alpha_grid a
  CROSS JOIN UNNEST(
    GENERATE_ARRAY(1, 10000)
  ) AS recipient_no


  UNION ALL


  -- ==========================================================
  -- pi_T
  -- alpha share goes to 3 NEW attacker entities.
  -- ==========================================================

  SELECT
    p.population,
    p.population_order,
    a.alpha,

    'pi_T' AS scenario,

    CONCAT(
      'incumbent:',
      p.address
    ) AS holder_id,

    CAST(p.balance_sats AS NUMERIC)
      * (NUMERIC '1' - a.alpha)
      AS post_balance_sats

  FROM population_ranked p
  CROSS JOIN alpha_grid a


  UNION ALL


  SELECT
    t.population,
    t.population_order,
    a.alpha,

    'pi_T' AS scenario,

    CONCAT(
      'new_attacker:',
      CAST(attacker_no AS STRING)
    ) AS holder_id,

    SAFE_DIVIDE(
      a.alpha
        * CAST(t.baseline_total_sats AS NUMERIC),
      NUMERIC '3'
    ) AS post_balance_sats

  FROM population_totals t
  CROSS JOIN alpha_grid a
  CROSS JOIN UNNEST(
    GENERATE_ARRAY(1, 3)
  ) AS attacker_no


  UNION ALL


  -- ==========================================================
  -- pi_I
  -- alpha share goes to the PRE-SHOCK top-3 incumbents
  -- WITHIN each population.
  -- No new holder IDs.
  -- ==========================================================

  SELECT
    p.population,
    p.population_order,
    a.alpha,

    'pi_I' AS scenario,

    CONCAT(
      'incumbent:',
      p.address
    ) AS holder_id,

    (
      CAST(p.balance_sats AS NUMERIC)
        * (NUMERIC '1' - a.alpha)
    )
    +
    CASE
      WHEN p.population_rank <= 3
      THEN
        SAFE_DIVIDE(
          a.alpha
            * CAST(t.baseline_total_sats AS NUMERIC),
          NUMERIC '3'
        )
      ELSE NUMERIC '0'
    END AS post_balance_sats

  FROM population_ranked p

  JOIN population_totals t
    USING (population)

  CROSS JOIN alpha_grid a
),

-- ------------------------------------------------------------
-- 12. Scenario totals and HHI
-- ------------------------------------------------------------
scenario_summary AS (
  SELECT
    s.population,
    s.population_order,
    s.alpha,
    s.scenario,

    COUNT(*) AS holder_count,

    SUM(
      s.post_balance_sats
    ) AS post_total_sats,

    SUM(
      POW(
        SAFE_DIVIDE(
          CAST(s.post_balance_sats AS FLOAT64),
          CAST(t.baseline_total_sats AS FLOAT64)
        ),
        2
      )
    ) AS hhi

  FROM scenario_balances s

  JOIN population_totals t
    USING (population)

  WHERE s.post_balance_sats > 0

  GROUP BY
    s.population,
    s.population_order,
    s.alpha,
    s.scenario
),

-- ------------------------------------------------------------
-- 13. Scenario Nakamoto
--
-- Again: ROW_NUMBER, not RANK.
-- ------------------------------------------------------------
scenario_ordered AS (
  SELECT
    population,
    population_order,
    alpha,
    scenario,
    holder_id,
    post_balance_sats,

    ROW_NUMBER() OVER (
      PARTITION BY
        population,
        alpha,
        scenario
      ORDER BY
        post_balance_sats DESC,
        holder_id ASC
    ) AS holder_number,

    SUM(post_balance_sats) OVER (
      PARTITION BY
        population,
        alpha,
        scenario
      ORDER BY
        post_balance_sats DESC,
        holder_id ASC
      ROWS BETWEEN
        UNBOUNDED PRECEDING
        AND CURRENT ROW
    ) AS cumulative_sats

  FROM scenario_balances

  WHERE post_balance_sats > 0
),

scenario_naka AS (
  SELECT
    o.population,
    o.alpha,
    o.scenario,

    MIN(
      o.holder_number
    ) AS nakamoto_33

  FROM scenario_ordered o

  JOIN population_totals t
    USING (population)

  WHERE
    o.cumulative_sats
      >= NUMERIC '0.33'
         * CAST(t.baseline_total_sats AS NUMERIC)

  GROUP BY
    o.population,
    o.alpha,
    o.scenario
)

-- ============================================================
-- 14. Final 60-row output
-- ============================================================
SELECT
  s.population,

  t.baseline_holder_count,

  t.baseline_total_sats,

  bh.baseline_hhi,

  bn.baseline_nakamoto_33,

  CAST(
    s.alpha * NUMERIC '100'
    AS FLOAT64
  ) AS alpha_percent,

  s.scenario,

  s.holder_count,

  s.post_total_sats,

  s.post_total_sats
    - CAST(t.baseline_total_sats AS NUMERIC)
    AS supply_diff_sats,

  s.hhi,

  n.nakamoto_33,

  s.hhi - bh.baseline_hhi
    AS delta_hhi,

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
    population,
    alpha,
    scenario
  )

JOIN population_totals t
  USING (population)

JOIN baseline_hhi bh
  USING (population)

JOIN baseline_naka bn
  USING (population)

ORDER BY
  s.population_order,
  s.alpha,

  CASE s.scenario
    WHEN 'pi_D' THEN 1
    WHEN 'pi_T' THEN 2
    WHEN 'pi_I' THEN 3
  END;
