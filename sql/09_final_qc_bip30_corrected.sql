-- ============================================================
-- 09_final_qc_bip30_corrected.sql
--
-- FINAL QC for canonical BIP30-corrected
-- 2026-01-01 / 5-year EDS analysis.
--
-- Creates NO permanent tables.
-- ============================================================

WITH

-- ============================================================
-- 1. Diagnose original duplicate outpoints
-- ============================================================
raw_duplicate_detail AS (
  SELECT
    created_tx_hash,
    created_vout,
    COUNT(*) AS n,
    COUNT(DISTINCT value_sats) AS distinct_values,
    MIN(value_sats) AS min_value_sats,
    MAX(value_sats) AS max_value_sats

  FROM `sixth-wave-484005-t0.btc_eds_ljw.eds_utxo_20260101_t5`

  GROUP BY
    created_tx_hash,
    created_vout

  HAVING COUNT(*) > 1
),

raw_duplicate_summary AS (
  SELECT
    COUNT(*) AS raw_duplicate_groups,

    COUNTIF(
      created_tx_hash IN (
        'd5d27987d2a3dfc724e359870c6644b40e497bdc0589a033220fe15429d88599',
        'e3bf3d07d4b0375638d5f1db5255fe07ba2c4cb067cd81b84ee974b6585fb468'
      )
      AND created_vout = 0
      AND n = 2
      AND distinct_values = 1
      AND min_value_sats = 5000000000
      AND max_value_sats = 5000000000
    ) AS valid_known_bip30_groups

  FROM raw_duplicate_detail
),

-- ============================================================
-- 2. Apply BIP30 correction
-- ============================================================
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

corrected_duplicate_summary AS (
  SELECT
    COUNT(*) AS corrected_duplicate_groups

  FROM (
    SELECT
      created_tx_hash,
      created_vout

    FROM corrected_utxo

    GROUP BY
      created_tx_hash,
      created_vout

    HAVING COUNT(*) > 1
  )
),

-- ============================================================
-- 3. Corrected address balances
-- ============================================================
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

-- ============================================================
-- 4. Canonical baseline HHI
--
-- IMPORTANT:
-- CTE name and field name are deliberately different.
-- ============================================================
baseline_hhi_calc AS (
  SELECT
    SUM(
      POW(
        SAFE_DIVIDE(
          CAST(p.balance_sats AS FLOAT64),
          CAST(t.total_sats AS FLOAT64)
        ),
        2
      )
    ) AS hhi_value

  FROM positive p
  CROSS JOIN totals t
),

-- ============================================================
-- 5. Canonical deterministic holder ordering
-- ============================================================
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

baseline_naka_33_calc AS (
  SELECT
    MIN(o.baseline_rank) AS naka33_value

  FROM baseline_ordered o
  CROSS JOIN totals t

  WHERE
    o.cumulative_sats * 100
      >= t.total_sats * 33
),

-- ============================================================
-- 6. Parameter grids
-- ============================================================
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

-- ============================================================
-- 7. Construct canonical main stress distributions
-- ============================================================
scenario_balances AS (

  -- pi_D incumbents
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


  -- pi_D: 10,000 new recipients
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
  CROSS JOIN UNNEST(
    GENERATE_ARRAY(1, 10000)
  ) AS recipient_no


  UNION ALL


  -- pi_T incumbents
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


  -- pi_T: 3 new attacker holders
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
  CROSS JOIN UNNEST(
    GENERATE_ARRAY(1, 3)
  ) AS attacker_no


  UNION ALL


  -- pi_I: pre-shock top-3 incumbents
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
          a.alpha * CAST(t.total_sats AS NUMERIC),
          NUMERIC '3'
        )
      ELSE NUMERIC '0'
    END AS post_balance_sats

  FROM baseline_ranked b
  CROSS JOIN alpha_grid a
  CROSS JOIN totals t
),

-- ============================================================
-- 8. Main scenario HHI + totals
-- ============================================================
scenario_summary AS (
  SELECT
    s.alpha,
    s.scenario,

    COUNT(*) AS holder_count,

    SUM(s.post_balance_sats)
      AS post_total_sats,

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

-- ============================================================
-- 9. Post-shock holder ordering
-- ============================================================
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

-- ============================================================
-- 10. Main Nakamoto(33%)
-- ============================================================
scenario_naka_33 AS (
  SELECT
    o.alpha,
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
    o.scenario
),

main_results AS (
  SELECT
    s.alpha,
    s.scenario,
    s.holder_count,
    s.post_total_sats,
    s.hhi,
    n.nakamoto_33

  FROM scenario_summary s

  JOIN scenario_naka_33 n
    USING (alpha, scenario)
),

-- ============================================================
-- 11. Tau-sensitive baseline Nakamoto coefficients
-- ============================================================
baseline_naka_tau AS (
  SELECT
    g.tau_threshold,

    MIN(o.baseline_rank)
      AS baseline_nakamoto

  FROM baseline_ordered o
  CROSS JOIN totals t
  CROSS JOIN tau_grid g

  WHERE
    CAST(o.cumulative_sats AS NUMERIC)
      >= g.tau_threshold
         * CAST(t.total_sats AS NUMERIC)

  GROUP BY g.tau_threshold
),

-- ============================================================
-- 12. Tau-sensitive post-shock Nakamoto coefficients
-- ============================================================
scenario_naka_tau AS (
  SELECT
    o.alpha,
    o.scenario,
    g.tau_threshold,

    MIN(o.holder_number)
      AS nakamoto

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
),

tau_results AS (
  SELECT
    s.alpha,
    s.scenario,
    s.tau_threshold,
    b.baseline_nakamoto,
    s.nakamoto

  FROM scenario_naka_tau s

  JOIN baseline_naka_tau b
    USING (tau_threshold)
),

-- ============================================================
-- 13. Independent analytic pi_D HHI boundary check
-- ============================================================
hhi_boundary_grid AS (
  SELECT
    a.alpha,
    m,

    (
      POW(
        1.0 - CAST(a.alpha AS FLOAT64),
        2
      )
      * h.hhi_value

      +

      POW(
        CAST(a.alpha AS FLOAT64),
        2
      )
      / CAST(m AS FLOAT64)
    ) AS piD_hhi

  FROM alpha_grid a
  CROSS JOIN baseline_hhi_calc h
  CROSS JOIN UNNEST(
    GENERATE_ARRAY(1, 10000)
  ) AS m
),

hhi_boundaries AS (
  SELECT
    g.alpha,

    MIN(g.m) AS min_m_hhi_improvement

  FROM hhi_boundary_grid g
  CROSS JOIN baseline_hhi_calc h

  WHERE g.piD_hhi < h.hhi_value

  GROUP BY g.alpha
),

-- ============================================================
-- 14. Track-A reconciliation
-- ============================================================
trackA AS (
  SELECT
    address,
    balance_sats AS old_balance_sats

  FROM `sixth-wave-484005-t0.btc_eds_ljw.trackA_entity_membership_v1`
),

trackA_duplicate_summary AS (
  SELECT
    COUNT(*) AS duplicate_address_groups

  FROM (
    SELECT address

    FROM trackA

    GROUP BY address

    HAVING COUNT(*) > 1
  )
),

trackA_reconcile AS (
  SELECT
    COUNTIF(t.address IS NULL)
      AS corrected_addresses_missing_from_trackA,

    COUNTIF(
      t.address IS NOT NULL
      AND t.old_balance_sats != p.balance_sats
    ) AS balance_mismatch_addresses,

    SUM(
      CASE
        WHEN t.address IS NOT NULL
        THEN ABS(
          t.old_balance_sats - p.balance_sats
        )
        ELSE 0
      END
    ) AS total_absolute_balance_difference_sats

  FROM positive p

  LEFT JOIN trackA t
    USING (address)
),

trackA_extra AS (
  SELECT
    COUNT(*) AS trackA_addresses_not_in_corrected_positive

  FROM trackA t

  LEFT JOIN positive p
    USING (address)

  WHERE p.address IS NULL
),

trackA_shape AS (
  SELECT
    COUNT(*) AS trackA_rows,

    COUNT(DISTINCT address)
      AS trackA_distinct_addresses

  FROM trackA
),

-- ============================================================
-- 15. Aggregate QC checks
-- ============================================================
qc AS (
  SELECT

    -- BIP30 source
    (
      (SELECT raw_duplicate_groups
       FROM raw_duplicate_summary) = 2

      AND

      (SELECT valid_known_bip30_groups
       FROM raw_duplicate_summary) = 2
    ) AS bip30_source_pass,

    -- Corrected source
    (
      (SELECT COUNT(*) FROM corrected_utxo) = 42232

      AND

      (SELECT corrected_duplicate_groups
       FROM corrected_duplicate_summary) = 0

      AND

      (SELECT COUNT(*) FROM corrected_addr) = 37566

      AND

      (SELECT COUNT(*) FROM positive) = 37564

      AND

      (SELECT COUNT(*)
       FROM corrected_addr
       WHERE balance_sats = 0) = 2

      AND

      (SELECT total_sats FROM totals)
        = 171831920736257
    ) AS corrected_source_pass,

    -- Baseline
    (
      ABS(
        (SELECT hhi_value FROM baseline_hhi_calc)
        - 3.3559490433565803e-05
      ) < 1e-15

      AND

      (SELECT naka33_value
       FROM baseline_naka_33_calc) = 11162
    ) AS baseline_pass,

    -- Main scenario structure/conservation
    (
      (SELECT COUNT(*) FROM main_results) = 15

      AND

      (
        SELECT MAX(
          ABS(
            post_total_sats
            - CAST(
                (SELECT total_sats FROM totals)
                AS NUMERIC
              )
          )
        )
        FROM main_results
      ) <= NUMERIC '0.000001'

      AND

      (
        SELECT COUNTIF(
          scenario = 'pi_D'
          AND holder_count = 47564
        )
        FROM main_results
      ) = 5

      AND

      (
        SELECT COUNTIF(
          scenario = 'pi_T'
          AND holder_count = 37567
        )
        FROM main_results
      ) = 5

      AND

      (
        SELECT COUNTIF(
          scenario = 'pi_I'
          AND holder_count = 37564
        )
        FROM main_results
      ) = 5
    ) AS main_structure_pass,

    -- Main qualitative direction
    (
      (
        SELECT COUNTIF(
          m.scenario = 'pi_D'
          AND m.hhi < h.hhi_value
          AND m.nakamoto_33 > n.naka33_value
        )

        FROM main_results m
        CROSS JOIN baseline_hhi_calc h
        CROSS JOIN baseline_naka_33_calc n
      ) = 5

      AND

      (
        SELECT COUNTIF(
          m.scenario = 'pi_T'
          AND m.hhi > h.hhi_value
          AND m.nakamoto_33 < n.naka33_value
        )

        FROM main_results m
        CROSS JOIN baseline_hhi_calc h
        CROSS JOIN baseline_naka_33_calc n
      ) = 5

      AND

      (
        SELECT COUNTIF(
          m.scenario = 'pi_I'
          AND m.hhi > h.hhi_value
          AND m.nakamoto_33 < n.naka33_value
        )

        FROM main_results m
        CROSS JOIN baseline_hhi_calc h
        CROSS JOIN baseline_naka_33_calc n
      ) = 5
    ) AS main_direction_pass,

    -- alpha=10% canonical cross-check
    (
      (
        SELECT nakamoto_33
        FROM main_results
        WHERE alpha = NUMERIC '0.10'
          AND scenario = 'pi_D'
      ) = 12422

      AND

      (
        SELECT nakamoto_33
        FROM main_results
        WHERE alpha = NUMERIC '0.10'
          AND scenario = 'pi_T'
      ) = 8606

      AND

      (
        SELECT nakamoto_33
        FROM main_results
        WHERE alpha = NUMERIC '0.10'
          AND scenario = 'pi_I'
      ) = 8603
    ) AS alpha10_crosscheck_pass,

    -- HHI granularity
    (
      (
        SELECT min_m_hhi_improvement
        FROM hhi_boundaries
        WHERE alpha = NUMERIC '0.005'
      ) = 75

      AND

      (
        SELECT min_m_hhi_improvement
        FROM hhi_boundaries
        WHERE alpha = NUMERIC '0.01'
      ) = 150

      AND

      (
        SELECT min_m_hhi_improvement
        FROM hhi_boundaries
        WHERE alpha = NUMERIC '0.02'
      ) = 301

      AND

      (
        SELECT min_m_hhi_improvement
        FROM hhi_boundaries
        WHERE alpha = NUMERIC '0.05'
      ) = 765

      AND

      (
        SELECT min_m_hhi_improvement
        FROM hhi_boundaries
        WHERE alpha = NUMERIC '0.10'
      ) = 1569
    ) AS hhi_granularity_pass,

    -- Tau sensitivity
    (
      (SELECT COUNT(*) FROM tau_results) = 45

      AND

      (
        SELECT baseline_nakamoto
        FROM baseline_naka_tau
        WHERE tau_threshold = NUMERIC '0.25'
      ) = 8412

      AND

      (
        SELECT baseline_nakamoto
        FROM baseline_naka_tau
        WHERE tau_threshold = NUMERIC '0.33'
      ) = 11162

      AND

      (
        SELECT baseline_nakamoto
        FROM baseline_naka_tau
        WHERE tau_threshold = NUMERIC '0.50'
      ) = 17004

      AND

      (
        SELECT COUNTIF(
          scenario = 'pi_D'
          AND nakamoto > baseline_nakamoto
        )
        FROM tau_results
      ) = 15

      AND

      (
        SELECT COUNTIF(
          scenario = 'pi_T'
          AND nakamoto < baseline_nakamoto
        )
        FROM tau_results
      ) = 15

      AND

      (
        SELECT COUNTIF(
          scenario = 'pi_I'
          AND nakamoto < baseline_nakamoto
        )
        FROM tau_results
      ) = 15
    ) AS tau_sensitivity_pass,

    -- Track-A reconciliation
    (
      (
        SELECT trackA_rows
        FROM trackA_shape
      ) = 37564

      AND

      (
        SELECT trackA_distinct_addresses
        FROM trackA_shape
      ) = 37564

      AND

      (
        SELECT duplicate_address_groups
        FROM trackA_duplicate_summary
      ) = 0

      AND

      (
        SELECT corrected_addresses_missing_from_trackA
        FROM trackA_reconcile
      ) = 0

      AND

      (
        SELECT trackA_addresses_not_in_corrected_positive
        FROM trackA_extra
      ) = 0

      AND

      (
        SELECT balance_mismatch_addresses
        FROM trackA_reconcile
      ) = 2

      AND

      (
        SELECT total_absolute_balance_difference_sats
        FROM trackA_reconcile
      ) = 10000000000
    ) AS trackA_reconcile_pass
)

-- ============================================================
-- 16. FINAL OUTPUT
-- ============================================================
SELECT
  CASE
    WHEN
      bip30_source_pass
      AND corrected_source_pass
      AND baseline_pass
      AND main_structure_pass
      AND main_direction_pass
      AND alpha10_crosscheck_pass
      AND hhi_granularity_pass
      AND tau_sensitivity_pass
      AND trackA_reconcile_pass
    THEN 'PASS'
    ELSE 'FAIL'
  END AS final_qc_status,

  bip30_source_pass,
  corrected_source_pass,
  baseline_pass,
  main_structure_pass,
  main_direction_pass,
  alpha10_crosscheck_pass,
  hhi_granularity_pass,
  tau_sensitivity_pass,
  trackA_reconcile_pass,

  (SELECT raw_duplicate_groups
   FROM raw_duplicate_summary)
    AS raw_duplicate_groups,

  (SELECT COUNT(*) FROM corrected_utxo)
    AS corrected_utxo_rows,

  (SELECT corrected_duplicate_groups
   FROM corrected_duplicate_summary)
    AS corrected_duplicate_groups,

  (SELECT COUNT(*) FROM corrected_addr)
    AS corrected_address_rows,

  (SELECT positive_addresses FROM totals)
    AS positive_addresses,

  (SELECT total_sats FROM totals)
    AS corrected_total_sats,

  (SELECT hhi_value FROM baseline_hhi_calc)
    AS canonical_baseline_hhi,

  (SELECT naka33_value
   FROM baseline_naka_33_calc)
    AS canonical_nakamoto_33,

  (SELECT COUNT(*) FROM main_results)
    AS main_scenario_rows,

  (
    SELECT MAX(
      ABS(
        post_total_sats
        - CAST(
            (SELECT total_sats FROM totals)
            AS NUMERIC
          )
      )
    )
    FROM main_results
  ) AS max_supply_diff_sats,

  (
    SELECT min_m_hhi_improvement
    FROM hhi_boundaries
    WHERE alpha = NUMERIC '0.10'
  ) AS alpha10_min_m_hhi_improvement,

  (
    SELECT baseline_nakamoto
    FROM baseline_naka_tau
    WHERE tau_threshold = NUMERIC '0.25'
  ) AS baseline_naka_25,

  (
    SELECT baseline_nakamoto
    FROM baseline_naka_tau
    WHERE tau_threshold = NUMERIC '0.33'
  ) AS baseline_naka_33,

  (
    SELECT baseline_nakamoto
    FROM baseline_naka_tau
    WHERE tau_threshold = NUMERIC '0.50'
  ) AS baseline_naka_50,

  (
    SELECT balance_mismatch_addresses
    FROM trackA_reconcile
  ) AS trackA_balance_mismatch_addresses,

  (
    SELECT total_absolute_balance_difference_sats
    FROM trackA_reconcile
  ) AS trackA_absolute_balance_difference_sats

FROM qc;
