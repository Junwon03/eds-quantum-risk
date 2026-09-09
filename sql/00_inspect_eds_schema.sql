SELECT
  table_name,
  ordinal_position,
  column_name,
  data_type
FROM `sixth-wave-484005-t0.btc_eds_ljw.INFORMATION_SCHEMA.COLUMNS`
WHERE table_name IN (
  'eds_utxo_20260101_t5',
  'eds_addrbal_20260101_t5',
  'hhi_nakomoto',
  'nakamoto1',
  'nakamoto_p2',
  'nakamoto_p4',
  'nakomoto_p1_hhi',
  'nakomoto_p3_k',
  'trackA_entity_membership_v1'
)
ORDER BY table_name, ordinal_position;
