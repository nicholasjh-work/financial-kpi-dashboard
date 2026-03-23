-- Scheduled refresh procedure for the KPI dashboard views.
-- Runs as a Snowflake Task on a daily schedule at 5:30 AM UTC.
-- Refreshes the materialized reporting views and logs the result.

-- Refresh log table
CREATE TABLE IF NOT EXISTS reporting.refresh_log (
    run_id          INTEGER AUTOINCREMENT PRIMARY KEY,
    run_start       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    run_end         TIMESTAMP_NTZ,
    status          VARCHAR(20),  -- 'success' or 'failed'
    rows_revenue    INTEGER,
    rows_opex       INTEGER,
    error_message   VARCHAR(2000),
    validation_pass BOOLEAN
);

-- The refresh procedure.
-- Views are already live (not materialized), so this procedure
-- runs the validation queries and logs whether they passed.
-- If you switch to materialized views, add the REFRESH statements here.
CREATE OR REPLACE PROCEDURE reporting.sp_refresh_dashboard()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    v_rows_revenue INTEGER;
    v_rows_opex INTEGER;
    v_orphan_count INTEGER;
    v_dup_count INTEGER;
    v_status VARCHAR(20) DEFAULT 'success';
    v_error VARCHAR(2000) DEFAULT NULL;
BEGIN
    -- Count rows in key views
    SELECT COUNT(*) INTO :v_rows_revenue FROM reporting.v_rpt_revenue_by_division;
    SELECT COUNT(*) INTO :v_rows_opex FROM reporting.v_rpt_opex_variance;

    -- Orphan key check
    SELECT COUNT(*) INTO :v_orphan_count
    FROM fact_revenue f
    LEFT JOIN dim_division d ON f.division_id = d.division_id
    WHERE d.division_id IS NULL;

    -- Duplicate check
    SELECT COUNT(*) INTO :v_dup_count
    FROM (
        SELECT transaction_id
        FROM fact_revenue
        GROUP BY transaction_id
        HAVING COUNT(*) > 1
    );

    IF (v_orphan_count > 0 OR v_dup_count > 0) THEN
        v_status := 'failed';
        v_error := 'orphan_keys=' || v_orphan_count::VARCHAR || ', duplicates=' || v_dup_count::VARCHAR;
    END IF;

    -- Log the result
    INSERT INTO reporting.refresh_log (run_end, status, rows_revenue, rows_opex, error_message, validation_pass)
    VALUES (CURRENT_TIMESTAMP(), :v_status, :v_rows_revenue, :v_rows_opex, :v_error, :v_status = 'success');

    RETURN v_status || ': revenue_rows=' || v_rows_revenue::VARCHAR || ', opex_rows=' || v_rows_opex::VARCHAR;
END;
$$;

-- Schedule the task: daily at 5:30 AM UTC
CREATE OR REPLACE TASK reporting.task_refresh_dashboard
    WAREHOUSE = 'ANALYTICS_WH'
    SCHEDULE = 'USING CRON 30 5 * * * UTC'
AS
    CALL reporting.sp_refresh_dashboard();

-- Enable the task (must be run by ACCOUNTADMIN or task owner)
ALTER TASK reporting.task_refresh_dashboard RESUME;
