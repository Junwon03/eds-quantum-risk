-- ============================================================
-- 07a_trackA_reconcile_bip30_corrected.sql
--
-- Reconcile the existing Track-A ownership mapping against
-- the BIP30-corrected 2026-01-01 / 5-year EDS balances.
--
-- IMPORTANT:
--   - Track-A membership fields are inspected/reused.
--   - Track-A balance_sats is NOT treated as canonical.
--   - Corrected balances are rebuilt from the original UTXO
--     source with the BIP30 correction applied in-query.
--
-- This is a diagnostic query only.
-- No permanent tables are created.
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

corrected_addr AS (
  SELECT
    address,
    SUM(value_sats) AS corrected_balance_sats

  FROM corrected_utxo

  GROUP BY address
),

corrected_positive AS (
  SELECT
    address,
    corrected_balance_sats

  FROM corrected_addr

  WHERE corrected_balance_sats > 0
),

-- ------------------------------------------------------------
-- 2. Existing Track-A membership
-- ------------------------------------------------------------
trackA AS (
  SELECT
    snapshot_date,
    mapping_version,
    address,
    balance_sats AS old_trackA_balance_sats,

    common_input_member,
    public_label_member,

    common_input_bound_group,
    public_label_actor,
    public_label_name,
    public_label_confidence,
    public_label_cluster_definer,

    combined_entity_id

  FROM `sixth-wave-484005-t0.btc_eds_ljw.trackA_entity_membership_v1`
),

-- ------------------------------------------------------------
-- 3. Duplicate-address diagnostic in Track A
-- ------------------------------------------------------------
trackA_duplicate_groups AS (
  SELECT
    COUNT(*) AS duplicate_address_groups

  FROM (
    SELECT
      address
    FROM trackA
    GROUP BY address
    HAVING COUNT(*) > 1
  )
),

-- ------------------------------------------------------------
-- 4. One-row-per-address view for reconciliation
--
-- This is used only for diagnostics.
-- If duplicate_address_groups > 0, STOP before proceeding
-- to the actual robustness analysis.
-- ------------------------------------------------------------
trackA_by_address AS (
  SELECT
    address,

    ANY_VALUE(snapshot_date) AS snapshot_date,
    ANY_VALUE(mapping_version) AS mapping_version,

    ANY_VALUE(old_trackA_balance_sats)
      AS old_trackA_balance_sats,

    LOGICAL_OR(IFNULL(common_input_member, FALSE))
      AS common_input_member,

    LOGICAL_OR(IFNULL(public_label_member, FALSE))
      AS public_label_member,

    ANY_VALUE(common_input_bound_group)
      AS common_input_bound_group,

    ANY_VALUE(public_label_actor)
      AS public_label_actor,

    ANY_VALUE(public_label_name)
      AS public_label_name,

    ANY_VALUE(public_label_confidence)
      AS public_label_confidence,

    LOGICAL_OR(
      IFNULL(public_label_cluster_definer, FALSE)
    ) AS public_label_cluster_definer,

    ANY_VALUE(combined_entity_id)
      AS combined_entity_id

  FROM trackA

  GROUP BY address
),

-- ------------------------------------------------------------
-- 5. Corrected source joined to Track-A membership
-- ------------------------------------------------------------
joined AS (
  SELECT
    c.address,
    c.corrected_balance_sats,

    t.old_trackA_balance_sats,

    t.snapshot_date,
    t.mapping_version,

    t.common_input_member,
    t.public_label_member,

    t.common_input_bound_group,
    t.public_label_actor,
    t.public_label_name,
    t.public_label_confidence,
    t.public_label_cluster_definer,

    t.combined_entity_id

  FROM corrected_positive c

  LEFT JOIN trackA_by_address t
    USING (address)
),

-- ------------------------------------------------------------
-- 6. Track-A addresses not present in corrected positive EDS
-- ------------------------------------------------------------
trackA_extra AS (
  SELECT
    t.address

  FROM trackA_by_address t

  LEFT JOIN corrected_positive c
    USING (address)

  WHERE c.address IS NULL
),

-- ------------------------------------------------------------
-- 7. Main reconciliation summary
-- ------------------------------------------------------------
summary AS (
  SELECT

    -- Corrected canonical population
    (SELECT COUNT(*) FROM corrected_positive)
      AS corrected_positive_addresses,

    (SELECT SUM(corrected_balance_sats)
     FROM corrected_positive)
      AS corrected_total_sats,

    -- Track-A shape
    (SELECT COUNT(*) FROM trackA)
      AS trackA_rows,

    (SELECT COUNT(DISTINCT address) FROM trackA)
      AS trackA_distinct_addresses,

    (SELECT duplicate_address_groups
     FROM trackA_duplicate_groups)
      AS trackA_duplicate_address_groups,

    -- Coverage reconciliation
    COUNTIF(old_trackA_balance_sats IS NOT NULL)
      AS matched_trackA_addresses,

    COUNTIF(old_trackA_balance_sats IS NULL)
      AS corrected_addresses_missing_from_trackA,

    (SELECT COUNT(*) FROM trackA_extra)
      AS trackA_addresses_not_in_corrected_positive,

    -- Old balance vs corrected balance
    COUNTIF(
      old_trackA_balance_sats IS NOT NULL
      AND old_trackA_balance_sats
          != corrected_balance_sats
    ) AS old_balance_mismatch_addresses,

    SUM(
      CASE
        WHEN old_trackA_balance_sats IS NOT NULL
        THEN ABS(
          old_trackA_balance_sats
          - corrected_balance_sats
        )
        ELSE 0
      END
    ) AS total_absolute_balance_difference_sats,

    -- Ownership-bound membership counts
    COUNTIF(IFNULL(common_input_member, FALSE))
      AS common_input_member_addresses,

    COUNTIF(IFNULL(public_label_member, FALSE))
      AS public_label_member_addresses,

    COUNTIF(
      IFNULL(common_input_member, FALSE)
      OR IFNULL(public_label_member, FALSE)
    ) AS union_bound_member_addresses,

    -- Corrected BTC covered by each bound
    SUM(
      IF(
        IFNULL(common_input_member, FALSE),
        corrected_balance_sats,
        0
      )
    ) AS common_input_member_sats,

    SUM(
      IF(
        IFNULL(public_label_member, FALSE),
        corrected_balance_sats,
        0
      )
    ) AS public_label_member_sats,

    SUM(
      IF(
        IFNULL(common_input_member, FALSE)
        OR IFNULL(public_label_member, FALSE),
        corrected_balance_sats,
        0
      )
    ) AS union_bound_member_sats,

    -- Mapping structure
    COUNT(
      DISTINCT IF(
        common_input_bound_group IS NOT NULL,
        common_input_bound_group,
        NULL
      )
    ) AS distinct_common_input_groups,

    COUNT(
      DISTINCT IF(
        public_label_actor IS NOT NULL,
        public_label_actor,
        NULL
      )
    ) AS distinct_public_label_actors,

    COUNT(
      DISTINCT IF(
        combined_entity_id IS NOT NULL,
        combined_entity_id,
        NULL
      )
    ) AS distinct_combined_entity_ids,

    MIN(snapshot_date) AS min_mapping_snapshot_date,
    MAX(snapshot_date) AS max_mapping_snapshot_date,

    COUNT(DISTINCT mapping_version)
      AS mapping_version_count

  FROM joined
),

-- ------------------------------------------------------------
-- 8. Explicitly inspect the two BIP30-affected addresses
-- ------------------------------------------------------------
bip30_addresses AS (
  SELECT address
  FROM UNNEST([
    '16va6NxJrMGe5d2LP6wUzuVnzBBoKQZKom',
    '1GktTvnY8KGfAS72DhzGYJRyaQNvYrK9Fg'
  ]) AS address
),

bip30_detail AS (
  SELECT
    b.address,

    j.old_trackA_balance_sats,

    j.corrected_balance_sats,

    j.old_trackA_balance_sats
      - j.corrected_balance_sats
      AS balance_difference_sats,

    j.common_input_member,
    j.public_label_member,

    j.common_input_bound_group,
    j.public_label_actor,
    j.public_label_name,

    j.combined_entity_id

  FROM bip30_addresses b

  LEFT JOIN joined j
    USING (address)
)

-- ============================================================
-- 9. Final output
--
-- Two rows: one for each historical BIP30-affected address.
-- Global reconciliation statistics are repeated on both rows.
-- ============================================================
SELECT
  s.*,

  d.address AS bip30_address,

  d.old_trackA_balance_sats
    AS bip30_old_trackA_balance_sats,

  d.corrected_balance_sats
    AS bip30_corrected_balance_sats,

  d.balance_difference_sats
    AS bip30_balance_difference_sats,

  d.common_input_member
    AS bip30_common_input_member,

  d.public_label_member
    AS bip30_public_label_member,

  d.common_input_bound_group
    AS bip30_common_input_bound_group,

  d.public_label_actor
    AS bip30_public_label_actor,

  d.public_label_name
    AS bip30_public_label_name,

  d.combined_entity_id
    AS bip30_combined_entity_id

FROM summary s
CROSS JOIN bip30_detail d

ORDER BY bip30_address;
