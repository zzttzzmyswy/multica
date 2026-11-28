-- Compare one consistent snapshot. Pre-739 rows retain their combined
-- standalone/squad totals until the first recompute of their seven-column key.
WITH legacy AS (
    SELECT h.bucket_hour, h.workspace_id, h.runtime_id, h.agent_id,
           h.project_id, h.provider, h.model
      FROM task_usage_hourly h
     GROUP BY 1,2,3,4,5,6,7
    HAVING bool_and(h.squad_id IS NULL)
       AND max(h.updated_at) < (SELECT applied_at FROM schema_migrations
                                 WHERE version = '739_task_usage_hourly_squad_col')
), raw AS (
    SELECT task_usage_hour_bucket(u.created_at) AS bucket_hour,
           a.workspace_id, t.runtime_id, t.agent_id, i.project_id,
           COALESCE(t.usage_squad_id, t.squad_id) AS squad_id,
           u.task_id, u.provider, u.model, u.input_tokens, u.output_tokens,
           u.cache_read_tokens, u.cache_write_tokens, u.cost_usd_ticks
      FROM task_usage u
      JOIN agent_task_queue t ON t.id = u.task_id
      JOIN agent a ON a.id = t.agent_id
      LEFT JOIN issue i ON i.id = t.issue_id
     WHERE t.runtime_id IS NOT NULL
), expected AS (
    SELECT r.bucket_hour, r.workspace_id, r.runtime_id, r.agent_id, r.project_id,
           CASE WHEN l.workspace_id IS NULL THEN r.squad_id END AS squad_id,
           r.provider, r.model,
           sum(r.input_tokens), sum(r.output_tokens),
           sum(r.cache_read_tokens), sum(r.cache_write_tokens),
           COALESCE(sum(r.cost_usd_ticks), 0),
           COALESCE(sum(r.input_tokens) FILTER (WHERE r.cost_usd_ticks IS NULL), 0),
           COALESCE(sum(r.output_tokens) FILTER (WHERE r.cost_usd_ticks IS NULL), 0),
           COALESCE(sum(r.cache_read_tokens) FILTER (WHERE r.cost_usd_ticks IS NULL), 0),
           COALESCE(sum(r.cache_write_tokens) FILTER (WHERE r.cost_usd_ticks IS NULL), 0),
           count(DISTINCT r.task_id), count(*)
      FROM raw r
      LEFT JOIN legacy l ON l.bucket_hour = r.bucket_hour AND l.workspace_id = r.workspace_id
                        AND l.runtime_id = r.runtime_id AND l.agent_id = r.agent_id
                        AND l.project_id IS NOT DISTINCT FROM r.project_id
                        AND l.provider = r.provider AND l.model = r.model
     GROUP BY 1,2,3,4,5,6,7,8
), actual AS (
    SELECT bucket_hour, workspace_id, runtime_id, agent_id, project_id, squad_id,
           provider, model, input_tokens, output_tokens, cache_read_tokens,
           cache_write_tokens, cost_usd_ticks, uncosted_input_tokens,
           uncosted_output_tokens, uncosted_cache_read_tokens,
           uncosted_cache_write_tokens, task_count, event_count
      FROM task_usage_hourly
), missing AS (
    SELECT * FROM expected EXCEPT ALL SELECT * FROM actual
), unexpected AS (
    SELECT * FROM actual EXCEPT ALL SELECT * FROM expected
)
SELECT (SELECT count(*) FROM expected) AS expected_rows,
       (SELECT count(*) FROM actual) AS actual_rows,
       (SELECT count(*) FROM legacy) AS legacy_keys,
       (SELECT count(*) FROM missing) AS missing_rows,
       (SELECT count(*) FROM unexpected) AS unexpected_rows,
       NOT EXISTS (SELECT FROM missing) AND NOT EXISTS (SELECT FROM unexpected) AS matches
\gset
\echo expected=:expected_rows actual=:actual_rows legacy_keys=:legacy_keys missing=:missing_rows unexpected=:unexpected_rows
