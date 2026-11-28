BEGIN;
CREATE FUNCTION pg_temp.check_result(ok boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'failed: %', label; END IF;
    RAISE NOTICE 'passed: %', label;
END $$;

-- Two workspaces have real raw and summary rows. Within the first workspace,
-- exercise nullable project/squad dimensions as well as model and runtime.
INSERT INTO workspace (name, slug, issue_prefix) VALUES ('A','fixture-a','FA') RETURNING id AS a \gset
INSERT INTO workspace (name, slug, issue_prefix) VALUES ('B','fixture-b','FB') RETURNING id AS b \gset
INSERT INTO "user" (name,email) VALUES ('Fixture','rollup@example.test') RETURNING id AS owner \gset
INSERT INTO project (workspace_id,title) VALUES (:'a','P') RETURNING id AS project \gset
INSERT INTO issue (workspace_id,title,creator_type,creator_id,project_id)
VALUES (:'a','I','member',:'owner',:'project') RETURNING id AS issue \gset
CREATE TEMP TABLE workers AS SELECT gen_random_uuid() AS agent, gen_random_uuid() AS runtime, ws, n
    FROM (VALUES (:'a'::uuid,1),(:'a',2),(:'b',3)) AS w(ws,n);
INSERT INTO agent_runtime (id,workspace_id,name,runtime_mode,provider,owner_id)
    SELECT runtime,ws,'runtime-'||n,'local','anthropic',:'owner' FROM workers;
INSERT INTO agent (id,workspace_id,name,runtime_mode,runtime_id,owner_id)
    SELECT agent,ws,'agent-'||n,'local',runtime,:'owner' FROM workers;
SELECT gen_random_uuid() AS squad \gset
CREATE TEMP TABLE tasks AS SELECT gen_random_uuid() AS task_id,w.agent,w.runtime,f.*
    FROM (VALUES (1,1,NULL::uuid,NULL::uuid),(2,1,NULL,:'squad'),
                 (3,1,:'issue',NULL),(4,2,NULL,NULL),(5,3,NULL,NULL)) f(n,worker,issue,squad)
    JOIN workers w ON w.n=f.worker;
INSERT INTO agent_task_queue (id,agent_id,runtime_id,issue_id,usage_squad_id,status)
    SELECT task_id,agent,runtime,issue,squad,'completed' FROM tasks;
INSERT INTO task_usage (task_id,provider,model,created_at,input_tokens,output_tokens,
                        cache_read_tokens,cache_write_tokens,cost_usd_ticks)
    SELECT task_id,'anthropic',model,'2020-03-01 05:01Z',n*100,n*10,n,n*2,
           CASE WHEN n % 2 = 0 THEN n*10 END
      FROM tasks CROSS JOIN (VALUES ('one'),('two')) m(model) WHERE model='one' OR n=1;

SELECT rollup_task_usage_hourly_window('2020-03-01',now()+interval '1 hour');
\ir mys3116-usage-compare.sql
SELECT pg_temp.check_result(:'matches'::boolean AND :actual_rows = 6,'all eight dimensions and both workspaces');

UPDATE task_usage_hourly SET input_tokens=input_tokens+1 WHERE workspace_id=:'b';
\ir mys3116-usage-compare.sql
SELECT pg_temp.check_result(:missing_rows=1 AND :unexpected_rows=1,'one corrupted bucket detected');
SELECT rollup_task_usage_hourly_window('2020-03-01',now()+interval '1 hour');
\ir mys3116-usage-compare.sql
SELECT pg_temp.check_result(:'matches'::boolean,'corruption corrected');

DELETE FROM task_usage WHERE task_id=(SELECT task_id FROM tasks WHERE n=4);
INSERT INTO task_usage_hourly_dirty (bucket_hour,workspace_id,runtime_id,agent_id,project_id,squad_id,provider,model)
    SELECT bucket_hour,workspace_id,runtime_id,agent_id,project_id,squad_id,provider,model
      FROM task_usage_hourly WHERE runtime_id=(SELECT runtime FROM workers WHERE n=2)
    ON CONFLICT DO NOTHING;
SELECT rollup_task_usage_hourly_window('2020-03-01',now()+interval '1 hour');
\ir mys3116-usage-compare.sql
SELECT pg_temp.check_result(:'matches'::boolean AND :actual_rows=5,'empty bucket removed');

-- Simulate a still-combined pre-739 key; other projects at the same hour
-- remain separate. Only the two first tasks share the affected hour key.
DELETE FROM task_usage_hourly WHERE squad_id=:'squad';
UPDATE task_usage_hourly SET input_tokens=300,output_tokens=30,cache_read_tokens=3,
    cache_write_tokens=6,cost_usd_ticks=20,task_count=2,event_count=2,updated_at='2020-03-01'
 WHERE workspace_id=:'a' AND project_id IS NULL AND model='one';
SELECT rollup_task_usage_hourly_window(now()+interval '1 day',now()+interval '2 days');
\ir mys3116-usage-compare.sql
SELECT pg_temp.check_result(:'matches'::boolean AND :legacy_keys=1 AND :actual_rows=4,'untouched combined hour conserved');
SELECT rollup_task_usage_hourly_window('2020-03-01',now()+interval '1 hour');
\ir mys3116-usage-compare.sql
SELECT pg_temp.check_result(:'matches'::boolean AND :legacy_keys=0 AND :actual_rows=5,'touched hour split by squad');
ROLLBACK;
