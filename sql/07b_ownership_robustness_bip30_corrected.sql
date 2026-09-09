-- ============================================================
-- 07b_ownership_robustness_bip30_corrected.sql
--
-- Ownership-definition robustness using BIP30-corrected
-- balances joined to the existing Track-A membership mapping.
--
-- Ownership models:
--   1. Address
--   2. SpendingHistoryBound
--   3. PublicLabel
--   4. Combined
--
-- Stress settings:
--   alpha = 0.5%, 1%, 2%, 5%, 10%
--   pi_D  = m = 10,000 new recipients
--   pi_T  = k = 3 new attacker entities
--   pi_I  = k = 3 pre-shock top incumbent entities
--   Nakamoto threshold = 33%
--
-- Expected output:
--   4 models × 5 alpha × 3 pathways = 60 rows
-- ============================================================

WITH

-- ------------------------------------------------------------
-- 1. BIP30-corrected UTXO source
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
-- 2. Track-A membership only
--
-- IMPORTANT:
-- old Track-A balance_sats is intentionally ignored.
-- ------------------------------------------------------------
trackA AS (
  SELECT
    address,

    IFNULL(common_input_member, FALSE)
      AS common_input_member,

    IFNULL(public_label_member, FALSE)
      AS public_label_member,

    common_input_bound_group,

    public_label_actor,
    public_label_name,

    combined_entity_id

  FROM `sixth-wave-484005-t0.btc_eds_ljw.trackA_entity_membership_v1`
),

-- ------------------------------------------------------------
-- 3. Join CORRECTED balances to ownership membership
-- ------------------------------------------------------------
joined AS (
  SELECT
    p.address,
    p.balance_sats,

    t.common_input_member,
    t.public_label_member,

    t.common_input_bound_group,

    t.public_label_actor,
    t.public_label_name,

    t.combined_entity_id

  FROM positive p

  JOIN trackA t
    USING (address)
),

-- ============================================================
-- 4. Construct four ownership definitions
-- ============================================================
ownership_assignment AS (

  -- ----------------------------------------------------------
  -- Address-level baseline
  -- ----------------------------------------------------------
  SELECT
    'Address' AS ownership_model,
    1 AS model_order,

    address,

    CONCAT(
      'ADDR:',
      address
    ) AS entity_id,

    balance_sats

  FROM joined


  UNION ALL


  -- ----------------------------------------------------------
  -- Spending-history observable bound
  --
  -- Only mapped members are merged.
  -- All other addresses remain singletons.
  -- ----------------------------------------------------------
  SELECT
    'SpendingHistoryBound' AS ownership_model,
    2 AS model_order,

    address,

    CASE
      WHEN common_input_member
       AND common_input_bound_group IS NOT NULL
      THEN CONCAT(
        'CI_GROUP:',
        common_input_bound_group
      )

      ELSE CONCAT(
        'ADDR:',
        address
      )
    END AS entity_id,

    balance_sats

  FROM joined


  UNION ALL


  -- ----------------------------------------------------------
  -- Public-label aggregation
  --
  -- Only explicitly labelled members are merged.
  -- ----------------------------------------------------------
  SELECT
    'PublicLabel' AS ownership_model,
    3 AS model_order,

    address,

    CASE
      WHEN public_label_member
       AND COALESCE(
             public_label_actor,
             public_label_name
           ) IS NOT NULL
      THEN CONCAT(
        'PUBLIC:',
        COALESCE(
          public_label_actor,
          public_label_name
        )
      )

      ELSE CONCAT(
        'ADDR:',
        address
      )
    END AS entity_id,

    balance_sats

  FROM joined


  UNION ALL


  -- ----------------------------------------------------------
  -- Combined Track-A mapping
  --
  -- Existing combined_entity_id is retained.
  -- Missing IDs, if any, fail safely to singletons.
  -- ----------------------------------------------------------
  SELECT
    'Combined' AS ownership_model,
    4 AS model_order,

    address,

    CASE
      WHEN combined_entity_id IS NOT NULL
      THEN CONCAT(
        'COMBINED:',
        combined_entity_id
      )

      ELSE CONCAT(
        'ADDR:',
        address
      )
    END AS entity_id,

    balance_sats

  FROM joined
),

-- ------------------------------------------------------------
-- 5. Aggregate addresses into entities
-- ------------------------------------------------------------
entity_balances AS (
  SELECT
    ownership_model,
    model_order,
    entity_id,

    SUM(balance_sats) AS balance_sats

  FROM ownership_assignment

  GROUP BY
    ownership_model,
    model_order,
    entity_id
),

-- ------------------------------------------------------------
-- 6. Model totals
-- ------------------------------------------------------------
model_totals AS (
  SELECT
    ownership_model,
    model_order,

    COUNT(*) AS baseline_holder_count,

    SUM(balance_sats) AS baseline_total_sats

  FROM entity_balances

  GROUP BY
    ownership_model,
    model_order
),

-- ------------------------------------------------------------
-- 7. Pre-shock entity ranking
-- ------------------------------------------------------------
baseline_ranked AS (
  SELECT
    ownership_model,
    model_order,
    entity_id,
    balance_sats,

    ROW_NUMBER() OVER (
      PARTITION BY ownership_model
      ORDER BY balance_sats DESC, entity_id ASC
    ) AS baseline_rank

  FROM entity_balances
),

-- ------------------------------------------------------------
-- 8. Baseline HHI
-- ------------------------------------------------------------
baseline_hhi AS (
  SELECT
    b.ownership_model,

    SUM(
      POW(
        SAFE_DIVIDE(
          CAST(b.balance_sats AS FLOAT64),
          CAST(t.baseline_total_sats AS FLOAT64)
        ),
        2
      )
    ) AS baseline_hhi

  FROM entity_balances b

  JOIN model_totals t
    USING (ownership_model)

  GROUP BY
    b.ownership_model
),

-- ------------------------------------------------------------
-- 9. Baseline Nakamoto(33%)
-- ------------------------------------------------------------
baseline_ordered AS (
  SELECT
    ownership_model,
    entity_id,
    balance_sats,
    baseline_rank AS holder_number,

    SUM(balance_sats) OVER (
      PARTITION BY ownership_model
      ORDER BY baseline_rank
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_sats

  FROM baseline_ranked
),

baseline_naka AS (
  SELECT
    o.ownership_model,

    MIN(o.holder_number)
      AS baseline_nakamoto_33

  FROM baseline_ordered o

  JOIN model_totals t
    USING (ownership_model)

  WHERE
    CAST(o.cumulative_sats AS NUMERIC)
      >= NUMERIC '0.33'
         * CAST(t.baseline_total_sats AS NUMERIC)

  GROUP BY
    o.ownership_model
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
-- 11. Construct stress distributions
-- ============================================================
scenario_balances AS (

  -- ==========================================================
  -- pi_D incumbents
  -- ==========================================================
  SELECT
    b.ownership_model,
    b.model_order,
    a.alpha,

    'pi_D' AS scenario,

    CONCAT(
      'INCUMBENT:',
      b.entity_id
    ) AS holder_id,

    CAST(b.balance_sats AS NUMERIC)
      * (NUMERIC '1' - a.alpha)
      AS post_balance_sats

  FROM entity_balances b
  CROSS JOIN alpha_grid a


  UNION ALL


  -- ==========================================================
  -- pi_D: 10,000 new recipients
  -- ==========================================================
  SELECT
    t.ownership_model,
    t.model_order,
    a.alpha,

    'pi_D' AS scenario,

    CONCAT(
      'NEW_DISPERSION:',
      LPAD(
        CAST(recipient_no AS STRING),
        5,
        '0'
      )
    ) AS holder_id,

    SAFE_DIVIDE(
      a.alpha
        * CAST(t.baseline_total_sats AS NUMERIC),
      NUMERIC '10000'
    ) AS post_balance_sats

  FROM model_totals t
  CROSS JOIN alpha_grid a
  CROSS JOIN UNNEST(
    GENERATE_ARRAY(1, 10000)
  ) AS recipient_no


  UNION ALL


  -- ==========================================================
  -- pi_T incumbents
  -- ==========================================================
  SELECT
    b.ownership_model,
    b.model_order,
    a.alpha,

    'pi_T' AS scenario,

    CONCAT(
      'INCUMBENT:',
      b.entity_id
    ) AS holder_id,

    CAST(b.balance_sats AS NUMERIC)
      * (NUMERIC '1' - a.alpha)
      AS post_balance_sats

  FROM entity_balances b
  CROSS JOIN alpha_grid a


  UNION ALL


  -- ==========================================================
  -- pi_T: 3 new attacker entities
  -- ==========================================================
  SELECT
    t.ownership_model,
    t.model_order,
    a.alpha,

    'pi_T' AS scenario,

    CONCAT(
      'NEW_ATTACKER:',
      CAST(attacker_no AS STRING)
    ) AS holder_id,

    SAFE_DIVIDE(
      a.alpha
        * CAST(t.baseline_total_sats AS NUMERIC),
      NUMERIC '3'
    ) AS post_balance_sats

  FROM model_totals t
  CROSS JOIN alpha_grid a
  CROSS JOIN UNNEST(
    GENERATE_ARRAY(1, 3)
  ) AS attacker_no


  UNION ALL


  -- ==========================================================
  -- pi_I:
  -- activated balance goes to PRE-SHOCK top-3 entities
  -- ==========================================================
  SELECT
    b.ownership_model,
    b.model_order,
    a.alpha,

    'pi_I' AS scenario,

    CONCAT(
      'INCUMBENT:',
      b.entity_id
    ) AS holder_id,

    (
      CAST(b.balance_sats AS NUMERIC)
        * (NUMERIC '1' - a.alpha)
    )
    +
    CASE
      WHEN b.baseline_rank <= 3
      THEN SAFE_DIVIDE(
        a.alpha
          * CAST(t.baseline_total_sats AS NUMERIC),
        NUMERIC '3'
      )

      ELSE NUMERIC '0'
    END AS post_balance_sats

  FROM baseline_ranked b

  JOIN model_totals t
    USING (ownership_model)

  CROSS JOIN alpha_grid a
),

-- ------------------------------------------------------------
-- 12. Scenario totals + HHI
-- ------------------------------------------------------------
scenario_summary AS (
  SELECT
    s.ownership_model,
    s.model_order,
    s.alpha,
    s.scenario,

    COUNT(*) AS holder_count,

    SUM(s.post_balance_sats)
      AS post_total_sats,

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

  JOIN model_totals t
    USING (ownership_model)

  WHERE s.post_balance_sats > 0

  GROUP BY
    s.ownership_model,
    s.model_order,
    s.alpha,
    s.scenario
),

-- ------------------------------------------------------------
-- 13. Scenario Nakamoto
-- ------------------------------------------------------------
scenario_ordered AS (
  SELECT
    ownership_model,
    model_order,
    alpha,
    scenario,
    holder_id,
    post_balance_sats,

    ROW_NUMBER() OVER (
      PARTITION BY
        ownership_model,
        alpha,
        scenario
      ORDER BY
        post_balance_sats DESC,
        holder_id ASC
    ) AS holder_number,

    SUM(post_balance_sats) OVER (
      PARTITION BY
        ownership_model,
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
    o.ownership_model,
    o.alpha,
    o.scenario,

    MIN(o.holder_number)
      AS nakamoto_33

  FROM scenario_ordered o

  JOIN model_totals t
    USING (ownership_model)

  WHERE
    o.cumulative_sats
      >= NUMERIC '0.33'
         * CAST(t.baseline_total_sats AS NUMERIC)

  GROUP BY
    o.ownership_model,
    o.alpha,
    o.scenario
)

-- ============================================================
-- 14. Final 60-row output
-- ============================================================
SELECT
  s.ownership_model,

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
    WHEN n.nakamoto_33
         > bn.baseline_nakamoto_33
      THEN 'IMPROVED'

    WHEN n.nakamoto_33
         < bn.baseline_nakamoto_33
      THEN 'DETERIORATED'

    ELSE 'EQUAL'
  END AS naka_direction

FROM scenario_summary s

JOIN scenario_naka n
  USING (
    ownership_model,
    alpha,
    scenario
  )

JOIN model_totals t
  USING (ownership_model)

JOIN baseline_hhi bh
  USING (ownership_model)

JOIN baseline_naka bn
  USING (ownership_model)

ORDER BY
  s.model_order,
  s.alpha,

  CASE s.scenario
    WHEN 'pi_D' THEN 1
    WHEN 'pi_T' THEN 2
    WHEN 'pi_I' THEN 3
  END;
