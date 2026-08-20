#!/bin/bash
trap "exit 1" TERM
export TOP_PID=$$

die() {
  echo "ERROR: $*" >&2
  kill -s TERM "${TOP_PID}"
}

if [ "$#" -eq 8 ]; then
        db_sid=${1}          ## HANA DB SID (also used as connect host)
        db_inst_no=${2}      ## HANA instance number
        schemaName=${3}      ## schema / connect user name
        db_password=${4}     ## DB password, or 'none' to use hdbuserstore key <schemaName>
        begin_time=${5}      ## BEGIN_TIME for statement hash data collection window
        end_time=${6}        ## END_TIME for statement hash data collection window
        statement_hash=${7}  ## STATEMENT_HASH to analyze (mandatory)
        script_dir=${8}/hana_dbop_comparison
else
        echo "Parameter missing"
        echo "Usage: $0 db_sid db_inst_no schemaName db_password begin_time end_time statement_hash script_dir"
        exit 1
fi

## The orchestrating platform passes timestamps as a single whitespace-free
## token (e.g. 2026/08/19_00:26:20) so the value survives unquoted expansion on
## the command line. Turn the separator back into a space before it reaches the
## SQL. Shortcut forms (C, C-H2, E-S900, MIN, MAX, ...) contain no underscore and
## are passed through untouched.
normalize_time() {
  if [[ "${1}" =~ ^([0-9]{4}/[0-9]{2}/[0-9]{2})_([0-9]{2}:[0-9]{2}:[0-9]{2})$ ]]; then
    printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '%s' "${1}"
  fi
}
begin_time="$(normalize_time "${begin_time}")"
end_time="$(normalize_time "${end_time}")"

HDBSQL_BIN="/usr/sap/${db_sid}/HDB${db_inst_no}/exe/hdbsql"
db_name="${db_sid}"    ## tenant/system database name for -d, assumed same as SID

if [[ ! -x "${HDBSQL_BIN}" ]]; then
  die "hdbsql binary not found or not executable at ${HDBSQL_BIN}"
fi

mkdir -p "${script_dir}" || die "Could not create working directory ${script_dir}"

# --- Embedded SQL (HANA_SQL_StatementHash_DataCollector_2.00.070+, unmodified except
#     BEGIN_TIME / END_TIME / STATEMENT_HASH in the modification section replaced with
#     __placeholders__) ---
read -r -d '' SQL_TEMPLATE_CONTENT <<'SQL_EOF'
WITH
/*
[NAME]
- HANA_SQL_StatementHash_DataCollector_2.00.070+
[DESCRIPTION]
- Collection of details for a specific SQL statement
[SOURCE]
- SAP Note 1969700
[DETAILS AND RESTRICTIONS]
- M_TABLE_REPLICAS available starting with 1.00.120
- M_ADMISSION_CONTROL_EVENTS available starting with 2.00.010
- M_MULTIDIMENSIONAL_STATEMENT_STATISTICS available starting with 1.00.122.16 and 2.00.024.01
- Running this command with SAP HANA 2.0 Revisions before 2.00.024.01 will fail with:
  Could not find table/view M_MULTIDIMENSIONAL_STATEMENT_STATISTICS
- M_CE_CALCSCENARIO_HINTS available starting with 2.00.030
- HOST_SQL_PLAN_CACHE.APPLICATION_SOURCE available starting with 1.00.122.21, 2.00.024.06 and 2.00.034
- M_CS_LOADS.STATEMENT_HASH and ROOT_STATEMENT_HASH available starting with SAP HANA 2.00.040
- EXECUTION_ENGINE in M_SQL_PLAN_CACHE and HOST_SQL_PLAN_CACHE available with SAP HANA >= 2.00.053
- Columns RESOURCE_WAIT_TIME, PHASE_1_HESITANT_LOCK_WAIT_TIME, PHASE_1_BLOCKING_LOCK_WAIT_TIME,
  PHASE_1_LOCK_TIME, PHASE_2_HESITANT_LOCK_WAIT_TIME, PHASE_2_BLOCKING_LOCK_WAIT_TIME and PHASE_2_LOCK_TIME
  of HOST_DELTA_MERGE_STATISTICS available with SAP HANA >= 2.00.059.01.
- SITE_ID in history tables available with SAP HANA >= 2.0 SPS 06, only primary site is evaluated
- Thread information APPLICATION_COMPONENT_NAME and APPLICATION_COMPONENT_TYPE available with SAP HANA >= 2.00.070
- AVG_BUFFER_CACHE_IO_READ_SIZE and MAX_BUFFER_CACHE_IO_READ_SIZE in SQL cache available with SAP HANA >= 2.00.070
- In order to display explain plans, you have to create them in advance using the ZDC_<plan_id> naming convention:
  EXPLAIN PLAN SET STATEMENT_NAME = 'ZDC_<plan_id>' FOR SQL PLAN CACHE ENTRY <plan_id>
[VALID FOR]
- Revisions:              >= 2.00.070
[SQL COMMAND VERSION]
- 2017/05/29:  1.0 (initial version)
- 2017/09/21:  1.1 (display of implicit single column indexes, PLAN_ID added to SQL cache overview)
- 2017/10/20:  1.2 (HOST information and CONCAT ATTRIBUTE indexes added)
- 2018/01/08:  1.3 ("PARAMETER SETTINGS" section added)
- 2018/04/11:  1.4 ("CALCULATION VIEWS" and "CALCULATION SCENARIOS" sections added, supression of empty sections)
- 2018/06/04:  1.5 ("TABLE REPLICAS" added, PERCENT added to "THREAD SAMPLES" section)
- 2018/06/05:  1.6 ("TRACE ENTRIES" section added)
- 2018/07/18:  1.7 (current, maximum and minimum disk size added to "TABLE INFORMATION")
- 2018/11/03:  1.8 (dedicated 1.00.122.16+ version including MDS)
- 2018/11/12:  1.9 (dedicated 2.00.030+ version including M_CE_CALCSCENARIO_HINTS)
- 2018/12/04:  2.0 (shortcuts for BEGIN_TIME and END_TIME like 'C', 'E-S900' or 'MAX')
- 2018/12/15:  2.1 (M_ADMISSION_CONTROL_EVENTS included)
- 2019/01/30:  2.2 (dedicated 2.00.034+ version including HOST_SQL_PLAN_CACHE.APPLICATION_SOURCE)
- 2019/02/19:  2.3 (REFERENTIAL_CONSTRAINTS included)
- 2019/03/13:  2.4 (PROCEDURES AND ACTIVE PROCEDURES sections included)
- 2019/06/03:  2.5 (dynamic column widths)
- 2019/09/06:  2.6 (annotations added)
- 2019/09/29:  2.7 (DATA_STATISTICS added)
- 2019/12/05:  2.8 (virtual tables added)
- 2019/12/17:  2.9 (translation tables added)
- 2020/02/20:  3.0 (ROOT_STATEMENT_HASH added)
- 2020/03/04:  3.1 (CLIENT_IP / CLIENT_PID added)
- 2020/04/06:  3.2 (LAST_INVALIDATION_REASON added)
- 2020/06/15:  3.3 (M_FEATURE_USAGE added)
- 2020/09/24:  3.4 (CHILD_STATEMENT_HASH overview added)
- 2020/12/23:  3.5 (dedicated 2.00.053+ version including EXECUTION_ENGINE)
- 2021/02/02:  3.6 (M_CS_ALL_COLUMN_STATISTICS.SCANNED_RECORD_COUNT and M_RS_TABLES.SCAN_COUNT added)
- 2021/09/12:  3.7 (PASSPORT_COMPONENT and PASSPORT_ACTION included)
- 2021/10/21:  3.8 (additional PASSPORT_ACTION without PASSPORT_COMPONENT section included)
- 2022/04/24:  3.9 (TRIGGER section included)
- 2022/05/26:  4.0 (dedicated 2.00.060+ version including SITE_ID for data source HISTORY)
- 2022/06/19:  4.1 (DB_USER filter added)
- 2022/07/21:  4.2 (DATABASE VERSION HISTORY section added)
- 2022/08/14:  4.3 (SCHEMA_NAME filter added)
- 2023/10/29:  4.4 (dedicated 2.00.070+ version including APPLICATION_COMPONENT_NAME and APPLICATION_COMPONENT_TYPE)
- 2024/05/24:  4.5 (lock and wait times for table optimizations included)
- 2024/07/11:  4.6 (FUNCTIONS added)
- 2024/10/17:  4.7 (Explain plans added)
- 2025/11/01:  4.8 (TABLE_COLUMNS.IS_NULLABLE included)
- 2026/03/15:  4.9 (SQL plan CPU information added)
[INVOLVED TABLES]
- ANNOTATIONS
- EXPLAIN_PLAN_TABLE
- FUNCTIONS
- HOST_DELTA_MERGE_STATISTICS
- HOST_SERVICE_THREAD_SAMPLES
- HOST_SQL_PLAN_CACHE
- INDEX_COLUMNS
- M_ACTIVE_PROCEDURES
- M_ACTIVE_STATEMENTS
- M_CE_CALCSCENARIO_HINTS
- M_CE_CALCSCENARIOS_OVERVIEW
- M_CE_CALCVIEW_DEPENDENCIES
- M_CONFIGURATION_PARAMETER_VALUES
- M_CS_ALL_COLUMNS
- M_CS_TABLES
- M_DATABASE_HISTORY
- M_DATA_STATISTICS
- M_EXPENSIVE_STATEMENTS
- M_FEATURE_USAGE
- M_INIFILE_CONTENT_HISTORY
- M_JOIN_TRANSLATION_TABLES
- M_MULTIDIMENSIONAL_STATEMENT_STATITICS
- M_RS_TABLES
- M_SERVICE_THREAD_CALLSTACKS
- M_SQL_PLAN_CACHE
- M_SQL_PLAN_CACHE_PARAMETERS
- M_TABLE_REPLICAS
- OBJECT_DEPENDENCIES
- OBJECTS
- PARTITIONED_TABLES
- PINNED_SQL_PLANS
- PROCEDURES
- STATEMENT_HINTS
- TABLE_COLUMNS
- TRIGGERS
- VIRTUAL_TABLES
[INPUT PARAMETERS]
- BEGIN_TIME
  Begin time
  '2018/12/05 14:05:00' --> Set begin time to 5th of December 2018, 14:05
  'C'                   --> Set begin time to current time
  'C-S900'              --> Set begin time to current time minus 900 seconds
  'C-M15'               --> Set begin time to current time minus 15 minutes
  'C-H5'                --> Set begin time to current time minus 5 hours
  'C-D1'                --> Set begin time to current time minus 1 day
  'C-W4'                --> Set begin time to current time minus 4 weeks
  'E-S900'              --> Set begin time to end time minus 900 seconds
  'E-M15'               --> Set begin time to end time minus 15 minutes
  'E-H5'                --> Set begin time to end time minus 5 hours
  'E-D1'                --> Set begin time to end time minus 1 day
  'E-W4'                --> Set begin time to end time minus 4 weeks
  'MIN'                 --> Set begin time to minimum (1000/01/01 00:00:00)
- END_TIME
  End time
  '2018/12/08 14:05:00' --> Set end time to 8th of December 2018, 14:05
  'C'                   --> Set end time to current time
  'C-S900'              --> Set end time to current time minus 900 seconds
  'C-M15'               --> Set end time to current time minus 15 minutes
  'C-H5'                --> Set end time to current time minus 5 hours
  'C-D1'                --> Set end time to current time minus 1 day
  'C-W4'                --> Set end time to current time minus 4 weeks
  'B+S900'              --> Set end time to begin time plus 900 seconds
  'B+M15'               --> Set end time to begin time plus 15 minutes
  'B+H5'                --> Set end time to begin time plus 5 hours
  'B+D1'                --> Set end time to begin time plus 1 day
  'B+W4'                --> Set end time to begin time plus 4 weeks
  'MAX'                 --> Set end time to maximum (9999/12/31 23:59:59)
- SITE_ID
  System replication site ID
  -1             --> No restriction related to site ID
  1              --> Site id 1
- STATEMENT_HASH
  Hash of SQL statement to be analyzed (mandatory)
- PLAN_ID
  SQL plan identifier
  12345678       --> SQL plan identifier 12345678
  -1             --> No restriction based on SQL plan identifier
- DB_USER
  Database user, column value may contain a list of several users, so putting '%' around user name can be useful
  'SYSTEM'        --> Database user 'SYSTEM'
  '%'             --> No database user restriction
- SCHEMA_NAME
  Schema name or pattern (be aware that some views cannot be restricted by schema)
  'SAPSR3'        --> Specific schema SAPSR3
  'SAP%'          --> All schemata starting with 'SAP'
  '%'             --> All schemata
- MAX_RESULT_LINES
  Maximum number of result lines for history sections
  20             --> Return a maximum of 20 lines in the output
  -1             --> No restriction related to result lines
- TRACE_HISTORY_S
  Time frame for checking SAP HANA trace files for statement hash occurrences (s)
  86400          --> Check last 86400 s (1 day) for trace file entries
  -1             --> No trace file check limitation (attention: Can be very expensive)
- LINE_LENGTH
  Maximum length of output lines
  200            --> Limit output lines to a length of 200 characters
  -1             --> No limitation related to output line length
- SHOW_COMPLETE_BIND_VALUE_LIST
  Possibility to display the complete list of bind values
  'X'            --> Show all captured bind values
  ' '            --> Only show the first MAX_RESULT_LINES bind values
- TIME_UNIT
  Unit of total times in the output
  'MS' --> milli seconds
  'S'  --> seconds
  'M'  --> minutes
  'H'  --> hours
  'D'  --> days
[OUTPUT PARAMETERS]
- LINE: Output information
[EXAMPLE OUTPUT]
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
|LINE                                                                                                                                                                                                    |
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
|*******************************************                                                                                                                                                             |
|* SAP HANA STATEMENT HASH DATA COLLECTION *                                                                                                                                                             |
|*******************************************                                                                                                                                                             |
|                                                                                                                                                                                                        |
|Analysis time:      2017/05/29 14:47:37                                                                                                                                                                 |
|Generated with:     SQL: "HANA_SQL_StatementHash_DataCollector" (SAP Note 1969700)                                                                                                                      |
|Statement hash:     d589b47003b8db3caf9425ebfaf5b72e                                                                                                                                                    |
|                                                                                                                                                                                                        |
|***************                                                                                                                                                                                         |
|* KEY FIGURES *                                                                                                                                                                                         |
|***************                                                                                                                                                                                         |
|                                                                                                                                                                                                        |
|STAT_NAME                VALUE                             VALUE_PER_EXEC  VALUE_PER_ROW                                                                                                                |
|======================== ================================ =============== ==============                                                                                                                |
|Statement Hash           d589b47003b8db3caf9425ebfaf5b72e                                                                                                                                               |
|Plan ID                  40772250004                                                                                                                                                                    |
|Table type / dist.       COLUMN / local                                                                                                                                                                 |
|Database user name       SAPERP                                                                                                                                                                         |
|Last connection ID       455766                                                                                                                                                                         |
|                                                                                                                                                                                                        |
|Executions                                              3                                                                                                                                               |
|Records                                                 0            0.00                                                                                                                               |
|Preparations                                            0            0.00                                                                                                                               |
|                                                                                                                                                                                                        |
|Elapsed time                                       8.39 h  10077261.05 ms        0.00 ms                                                                                                                |
|Execution time                                     8.39 h  10077261.05 ms        0.00 ms                                                                                                                |
|Preparation time                                   0.00 h         0.00 ms        0.00 ms                                                                                                                |
|Lock wait time                                     0.00 h         0.00 ms        0.00 ms                                                                                                                |
|                                                                                                                                                                                                        |
|******************                                                                                                                                                                                      |
|* STATEMENT TEXT *                                                                                                                                                                                      |
|******************                                                                                                                                                                                      |
|                                                                                                                                                                                                        |
|SELECT / FDA WRITE / DISTINCT  "V_MLHD" . "BELNR" , "V_MLHD" . "KJAHR" , "V_MLHD"                                                                                                                       |
|. "VGART" , "V_MLHD" . "CPUDT" , "V_MLHD" . "CPUTM" , "V_MLHD" . "GLVOR" , "V_MLHD"                                                                                                                     |
|. "STORNO" , "V_MLHD" . "AWREF" , "V_MLHD" . "AWORG" , "V_MLHD" . "AWTYP"                                                                                                                               |
|, "V_MLHD" . "TCODE" FROM / Redirected table: MLHD / "V_MLHD" , X AS "t_00"                                                                                                                             |
|(C_0 NVARCHAR(10), C_1 NVARCHAR(4)) WHERE "V_MLHD" . "MANDT" = X AND "V_MLHD" .                                                                                                                         |
|"BELNR" = "t_00" . "C_0" AND "V_MLHD" . "KJAHR" = "t_00" . "C_1"  WITH RANGE_RESTRICTION('CURRENT')                                                                                                     |
|                                                                                                                                                                                                        |
|***************                                                                                                                                                                                         |
|* BIND VALUES *                                                                                                                                                                                         |
|***************                                                                                                                                                                                         |
|                                                                                                                                                                                                        |
|EXECUTION_TIME      DATA_TYPE       POS BIND_VALUE                                                                                                                                                      |
|=================== ============== ==== ==================================================                                                                                                              |
|                                                                                                                                                                                                        |
|*************                                                                                                                                                                                           |
|* SQL CACHE *                                                                                                                                                                                           |
|*************                                                                                                                                                                                           |
|                                                                                                                                                                                                        |
|CURRENT                  EXECUTIONS        RECORDS   REC_PER_EXEC          ELAPSED_MS   ELA_PER_EXEC_MS    PREPARES     PREPARE_MS        LOCK_MS                                                       |
|==================== ============== ============== ============== =================== ================= =========== ============== ==============                                                       |
|CURRENT                           0              0           0.00                1073              0.00           2           1073              0                                                       |
|2017/05/26 18:42:23               2              0           0.00            29729395    14864697565.50           0              0              0                                                       |
|2017/05/24 12:00:51               1              0           0.00              502388      502388022.00           0              0              0                                                       |
|                                                                                                                                                                                                        |
|*********************                                                                                                                                                                                   |
|* TABLE INFORMATION *                                                                                                                                                                                   |
|*********************                                                                                                                                                                                   |
|                                                                                                                                                                                                        |
|SCHEMA_NAME         TABLE_NAME                              TYPE    PARTS     RECORDS MEM_TOTAL_GB MEM_DELTA_GB                                                                                         |
|=================== ======================================= ====== ====== =========== ============ ============                                                                                         |
|SAPERP              ACDOCA                                  COLUMN      8  5363293802       316.78         5.44                                                                                         |
|SAPERP              BKPF                                    COLUMN      1   488298937        30.51         0.82                                                                                         |
|SAPERP              FINSC_LEDGER                            COLUMN      1           6         0.00         0.00                                                                                         |
|SAPERP              FINS_MIG_STATUS                         COLUMN      1           1         0.00         0.00                                                                                         |
|SAPERP              MLHD                                    COLUMN      1   164711605         6.84         0.23                                                                                         |
|                                                                                                                                                                                                        |
...
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
*/
BASIS_INFO AS
( SELECT
    CASE
      WHEN BEGIN_TIME =    'C'                             THEN CURRENT_TIMESTAMP
      WHEN BEGIN_TIME LIKE 'C-S%'                          THEN ADD_SECONDS(CURRENT_TIMESTAMP, -SUBSTR_AFTER(BEGIN_TIME, 'C-S'))
      WHEN BEGIN_TIME LIKE 'C-M%'                          THEN ADD_SECONDS(CURRENT_TIMESTAMP, -SUBSTR_AFTER(BEGIN_TIME, 'C-M') * 60)
      WHEN BEGIN_TIME LIKE 'C-H%'                          THEN ADD_SECONDS(CURRENT_TIMESTAMP, -SUBSTR_AFTER(BEGIN_TIME, 'C-H') * 3600)
      WHEN BEGIN_TIME LIKE 'C-D%'                          THEN ADD_SECONDS(CURRENT_TIMESTAMP, -SUBSTR_AFTER(BEGIN_TIME, 'C-D') * 86400)
      WHEN BEGIN_TIME LIKE 'C-W%'                          THEN ADD_SECONDS(CURRENT_TIMESTAMP, -SUBSTR_AFTER(BEGIN_TIME, 'C-W') * 86400 * 7)
      WHEN BEGIN_TIME LIKE 'E-S%'                          THEN ADD_SECONDS(TO_TIMESTAMP(END_TIME, 'YYYY/MM/DD HH24:MI:SS'), -SUBSTR_AFTER(BEGIN_TIME, 'E-S'))
      WHEN BEGIN_TIME LIKE 'E-M%'                          THEN ADD_SECONDS(TO_TIMESTAMP(END_TIME, 'YYYY/MM/DD HH24:MI:SS'), -SUBSTR_AFTER(BEGIN_TIME, 'E-M') * 60)
      WHEN BEGIN_TIME LIKE 'E-H%'                          THEN ADD_SECONDS(TO_TIMESTAMP(END_TIME, 'YYYY/MM/DD HH24:MI:SS'), -SUBSTR_AFTER(BEGIN_TIME, 'E-H') * 3600)
      WHEN BEGIN_TIME LIKE 'E-D%'                          THEN ADD_SECONDS(TO_TIMESTAMP(END_TIME, 'YYYY/MM/DD HH24:MI:SS'), -SUBSTR_AFTER(BEGIN_TIME, 'E-D') * 86400)
      WHEN BEGIN_TIME LIKE 'E-W%'                          THEN ADD_SECONDS(TO_TIMESTAMP(END_TIME, 'YYYY/MM/DD HH24:MI:SS'), -SUBSTR_AFTER(BEGIN_TIME, 'E-W') * 86400 * 7)
      WHEN BEGIN_TIME =    'MIN'                           THEN TO_TIMESTAMP('1000/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS')
      WHEN SUBSTR(BEGIN_TIME, 1, 1) NOT IN ('C', 'E', 'M') THEN TO_TIMESTAMP(BEGIN_TIME, 'YYYY/MM/DD HH24:MI:SS')
    END BEGIN_TIME,
    CASE
      WHEN END_TIME =    'C'                             THEN CURRENT_TIMESTAMP
      WHEN END_TIME LIKE 'C-S%'                          THEN ADD_SECONDS(CURRENT_TIMESTAMP, -SUBSTR_AFTER(END_TIME, 'C-S'))
      WHEN END_TIME LIKE 'C-M%'                          THEN ADD_SECONDS(CURRENT_TIMESTAMP, -SUBSTR_AFTER(END_TIME, 'C-M') * 60)
      WHEN END_TIME LIKE 'C-H%'                          THEN ADD_SECONDS(CURRENT_TIMESTAMP, -SUBSTR_AFTER(END_TIME, 'C-H') * 3600)
      WHEN END_TIME LIKE 'C-D%'                          THEN ADD_SECONDS(CURRENT_TIMESTAMP, -SUBSTR_AFTER(END_TIME, 'C-D') * 86400)
      WHEN END_TIME LIKE 'C-W%'                          THEN ADD_SECONDS(CURRENT_TIMESTAMP, -SUBSTR_AFTER(END_TIME, 'C-W') * 86400 * 7)
      WHEN END_TIME LIKE 'B+S%'                          THEN ADD_SECONDS(TO_TIMESTAMP(BEGIN_TIME, 'YYYY/MM/DD HH24:MI:SS'), SUBSTR_AFTER(END_TIME, 'B+S'))
      WHEN END_TIME LIKE 'B+M%'                          THEN ADD_SECONDS(TO_TIMESTAMP(BEGIN_TIME, 'YYYY/MM/DD HH24:MI:SS'), SUBSTR_AFTER(END_TIME, 'B+M') * 60)
      WHEN END_TIME LIKE 'B+H%'                          THEN ADD_SECONDS(TO_TIMESTAMP(BEGIN_TIME, 'YYYY/MM/DD HH24:MI:SS'), SUBSTR_AFTER(END_TIME, 'B+H') * 3600)
      WHEN END_TIME LIKE 'B+D%'                          THEN ADD_SECONDS(TO_TIMESTAMP(BEGIN_TIME, 'YYYY/MM/DD HH24:MI:SS'), SUBSTR_AFTER(END_TIME, 'B+D') * 86400)
      WHEN END_TIME LIKE 'B+W%'                          THEN ADD_SECONDS(TO_TIMESTAMP(BEGIN_TIME, 'YYYY/MM/DD HH24:MI:SS'), SUBSTR_AFTER(END_TIME, 'B+W') * 86400 * 7)
      WHEN END_TIME =    'MAX'                           THEN TO_TIMESTAMP('9999/12/31 00:00:00', 'YYYY/MM/DD HH24:MI:SS')
      WHEN SUBSTR(END_TIME, 1, 1) NOT IN ('C', 'B', 'M') THEN TO_TIMESTAMP(END_TIME, 'YYYY/MM/DD HH24:MI:SS')
    END END_TIME,
    SITE_ID,
    STATEMENT_HASH,
    DB_USER,
    SCHEMA_NAME,
    PLAN_ID,
    MAX_RESULT_LINES,
    TRACE_HISTORY_S,
    LINE_LENGTH,
    SHOW_COMPLETE_BIND_VALUE_LIST,
    LOWER(TIME_UNIT) TIME_UNIT,
    MAP(TIME_UNIT, 'MS', 1, 'S', 1000, 'M', 60000, 'H', 3600000, 'D', 86400000) TIME_FACTOR,
    HOST_LEN
  FROM
  ( SELECT                /* Modification section */
      '__BEGIN_TIME__' BEGIN_TIME,                  /* YYYY/MM/DD HH24:MI:SS timestamp, C, C-S<seconds>, C-M<minutes>, C-H<hours>, C-D<days>, C-W<weeks>, E-S<seconds>, E-M<minutes>, E-H<hours>, E-D<days>, E-W<weeks>, MIN */
      '__END_TIME__' END_TIME,                    /* YYYY/MM/DD HH24:MI:SS timestamp, C, C-S<seconds>, C-M<minutes>, C-H<hours>, C-D<days>, C-W<weeks>, B+S<seconds>, B+M<minutes>, B+H<hours>, B+D<days>, B+W<weeks>, MAX */
      CURRENT_SITE_ID() SITE_ID,
      '__STATEMENT_HASH__' STATEMENT_HASH,
      -1 PLAN_ID,
      '%' DB_USER,
      '%' SCHEMA_NAME,
      50 MAX_RESULT_LINES,
      86400 TRACE_HISTORY_S,
      200 LINE_LENGTH,
      ' ' SHOW_COMPLETE_BIND_VALUE_LIST,
      'H' TIME_UNIT                    /* MS, S, M, H, D */
    FROM
      DUMMY
  ),
  ( SELECT MAX(LENGTH(HOST)) HOST_LEN FROM M_HOST_INFORMATION )
),
ROW_COUNTER AS
( SELECT
    ROW_NUMBER () OVER () LINE_NO
  FROM
    OBJECTS
),
SQL_CACHE_CURRENT AS
( SELECT
    CURRENT_TIMESTAMP SERVER_TIMESTAMP,
    C.HOST,
    C.STATEMENT_HASH,
    TO_VARCHAR(C.STATEMENT_STRING) STATEMENT_STRING,
    C.PLAN_ID,
    C.USER_NAME,
    C.TABLE_TYPES,
    C.EXECUTION_ENGINE ENGINES,
    C.LAST_PREPARATION_TIMESTAMP,
    C.LAST_EXECUTION_TIMESTAMP,
    C.LAST_CONNECTION_ID,
    C.EXECUTION_COUNT,
    C.TOTAL_RESULT_RECORD_COUNT,
    C.PREPARATION_COUNT,
    C.TOTAL_CURSOR_DURATION,
    C.TOTAL_EXECUTION_TIME,
    C.TOTAL_EXECUTION_CPU_TIME,
    C.TOTAL_PREPARATION_TIME,
    C.TOTAL_LOCK_WAIT_DURATION,
    C.TOTAL_SERVICE_NETWORK_REQUEST_COUNT,
    C.TOTAL_SERVICE_NETWORK_REQUEST_DURATION,
    C.TOTAL_SERVICE_NETWORK_REQUEST_SIZE,
    C.TOTAL_CALLED_THREAD_COUNT,
    C.TOTAL_TABLE_LOAD_TIME_DURING_PREPARATION,
    C.TOTAL_EXECUTION_MEMORY_SIZE,
    C.TOTAL_BUFFER_CACHE_IO_READ_SIZE,
    C.IS_DISTRIBUTED_EXECUTION,
    MAP(C.COMPILATION_OPTIONS, 'STATEMENT HINT', 'X', ' ') HINT,
    TO_VARCHAR(C.ACCESSED_TABLE_NAMES) ACCESSED_TABLE_NAMES,
    TO_VARCHAR(C.ACCESSED_OBJECT_NAMES) ACCESSED_OBJECT_NAMES,
    TO_VARCHAR(SUBSTR(C.STATEMENT_STRING, 1, 4000)) SQL_TEXT,
    C.APPLICATION_SOURCE,
    CASE WHEN C.LAST_INVALIDATION_REASON LIKE 'OBJECT VERSION MISMATCH%' THEN 'OBJECT VERSION MISMATCH' ELSE C.LAST_INVALIDATION_REASON END LAST_INVALIDATION_REASON,
    C.PLAN_MEMORY_SIZE,
    C.AVG_EXECUTION_MEMORY_SIZE,
    C.MAX_EXECUTION_MEMORY_SIZE,
    C.AVG_BUFFER_CACHE_PINNED_MEMORY_SIZE,
    C.MAX_BUFFER_CACHE_PINNED_MEMORY_SIZE,
    C.AVG_BUFFER_CACHE_IO_READ_SIZE,
    C.MAX_BUFFER_CACHE_IO_READ_SIZE,
    1 LINE_NO
  FROM
    BASIS_INFO BI,
    M_SQL_PLAN_CACHE C
  WHERE
    C.STATEMENT_HASH LIKE BI.STATEMENT_HASH AND
    ( BI.PLAN_ID = -1 OR C.PLAN_ID = BI.PLAN_ID ) AND
    C.USER_NAME LIKE BI.DB_USER AND
    C.SCHEMA_NAME LIKE BI.SCHEMA_NAME
),
SQL_CACHE_HISTORY AS
( SELECT
    C.SERVER_TIMESTAMP,
    C.HOST,
    C.STATEMENT_HASH,
    TO_VARCHAR(C.STATEMENT_STRING) STATEMENT_STRING,
    C.PLAN_ID,
    C.USER_NAME,
    C.TABLE_TYPES,
    C.EXECUTION_ENGINE ENGINES,
    C.LAST_PREPARATION_TIMESTAMP,
    C.LAST_EXECUTION_TIMESTAMP,
    C.LAST_CONNECTION_ID,
    C.EXECUTION_COUNT,
    C.TOTAL_RESULT_RECORD_COUNT,
    C.PREPARATION_COUNT,
    C.TOTAL_CURSOR_DURATION,
    C.TOTAL_EXECUTION_TIME,
    C.TOTAL_EXECUTION_CPU_TIME,
    C.TOTAL_PREPARATION_TIME,
    C.TOTAL_LOCK_WAIT_DURATION,
    C.TOTAL_SERVICE_NETWORK_REQUEST_COUNT,
    C.TOTAL_SERVICE_NETWORK_REQUEST_DURATION,
    C.TOTAL_SERVICE_NETWORK_REQUEST_SIZE,
    C.TOTAL_CALLED_THREAD_COUNT,
    C.TOTAL_TABLE_LOAD_TIME_DURING_PREPARATION,
    C.TOTAL_EXECUTION_MEMORY_SIZE,
    C.TOTAL_BUFFER_CACHE_IO_READ_SIZE,
    C.IS_DISTRIBUTED_EXECUTION,
    MAP(C.COMPILATION_OPTIONS, 'STATEMENT HINT', 'X', ' ') HINT,
    TO_VARCHAR(C.ACCESSED_TABLE_NAMES) ACCESSED_TABLE_NAMES,
    TO_VARCHAR(C.ACCESSED_OBJECT_NAMES) ACCESSED_OBJECT_NAMES,
    TO_VARCHAR(SUBSTR(C.STATEMENT_STRING, 1, 4000)) SQL_TEXT,
    C.APPLICATION_SOURCE,
    CASE WHEN C.LAST_INVALIDATION_REASON LIKE 'OBJECT VERSION MISMATCH%' THEN 'OBJECT VERSION MISMATCH' ELSE C.LAST_INVALIDATION_REASON END LAST_INVALIDATION_REASON,
    C.PLAN_MEMORY_SIZE,
    C.AVG_EXECUTION_MEMORY_SIZE,
    C.MAX_EXECUTION_MEMORY_SIZE,
    C.AVG_BUFFER_CACHE_PINNED_MEMORY_SIZE,
    C.MAX_BUFFER_CACHE_PINNED_MEMORY_SIZE,
    C.AVG_BUFFER_CACHE_IO_READ_SIZE,
    C.MAX_BUFFER_CACHE_IO_READ_SIZE,
    ROW_NUMBER () OVER (ORDER BY C.SERVER_TIMESTAMP DESC, C.PLAN_ID) LINE_NO
  FROM
    BASIS_INFO BI,
    _SYS_STATISTICS.HOST_SQL_PLAN_CACHE C
  WHERE
    C.SERVER_TIMESTAMP BETWEEN BI.BEGIN_TIME AND BI.END_TIME AND
    C.STATEMENT_HASH LIKE BI.STATEMENT_HASH AND
    ( BI.PLAN_ID = -1 OR C.PLAN_ID = BI.PLAN_ID ) AND
    C.USER_NAME LIKE BI.DB_USER AND
    C.SCHEMA_NAME LIKE BI.SCHEMA_NAME
),
BIND_VALUES AS
( SELECT
    ROW_NUMBER () OVER (ORDER BY B.EXECUTION_TIMESTAMP DESC, B.POSITION) LINE_NO,
    B.EXECUTION_TIMESTAMP,
    B.DATA_TYPE_NAME,
    B.POSITION,
    B.PARAMETER_VALUE,
    BI.MAX_RESULT_LINES,
    BI.SHOW_COMPLETE_BIND_VALUE_LIST
  FROM
    BASIS_INFO BI,
    SQL_CACHE_CURRENT S,
    M_SQL_PLAN_CACHE_PARAMETERS B
  WHERE
    S.PLAN_ID = B.PLAN_ID
),
THREAD_SAMPLES AS
( SELECT
    T.TIMESTAMP,
    T.HOST,
    T.PORT,
    T.THREAD_TYPE,
    T.THREAD_STATE,
    T.THREAD_METHOD,
    T.THREAD_DETAIL,
    T.LOCK_WAIT_NAME LOCK_NAME,
    T.USER_NAME DB_USER,
    T.APPLICATION_NAME APP_NAME,
    /* T.APPLICATION_SOURCE */ 'not reliable' APP_SOURCE,
    T.APPLICATION_USER_NAME APP_USER,
    IFNULL(T.APPLICATION_COMPONENT_NAME, '') APP_COMP_NAME,
    IFNULL(T.PASSPORT_COMPONENT_NAME, '') PASSPORT_COMPONENT,
    IFNULL(T.PASSPORT_ACTION, '') PASSPORT_ACTION,
    T.CLIENT_IP,
    T.CLIENT_PID,
    T.CONNECTION_ID,
    IFNULL(T.ROOT_STATEMENT_HASH, '') ROOT_STATEMENT_HASH,
    GREATEST(11, MAX(LENGTH(T.THREAD_TYPE)) OVER ()) TYPE_LEN,
    GREATEST(12, MAX(LENGTH(T.THREAD_STATE)) OVER ()) STATE_LEN,
    MAX(LENGTH(T.THREAD_METHOD)) OVER () METHOD_LEN,
    MAX(LENGTH(T.LOCK_WAIT_NAME)) OVER () LOCK_LEN,
    GREATEST(7, MAX(LENGTH(T.USER_NAME)) OVER ()) DB_USER_LEN,
    GREATEST(8, MAX(LENGTH(T.APPLICATION_NAME)) OVER ()) APP_NAME_LEN,
    GREATEST(10, MAX(LENGTH(T.APPLICATION_SOURCE)) OVER ()) APP_SOURCE_LEN,
    GREATEST(8, MAX(LENGTH(T.APPLICATION_USER_NAME)) OVER ()) APP_USER_LEN,
    GREATEST(13, MAX(LENGTH(IFNULL(T.APPLICATION_COMPONENT_NAME, ''))) OVER ()) APP_COMP_NAME_LEN,
    GREATEST(18, MAX(LENGTH(IFNULL(T.PASSPORT_COMPONENT_NAME, ''))) OVER ()) PASSPORT_COMPONENT_LEN,
    GREATEST(15, MAX(LENGTH(IFNULL(T.PASSPORT_ACTION, ''))) OVER ()) PASSPORT_ACTION_LEN,
    CASE WHEN T.THREAD_STATE = 'Job Exec Waiting' AND T.LOCK_WAIT_NAME != 'envCondStat' AND T.CALLING = '' THEN 'X' ELSE '' END Q,
    COUNT(*) SAMPLES,
    SUM(COUNT(*)) OVER () TOTAL_SAMPLES
  FROM
    BASIS_INFO BI,
    _SYS_STATISTICS.HOST_SERVICE_THREAD_SAMPLES T
  WHERE
    ( BI.SITE_ID = -1 OR ( BI.SITE_ID = 0 AND T.SITE_ID IN (-1, 0) ) OR T.SITE_ID = BI.SITE_ID ) AND
    SUBSTR(T.STATEMENT_HASH, 1, 31) = SUBSTR(BI.STATEMENT_HASH, 1, 31) AND          /* thread samples partially only stored 31 out of 32 characters */
    T.TIMESTAMP BETWEEN BI.BEGIN_TIME AND BI.END_TIME AND
    T.USER_NAME LIKE BI.DB_USER
  GROUP BY
    T.TIMESTAMP,
    T.HOST,
    T.PORT,
    T.THREAD_TYPE,
    T.THREAD_STATE,
    T.THREAD_METHOD,
    T.THREAD_DETAIL,
    T.LOCK_WAIT_NAME,
    T.USER_NAME,
    T.APPLICATION_NAME,
    T.APPLICATION_SOURCE,
    T.APPLICATION_USER_NAME,
    IFNULL(T.APPLICATION_COMPONENT_NAME, ''),
    IFNULL(T.PASSPORT_COMPONENT_NAME, ''),
    IFNULL(T.PASSPORT_ACTION, ''),
    T.CLIENT_IP,
    T.CLIENT_PID,
    T.CONNECTION_ID,
    T.ROOT_STATEMENT_HASH,
    CASE WHEN T.THREAD_STATE = 'Job Exec Waiting' AND T.LOCK_WAIT_NAME != 'envCondStat' AND T.CALLING = '' THEN 'X' ELSE '' END
),
THREAD_SAMPLES_ROOT_HASH AS
( SELECT
    T.STATEMENT_HASH CHILD_STATEMENT_HASH,
    T.ROOT_STATEMENT_HASH STATEMENT_HASH,
    COUNT(*) SAMPLES,
    SUM(COUNT(*)) OVER () TOTAL_SAMPLES
  FROM
    BASIS_INFO BI,
    _SYS_STATISTICS.HOST_SERVICE_THREAD_SAMPLES T
  WHERE
    ( BI.SITE_ID = -1 OR ( BI.SITE_ID = 0 AND T.SITE_ID IN (-1, 0) ) OR T.SITE_ID = BI.SITE_ID ) AND
    SUBSTR(T.ROOT_STATEMENT_HASH, 1, 31) = SUBSTR(BI.STATEMENT_HASH, 1, 31) AND          /* thread samples partially only stored 31 out of 32 characters */
    T.TIMESTAMP BETWEEN BI.BEGIN_TIME AND BI.END_TIME AND
    T.USER_NAME LIKE BI.DB_USER
  GROUP BY
    T.STATEMENT_HASH,
    T.ROOT_STATEMENT_HASH
),
ACCESSED_OBJECTS AS
( SELECT
    GREATEST(11, MAX(LENGTH(SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    *
  FROM
  ( SELECT
      CASE
        WHEN OBJECT_STRING LIKE '%.%' THEN SUBSTR(OBJECT_STRING, 1, LOCATE(OBJECT_STRING, '.', 1) - 1)
        ELSE OBJECT_STRING
      END SCHEMA_NAME,
      CASE
        WHEN OBJECT_STRING LIKE '%.%' THEN SUBSTR(OBJECT_STRING, LOCATE(OBJECT_STRING, '.', 1) + 1)
        ELSE ''
      END OBJECT_NAME
    FROM
    ( SELECT
        CASE
          WHEN R.LINE_NO = 1 THEN SUBSTR(T.ACCESSED_OBJECTS, 1, LOCATE(T.ACCESSED_OBJECTS, '(', 1, 1) - 1)
          ELSE SUBSTR(T.ACCESSED_OBJECTS, LOCATE(T.ACCESSED_OBJECTS, ', ', 1, R.LINE_NO - 1) + 2, LOCATE(T.ACCESSED_OBJECTS, '(', 1, R.LINE_NO) - LOCATE(T.ACCESSED_OBJECTS, ', ', 1, R.LINE_NO - 1) - 2)
        END OBJECT_STRING
      FROM
        ROW_COUNTER R,
      ( SELECT
          MIN(ACCESSED_OBJECT_NAMES) ACCESSED_OBJECTS,
          LENGTH(MAX(ACCESSED_OBJECT_NAMES)) - LENGTH(REPLACE(MAX(ACCESSED_OBJECT_NAMES), ',', '')) + 1 NUM_OBJECTS
        FROM
        ( SELECT
            CASE /* remove schema if stored as first object */
              WHEN LOCATE(ACCESSED_OBJECT_NAMES, '.') < LOCATE(ACCESSED_OBJECT_NAMES, '(') THEN ACCESSED_OBJECT_NAMES
              ELSE SUBSTR(ACCESSED_OBJECT_NAMES, LOCATE(ACCESSED_OBJECT_NAMES, CHAR(32), 1) + 1)
            END ACCESSED_OBJECT_NAMES
          FROM
            SQL_CACHE_CURRENT
          UNION
          SELECT
            CASE
              WHEN LOCATE(ACCESSED_OBJECT_NAMES, '.') < LOCATE(ACCESSED_OBJECT_NAMES, '(') THEN ACCESSED_OBJECT_NAMES
              ELSE SUBSTR(ACCESSED_OBJECT_NAMES, LOCATE(ACCESSED_OBJECT_NAMES, CHAR(32), 1) + 1)
            END ACCESSED_OBJECT_NAMES
          FROM
            SQL_CACHE_HISTORY
        )
      ) T
      WHERE
        R.LINE_NO <= T.NUM_OBJECTS
    )
  )
),
ACCESSED_PROCEDURES AS
( SELECT
    P.SCHEMA_NAME,
    P.PROCEDURE_NAME,
    P.INPUT_PARAMETER_COUNT,
    P.OUTPUT_PARAMETER_COUNT,
    P.INOUT_PARAMETER_COUNT,
    P.RESULT_SET_COUNT,
    P.PROCEDURE_TYPE,
    P.READ_ONLY,
    P.IS_VALID,
    GREATEST(11, MAX(LENGTH(P.SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    MAX(LENGTH(P.PROCEDURE_NAME)) OVER () PROCEDURE_LEN
  FROM
    ACCESSED_OBJECTS O,
    PROCEDURES P
  WHERE
    O.SCHEMA_NAME = P.SCHEMA_NAME AND
    O.OBJECT_NAME = P.PROCEDURE_NAME
),
ACCESSED_FUNCTIONS AS
( SELECT
    F.SCHEMA_NAME,
    F.FUNCTION_NAME,
    F.SQL_SECURITY,
    F.INPUT_PARAMETER_COUNT,
    F.RETURN_VALUE_COUNT,
    F.FUNCTION_TYPE,
    F.FUNCTION_USAGE_TYPE USAGE_TYPE,
    F.IS_VALID,
    GREATEST(11, MAX(LENGTH(F.SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    MAX(LENGTH(F.FUNCTION_NAME)) OVER () FUNCTION_LEN
  FROM
    ACCESSED_OBJECTS O,
    FUNCTIONS F
  WHERE
    O.SCHEMA_NAME = F.SCHEMA_NAME AND
    O.OBJECT_NAME = F.FUNCTION_NAME
),
ACCESSED_TABLES AS
( SELECT
    O.SCHEMA_NAME,
    O.OBJECT_NAME TABLE_NAME,
    T.TABLE_TYPE,
    T.LOAD_UNIT,
    T.IS_TEMPORARY,
    GREATEST(11, MAX(LENGTH(O.SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    GREATEST(10, MAX(LENGTH(O.OBJECT_NAME)) OVER ()) TABLE_LEN
  FROM
    ACCESSED_OBJECTS O,
    TABLES T
  WHERE
    O.SCHEMA_NAME = T.SCHEMA_NAME AND
    O.OBJECT_NAME = T.TABLE_NAME
),
ACCESSED_TRANSLATION_TABLES AS
( SELECT
    TT.SCHEMA_NAME1 SCHEMA_NAME_1,
    TT.TABLE_NAME1 TABLE_NAME_1,
    TT.COLUMN_NAME1 COLUMN_NAME_1,
    TT.SCHEMA_NAME2 SCHEMA_NAME_2,
    TT.TABLE_NAME2 TABLE_NAME_2,
    TT.COLUMN_NAME2 COLUMN_NAME_2,
    COUNT(*) NUM_TTS,
    TO_DECIMAL(SUM(TT.TRANSLATION_TABLE_MEMORY_SIZE) / 1024 / 1024, 10, 2) SIZE_MB,
    GREATEST(13, MAX(LENGTH(TT.SCHEMA_NAME1)) OVER ()) SCHEMA_NAME_1_LEN,
    GREATEST(12, MAX(LENGTH(TT.TABLE_NAME1)) OVER ()) TABLE_NAME_1_LEN,
    GREATEST(13, MAX(LENGTH(TT.COLUMN_NAME1)) OVER ()) COLUMN_NAME_1_LEN,
    GREATEST(13, MAX(LENGTH(TT.SCHEMA_NAME2)) OVER ()) SCHEMA_NAME_2_LEN,
    GREATEST(12, MAX(LENGTH(TT.TABLE_NAME2)) OVER ()) TABLE_NAME_2_LEN,
    GREATEST(13, MAX(LENGTH(TT.COLUMN_NAME2)) OVER ()) COLUMN_NAME_2_LEN
  FROM
    M_JOIN_TRANSLATION_TABLES TT
  WHERE
    ( TT.SCHEMA_NAME1, TT.TABLE_NAME1) IN ( SELECT SCHEMA_NAME, TABLE_NAME FROM ACCESSED_TABLES ) AND
    ( TT.SCHEMA_NAME2, TT.TABLE_NAME2) IN ( SELECT SCHEMA_NAME, TABLE_NAME FROM ACCESSED_TABLES )
  GROUP BY
    TT.SCHEMA_NAME1,
    TT.TABLE_NAME1,
    TT.COLUMN_NAME1,
    TT.SCHEMA_NAME2,
    TT.TABLE_NAME2,
    TT.COLUMN_NAME2
),
ACCESSED_VIRTUAL_TABLES AS
( SELECT
    V.SCHEMA_NAME,
    V.TABLE_NAME,
    V.REMOTE_SOURCE_NAME,
    V.REMOTE_OBJECT_NAME,
    GREATEST(11, MAX(LENGTH(V.SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    GREATEST(10, MAX(LENGTH(V.TABLE_NAME)) OVER ()) TABLE_LEN,
    GREATEST(18, MAX(LENGTH(V.REMOTE_SOURCE_NAME)) OVER ()) REMOTE_SOURCE_LEN,
    GREATEST(18, MAX(LENGTH(V.REMOTE_OBJECT_NAME)) OVER ()) REMOTE_OBJECT_LEN
  FROM
    ACCESSED_OBJECTS O,
    VIRTUAL_TABLES V
  WHERE
    O.SCHEMA_NAME = V.SCHEMA_NAME AND
    O.OBJECT_NAME = V.TABLE_NAME
),
ACCESSED_LOBS AS
( SELECT
    L.SCHEMA_NAME,
    L.TABLE_NAME || MAP(L.PART_ID, 0, '', CHAR(32) || '(' || L.PART_ID || ')') TABLE_NAME,
    L.COLUMN_NAME,
    L.LOB_STORAGE_TYPE LOB_TYPE,
    TO_DECIMAL(SUM(L.DISK_SIZE) / 1024 / 1024 / 1024, 10, 2) DISK_GB,
    TO_DECIMAL(SUM(L.BINARY_SIZE) / 1024 / 1024 / 1024, 10, 2)  BINARY_GB,
    SUM(L.LOB_COUNT) LOB_COUNT,
    GREATEST(11, MAX(LENGTH(L.SCHEMA_NAME)) OVER ()) SCHEMA_LEN
  FROM
    ACCESSED_TABLES T,
    M_TABLE_LOB_STATISTICS L
  WHERE
    T.SCHEMA_NAME = L.SCHEMA_NAME AND
    T.TABLE_NAME = L.TABLE_NAME
  GROUP BY
    L.SCHEMA_NAME,
    L.TABLE_NAME || MAP(L.PART_ID, 0, '', CHAR(32) || '(' || L.PART_ID || ')'),
    L.COLUMN_NAME,
    L.LOB_STORAGE_TYPE
),
ACCESSED_PARTITIONS AS
( SELECT
    P.*,
    GREATEST(11, MAX(LENGTH(P.SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    GREATEST(10, MAX(LENGTH(P.TABLE_NAME) + LENGTH(P.PART_ID) + 3) OVER ()) TABLE_LEN,
    GREATEST(20, MAX(LENGTH(P.LEVEL_1_PARTITIONING)) OVER ()) L1_LEN,
    GREATEST(20, MAX(LENGTH(P.LEVEL_2_PARTITIONING)) OVER ()) L2_LEN,
    GREATEST(4, MAX(LENGTH(P.HOST)) OVER ()) HOST_LEN
  FROM
  ( SELECT
      CT.HOST,
      TP.SCHEMA_NAME,
      TP.TABLE_NAME,
      TP.PART_ID,
      CASE PT.LEVEL_1_TYPE
        WHEN 'RANGE' THEN 'RANGE (' || PT.LEVEL_1_EXPRESSION || ')' || CHAR(32) || TP.LEVEL_1_RANGE_MIN_VALUE || MAP(TP.LEVEL_1_RANGE_MAX_VALUE, '', '', TP.LEVEL_1_RANGE_MIN_VALUE, '', '-' || TP.LEVEL_1_RANGE_MAX_VALUE)
        ELSE PT.LEVEL_1_TYPE || CHAR(32) || PT.LEVEL_1_COUNT || CHAR(32) || '(' || PT.LEVEL_1_EXPRESSION || ')'
      END LEVEL_1_PARTITIONING,
      CASE
        WHEN PT.LEVEL_2_TYPE = '' OR TP.LEVEL_2_PARTITION = 0 THEN ''
        WHEN PT.LEVEL_2_TYPE = 'RANGE' THEN 'RANGE (' || PT.LEVEL_2_EXPRESSION || ')' || CHAR(32) || TP.LEVEL_2_RANGE_MIN_VALUE || MAP(TP.LEVEL_2_RANGE_MAX_VALUE, '', '', TP.LEVEL_2_RANGE_MIN_VALUE, '', '-' || TP.LEVEL_2_RANGE_MAX_VALUE)
        WHEN PT.LEVEL_2_TYPE = 'RANGE HETEROGENEOUS' THEN 'RANGE HETEROGENEOUS (' || PT.LEVEL_2_EXPRESSION || ')' || CHAR(32) || TP.LEVEL_2_RANGE_MIN_VALUE || MAP(TP.LEVEL_2_RANGE_MAX_VALUE, '', '',
          TP.LEVEL_2_RANGE_MIN_VALUE, '', '-' || TP.LEVEL_2_RANGE_MAX_VALUE)
        ELSE PT.LEVEL_2_TYPE || CHAR(32) || MAX(TP.LEVEL_2_PARTITION) OVER (PARTITION BY TP.SCHEMA_NAME, TP.TABLE_NAME, TP.LEVEL_1_PARTITION) || CHAR(32) || '(' || PT.LEVEL_2_EXPRESSION || ')'
      END LEVEL_2_PARTITIONING,
      GREATEST(CT.MEMORY_SIZE_IN_TOTAL + CT.PERSISTENT_MEMORY_SIZE_IN_TOTAL, CT.ESTIMATED_MAX_MEMORY_SIZE_IN_TOTAL) / 1024 / 1024 / 1024 MEM_SIZE_GB,
      CT.RECORD_COUNT RECORDS,
      CT.READ_COUNT,
      CT.WRITE_COUNT,
      CT.MERGE_COUNT,
      TP.LOAD_UNIT
    FROM
      ACCESSED_TABLES AC,
      PARTITIONED_TABLES PT,
      TABLE_PARTITIONS TP,
      M_CS_TABLES CT
    WHERE
      AC.SCHEMA_NAME = PT.SCHEMA_NAME AND
      AC.TABLE_NAME = PT.TABLE_NAME AND
      PT.SCHEMA_NAME = TP.SCHEMA_NAME AND
      PT.TABLE_NAME = TP.TABLE_NAME AND
      TP.SCHEMA_NAME = CT.SCHEMA_NAME AND
      TP.TABLE_NAME = CT.TABLE_NAME AND
      TP.PART_ID = CT.PART_ID
  ) P
),
ACCESSED_VIEWS AS
( SELECT
    V.*,
    MAX(LENGTH(VIEW_NAME)) OVER () VIEW_LEN,
    GREATEST(11, MAX(LENGTH(V.SCHEMA_NAME)) OVER ()) SCHEMA_LEN
  FROM
    ACCESSED_OBJECTS O,
    VIEWS V
  WHERE
    V.SCHEMA_NAME = O.SCHEMA_NAME AND
    V.VIEW_NAME = O.OBJECT_NAME
),
ACCESSED_CALCVIEWS AS
( SELECT
    C.HOST,
    C.PORT,
    C.SCHEMA_NAME,
    C.VIEW_NAME,
    C.CALCNODE_NAME,
    MAX(LENGTH(C.VIEW_NAME)) OVER () VIEW_LEN,
    SUBSTR(SCENARIO_NAME, 1, LOCATE(SCENARIO_NAME, ':', 1) - 1) SCENARIO_SCHEMA_NAME,
    SUBSTR(SCENARIO_NAME, LOCATE(SCENARIO_NAME, ':', 1) + 1) SCENARIO_NAME,
    GREATEST(11, MAX(LENGTH(C.SCHEMA_NAME)) OVER ()) SCHEMA_LEN
  FROM
    ACCESSED_VIEWS V,
    M_CE_CALCVIEW_DEPENDENCIES C
  WHERE
    V.VIEW_TYPE = 'CALC' AND
    C.VIEW_NAME = V.VIEW_NAME
),
ACCESSED_CALCSCENARIOS AS
( SELECT
    CS.*,
    GREATEST(11, MAX(LENGTH(CS.SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    GREATEST(13, MAX(LENGTH(CS.SCENARIO_NAME)) OVER ()) SCENARIO_LEN,
    IFNULL(CH.SCENARIO_HINTS, '') SCENARIO_HINTS
  FROM
    ACCESSED_CALCVIEWS C,
  ( SELECT
      HOST,
      PORT,
      SUBSTR(SCENARIO_NAME, 1, LOCATE(SCENARIO_NAME, ':', 1) - 1) SCHEMA_NAME,
      SUBSTR(SCENARIO_NAME, LOCATE(SCENARIO_NAME, ':', 1) + 1) SCENARIO_NAME,
      IS_PERSISTENT,
      CREATE_TIME,
      MEMORY_SIZE,
      COMPONENT
    FROM
      M_CE_CALCSCENARIOS_OVERVIEW
  ) CS LEFT OUTER JOIN
  ( SELECT
      SCHEMA_NAME,
      SCENARIO_NAME,
      STRING_AGG(HINT_TYPE || '=' || HINT_VALUE, ', ' ORDER BY HINT_TYPE, HINT_VALUE) SCENARIO_HINTS
    FROM
      M_CE_CALCSCENARIO_HINTS
    GROUP BY
      SCHEMA_NAME,
      SCENARIO_NAME
  ) CH ON
    CH.SCHEMA_NAME = CS.SCHEMA_NAME AND
    CH.SCENARIO_NAME = CS.SCENARIO_NAME
  WHERE
    CS.SCHEMA_NAME = C.SCENARIO_SCHEMA_NAME AND
    CS.SCENARIO_NAME = C.SCENARIO_NAME
),
ACCESSED_COLUMNS AS
( SELECT
    SCHEMA_NAME,
    TABLE_NAME,
    COLUMN_NAME,
    NUM_DISTINCT,
    SIZE_MB,
    LENGTH,
    DATA_TYPE,
    MAP(IS_NULLABLE, 'TRUE', 'X', ' ') IS_NULLABLE,
    COMPRESSION,
    INDEX_TYPE,
    SCANNED_RECS_PER_S,
    INDEX_LOOKUPS_PER_H,
    INTERNAL_ATTRIBUTE_TYPE,
    LOAD_UNIT,
    GREATEST(11, MAX(LENGTH(SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    GREATEST(10, MAX(LENGTH(TABLE_NAME)) OVER ()) TABLE_LEN,
    MAX(LENGTH(COLUMN_NAME)) OVER () COLUMN_LEN
  FROM
  ( SELECT
      CC.SCHEMA_NAME,
      CC.TABLE_NAME,
      CC.COLUMN_NAME,
      TO_VARCHAR(MAX(CC.DISTINCT_COUNT)) NUM_DISTINCT,
      TO_VARCHAR(TO_DECIMAL(SUM(CC.MEMORY_SIZE_IN_TOTAL + CC.PERSISTENT_MEMORY_SIZE_IN_TOTAL) / 1024 / 1024, 10, 2)) SIZE_MB,
      MAP(MAX(TC.LENGTH), NULL, '', TO_VARCHAR(MAX(TC.LENGTH))) LENGTH,
      IFNULL(MAX(TC.DATA_TYPE_NAME), 'internal') DATA_TYPE,
      MAX(TC.IS_NULLABLE) IS_NULLABLE,
      MAP(MIN(CC.COMPRESSION_TYPE), MAX(CC.COMPRESSION_TYPE), MIN(CC.COMPRESSION_TYPE), 'various') COMPRESSION,
      MAP(MIN(CC.INDEX_TYPE), MAX(CC.INDEX_TYPE), MIN(CC.INDEX_TYPE), 'various') INDEX_TYPE,
      MAP(MIN(CC.INTERNAL_ATTRIBUTE_TYPE), MAX(CC.INTERNAL_ATTRIBUTE_TYPE), MIN(CC.INTERNAL_ATTRIBUTE_TYPE), 'various') INTERNAL_ATTRIBUTE_TYPE,
      IFNULL(TO_DECIMAL(SUM(CS.SCANNED_RECORD_COUNT) / S.TIMEFRAME_S, 18, 0), 0) SCANNED_RECS_PER_S,
      IFNULL(TO_DECIMAL(SUM(CS.INDEX_LOOKUP_COUNT) / S.TIMEFRAME_S * 3600, 18, 0), 0) INDEX_LOOKUPS_PER_H,
      IFNULL(MAX(CC.LOAD_UNIT), 'n/a') LOAD_UNIT
    FROM
      ( SELECT MAX(SECONDS_BETWEEN(START_TIME, CURRENT_TIMESTAMP)) TIMEFRAME_S FROM M_SERVICE_STATISTICS ) S,
      ACCESSED_TABLES AC,
      M_CS_ALL_COLUMNS CC LEFT OUTER JOIN
      M_CS_ALL_COLUMN_STATISTICS CS ON
        CS.SCHEMA_NAME = CC.SCHEMA_NAME AND
        CS.TABLE_NAME = CC.TABLE_NAME AND
        CS.COLUMN_NAME = CC.COLUMN_NAME AND
        CS.PART_ID = CC.PART_ID LEFT OUTER JOIN
      TABLE_COLUMNS TC ON
        TC.SCHEMA_NAME = CC.SCHEMA_NAME AND
        TC.TABLE_NAME = CC.TABLE_NAME AND
        TC.COLUMN_NAME = CC.COLUMN_NAME
    WHERE
      CC.SCHEMA_NAME = AC.SCHEMA_NAME AND
      CC.TABLE_NAME = AC.TABLE_NAME AND
      AC.IS_TEMPORARY = 'FALSE'
    GROUP BY
      S.TIMEFRAME_S,
      CC.SCHEMA_NAME,
      CC.TABLE_NAME,
      CC.COLUMN_NAME
    UNION ALL
    SELECT
      TC.SCHEMA_NAME,
      TC.TABLE_NAME,
      TC.COLUMN_NAME,
      '' NUM_DISTINCT,
      '' SIZE_MB,
      TO_VARCHAR(TC.LENGTH) LENGTH,
      TC.DATA_TYPE_NAME DATA_TYPE,
      TC.IS_NULLABLE,
      '' COMPRESSION,
      'NONE' INDEX_TYPE,
      '' INTERNAL_ATTRIBUTE_TYPE,
      -1 SCANNED_RECS_PER_S,
      -1 INDEX_LOOKUPS,
      'COLUMN' LOAD_UNIT
    FROM
      ACCESSED_TABLES AC,
      TABLE_COLUMNS TC
    WHERE
      TC.SCHEMA_NAME = AC.SCHEMA_NAME AND
      TC.TABLE_NAME = AC.TABLE_NAME AND
      AC.TABLE_TYPE = 'ROW'
  )
),
ACCESSED_INDEXES AS
( SELECT
    I.SCHEMA_NAME,
    I.TABLE_NAME,
    I.INDEX_NAME || MAP(I.PART_ID, 0, '', CHAR(32) || '(' || I.PART_ID || ')') INDEX_NAME,
    CASE
      WHEN I.INDEX_TYPE LIKE 'INVERTED VALUE%' THEN 'IV'
      WHEN I.INDEX_TYPE LIKE 'INVERTED INDIVIDUAL%' THEN 'II'
      WHEN I.INDEX_TYPE LIKE 'INVERTED HASH%' THEN 'IH'
      ELSE I.INDEX_TYPE
    END TY,
    TO_DECIMAL(I.MEMORY_SIZE_IN_TOTAL / 1024 / 1024, 10, 2) MEM_TOT_MB,
    TO_DECIMAL(I.MEMORY_SIZE_IN_CONCAT / 1024 / 1024, 10, 2) MEM_CONC_MB,
    I.INVERTED_INDIVIDUAL_COST INDIV_COSTS,
    IFNULL(I.MOST_SELECTIVE_COLUMN_NAME, '') INDIV_COLUMN,
    I.INDEX_NAME INDEX_NAME_NO_PART,
    I.PART_ID,
    GREATEST(11, MAX(LENGTH(I.SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    GREATEST(10, MAX(LENGTH(I.TABLE_NAME)) OVER ()) TABLE_LEN,
    GREATEST(10, MAX(LENGTH(I.INDEX_NAME || MAP(I.PART_ID, 0, '', CHAR(32) || '(' || I.PART_ID || ')'))) OVER ()) INDEX_LEN,
    GREATEST(12, MAX(LENGTH(I.MOST_SELECTIVE_COLUMN_NAME)) OVER ()) INDIV_COL_LEN
  FROM
    ACCESSED_TABLES T,
    M_CS_INDEXES I
  WHERE
    I.SCHEMA_NAME = T.SCHEMA_NAME AND
    I.TABLE_NAME = T.TABLE_NAME
),
ACCESSED_INDEX_COLUMNS AS
( SELECT
    SCHEMA_NAME,
    TABLE_NAME,
    INDEX_NAME,
    COLUMN_NAME,
    POSITION,
    INDEX_TYPE,
    CONSTRAINT,
    GREATEST(11, MAX(LENGTH(SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    GREATEST(10, MAX(LENGTH(TABLE_NAME)) OVER ()) TABLE_LEN,
    GREATEST(11, MAX(LENGTH(COLUMN_NAME)) OVER ()) COLUMN_LEN,
    GREATEST(10, MAX(LENGTH(INDEX_NAME)) OVER ()) INDEX_LEN,
    MAX(LENGTH(INDEX_TYPE)) OVER () INDEX_TYPE_LEN
  FROM
  ( SELECT
      IC.SCHEMA_NAME,
      IC.TABLE_NAME,
      IC.INDEX_NAME,
      IC.COLUMN_NAME,
      IC.POSITION,
      I.INDEX_TYPE,
      IC.CONSTRAINT
    FROM
      ACCESSED_TABLES AC,
      INDEX_COLUMNS IC,
      INDEXES I
    WHERE
      AC.SCHEMA_NAME = IC.SCHEMA_NAME AND
      AC.TABLE_NAME = IC.TABLE_NAME AND
      I.SCHEMA_NAME = IC.SCHEMA_NAME AND
      I.INDEX_NAME = IC.INDEX_NAME
    UNION ALL
    SELECT
      SCHEMA_NAME,
      TABLE_NAME,
      INDEX_NAME,
      COLUMN_NAME,
      POSITION,
      'CONCAT ATTRIBUTE' INDEX_TYPE,
      '' CONSTRAINT
    FROM
    ( SELECT TABLE_LEN FROM ACCESSED_TABLES ) AC,
    ( SELECT DISTINCT
        C.SCHEMA_NAME,
        C.TABLE_NAME,
        C.COLUMN_NAME INDEX_NAME,
        P.POSITION,
        SUBSTR(C.COLUMN_NAME, LOCATE(C.COLUMN_NAME, '$', 1, P.POSITION) + 1, LOCATE(C.COLUMN_NAME, '$', 1, P.POSITION + 1) - LOCATE(C.COLUMN_NAME, '$', 1, P.POSITION) - 1 ) COLUMN_NAME
      FROM
        ( SELECT TOP 50 ROW_NUMBER() OVER () POSITION FROM OBJECTS ) P,
        ACCESSED_COLUMNS C
      WHERE
        INTERNAL_ATTRIBUTE_TYPE = 'CONCAT_ATTRIBUTE' AND
        COLUMN_NAME NOT LIKE '$uc%'
    ) C
    WHERE
      C.COLUMN_NAME != '' AND
      NOT EXISTS
      ( SELECT
          1
        FROM
        ( SELECT
            '$' || STRING_AGG(IC.COLUMN_NAME, '$' ORDER BY IC.POSITION) || '$' INDEX_NAME
          FROM
            INDEX_COLUMNS IC
          WHERE
            IC.SCHEMA_NAME = C.SCHEMA_NAME AND
            IC.TABLE_NAME = C.TABLE_NAME
          GROUP BY
            IC.INDEX_NAME
        ) IC
        WHERE
          IC.INDEX_NAME = C.INDEX_NAME
      )
  )
  GROUP BY
    SCHEMA_NAME,
    TABLE_NAME,
    INDEX_NAME,
    COLUMN_NAME,
    POSITION,
    INDEX_TYPE,
    CONSTRAINT
),
ACCESSED_INDEXES_2 AS
( SELECT
    IC.SCHEMA_NAME,
    IC.TABLE_NAME,
    IC.INDEX_NAME,
    STRING_AGG(IC.COLUMN_NAME, ', ' ORDER BY IC.POSITION) COLUMN_LIST,
    AC.TABLE_LEN,
    GREATEST(11, MAX(LENGTH(IC.SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    MAX(LENGTH(IC.INDEX_NAME)) OVER () INDEX_LEN
  FROM
    ACCESSED_TABLES AC,
    INDEX_COLUMNS IC
  WHERE
    AC.SCHEMA_NAME = IC.SCHEMA_NAME AND
    AC.TABLE_NAME = IC.TABLE_NAME
  GROUP BY
    IC.SCHEMA_NAME,
    IC.TABLE_NAME,
    IC.INDEX_NAME,
    AC.TABLE_LEN
),
ACCESSED_INDEX_COLUMNS_2 AS
( SELECT
    ROW_NUMBER() OVER (ORDER BY SCHEMA_NAME, TABLE_NAME, COLUMN_NAME) ROW_NUM,
    ROW_NUMBER() OVER (PARTITION BY SCHEMA_NAME, TABLE_NAME ORDER BY COLUMN_NAME) ROW_NUM_PER_TAB,
    SCHEMA_NAME,
    TABLE_NAME,
    COLUMN_NAME,
    INDEX_TYPE,
    GREATEST(11, MAX(LENGTH(SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    GREATEST(10, MAX(LENGTH(TABLE_NAME)) OVER ()) TABLE_LEN,
    GREATEST(11, MAX(LENGTH(COLUMN_NAME)) OVER ()) COLUMN_LEN,
    MAX(LENGTH(INDEX_TYPE)) OVER () INDEX_TYPE_LEN
  FROM
  ( SELECT
      C.SCHEMA_NAME,
      C.TABLE_NAME,
      C.COLUMN_NAME,
      'INVERTED VALUE (' || C.INDEX_TYPE || ')' INDEX_TYPE
    FROM
      ACCESSED_TABLES AC,
      ACCESSED_COLUMNS C
    WHERE
      AC.SCHEMA_NAME = C.SCHEMA_NAME AND
      AC.TABLE_NAME = C.TABLE_NAME AND
      C.INDEX_TYPE != 'NONE' AND
      C.COLUMN_NAME NOT LIKE '$%' AND
      NOT EXISTS
      ( SELECT
          1
        FROM
          ACCESSED_INDEXES_2 IC
        WHERE
          AC.SCHEMA_NAME = IC.SCHEMA_NAME AND
          AC.TABLE_NAME = IC.TABLE_NAME AND
          C.COLUMN_NAME = IC.COLUMN_LIST
      )
  )
  GROUP BY
    SCHEMA_NAME,
    TABLE_NAME,
    COLUMN_NAME,
    INDEX_TYPE
),
ACCESSED_REFERENTIAL_CONSTRAINTS AS
( SELECT
    C.*,
    GREATEST(11, MAX(LENGTH(C.SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    GREATEST(10, MAX(LENGTH(C.TABLE_NAME)) OVER ()) TABLE_LEN,
    MAX(LENGTH(C.COLUMN_NAME)) OVER () COLUMN_LEN,
    GREATEST(10, MAX(LENGTH(C.REFERENCED_TABLE_NAME)) OVER ()) REF_TABLE_LEN,
    MAX(LENGTH(C.REFERENCED_COLUMN_NAME)) OVER () REF_COLUMN_LEN
  FROM
    ACCESSED_TABLES AC,
    REFERENTIAL_CONSTRAINTS C
  WHERE
    ( C.SCHEMA_NAME = AC.SCHEMA_NAME AND C.TABLE_NAME = AC.TABLE_NAME ) OR
    ( C.REFERENCED_SCHEMA_NAME = AC.SCHEMA_NAME AND C.REFERENCED_TABLE_NAME = AC.TABLE_NAME )
),
ACCESSED_REPLICAS AS
( SELECT
    R.*,
    GREATEST(11, MAX(LENGTH(R.SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    GREATEST(10, MAX(LENGTH(R.TABLE_NAME)) OVER ()) TABLE_LEN,
    GREATEST(10, MAX(LENGTH(R.SOURCE_TABLE_NAME)) OVER ()) SRC_TABLE_LEN
  FROM
    ACCESSED_TABLES AC,
    M_TABLE_REPLICAS R
  WHERE
  ( R.SOURCE_SCHEMA_NAME = AC.SCHEMA_NAME AND R.SOURCE_TABLE_NAME = AC.TABLE_NAME ) OR
  ( R.SCHEMA_NAME = AC.SCHEMA_NAME AND R.TABLE_NAME = AC.TABLE_NAME )
),
ACCESSED_TRIGGERS AS
( SELECT
    T.*,
    GREATEST(11, MAX(LENGTH(T.SUBJECT_TABLE_SCHEMA)) OVER ()) SCHEMA_LEN,
    GREATEST(10, MAX(LENGTH(T.SUBJECT_TABLE_NAME)) OVER ()) TABLE_LEN,
    GREATEST(12, MAX(LENGTH(T.TRIGGER_NAME)) OVER ()) TRIGGER_LEN
  FROM
    ACCESSED_TABLES AC,
    TRIGGERS T
  WHERE
    T.SUBJECT_TABLE_SCHEMA = AC.SCHEMA_NAME AND
    T.SUBJECT_TABLE_NAME = AC.TABLE_NAME
),
TABLE_OPTIMIZATIONS AS
( SELECT
    M.START_TIME,
    ROW_NUMBER() OVER (ORDER BY M.START_TIME DESC, M.SCHEMA_NAME, M.TABLE_NAME) LINE_NO,
    M.SCHEMA_NAME,
    M.TABLE_NAME || MAP(M.PART_ID, 0, '', CHAR(32) || '(' || M.PART_ID || ')') TABLE_NAME,
    M.HOST,
    M.TYPE,
    M.MOTIVATION,
    M.MERGED_DELTA_RECORDS MERGED_ROWS,
    TO_DECIMAL(M.EXECUTION_TIME / 1000, 10, 2) RUNTIME_S,
    TO_DECIMAL(IFNULL(GREATEST(0, RESOURCE_WAIT_TIME), 0) / 1000, 10, 0) RW_S,
    TO_DECIMAL(IFNULL(GREATEST(0, PHASE_1_HESITANT_LOCK_WAIT_TIME), 0) / 1000, 10, 0) P1_HLW_S,
    TO_DECIMAL(IFNULL(GREATEST(0, PHASE_1_BLOCKING_LOCK_WAIT_TIME), 0) / 1000, 10, 0) P1_BLW_S,
    TO_DECIMAL(IFNULL(GREATEST(0, PHASE_1_LOCK_TIME), 0) / 1000, 10, 0) P1_L_S,
    TO_DECIMAL(IFNULL(GREATEST(0, PHASE_2_HESITANT_LOCK_WAIT_TIME), 0) / 1000, 10, 0) P2_HLW_S,
    TO_DECIMAL(IFNULL(GREATEST(0, PHASE_2_BLOCKING_LOCK_WAIT_TIME), 0) / 1000, 10, 0) P2_BLW_S,
    TO_DECIMAL(IFNULL(GREATEST(0, PHASE_2_LOCK_TIME), 0) / 1000, 10, 0) P2_L_S,
    MAP(M.LAST_ERROR, '0', '0', M.LAST_ERROR || CHAR(32) || M.ERROR_DESCRIPTION) LAST_ERROR,
    GREATEST(11, MAX(LENGTH(M.SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    GREATEST(10, MAX(LENGTH(M.TABLE_NAME || MAP(M.PART_ID, 0, '', CHAR(32) || '(' || M.PART_ID || ')'))) OVER ()) TABLE_LEN,
    BI.MAX_RESULT_LINES
  FROM
    BASIS_INFO BI,
    ACCESSED_TABLES AC,
  ( SELECT DISTINCT
      START_TIME,
      SCHEMA_NAME,
      TABLE_NAME,
      PART_ID,
      HOST,
      TYPE,
      MOTIVATION,
      MERGED_DELTA_RECORDS,
      EXECUTION_TIME,
      LAST_ERROR,
      ERROR_DESCRIPTION,
      RESOURCE_WAIT_TIME,
      PHASE_1_HESITANT_LOCK_WAIT_TIME,
      PHASE_1_BLOCKING_LOCK_WAIT_TIME,
      PHASE_1_LOCK_TIME,
      PHASE_2_HESITANT_LOCK_WAIT_TIME,
      PHASE_2_BLOCKING_LOCK_WAIT_TIME,
      PHASE_2_LOCK_TIME
    FROM
    ( SELECT SITE_ID FROM BASIS_INFO ) BI,
      _SYS_STATISTICS.HOST_DELTA_MERGE_STATISTICS M
    WHERE
    ( BI.SITE_ID = -1 OR ( BI.SITE_ID = 0 AND M.SITE_ID IN (-1, 0) ) OR M.SITE_ID = BI.SITE_ID )
  ) M
  WHERE
    M.START_TIME BETWEEN BI.BEGIN_TIME AND BI.END_TIME AND
    AC.SCHEMA_NAME = M.SCHEMA_NAME AND
    AC.TABLE_NAME = M.TABLE_NAME
),
UNLOADS_AND_LOADS AS
( SELECT
    L.TYPE,
    L.ACTION_TIME,
    ROW_NUMBER() OVER (ORDER BY L.ACTION_TIME DESC, L.SCHEMA_NAME, L.TABLE_NAME) LINE_NO,
    L.SCHEMA_NAME,
    L.TABLE_NAME,
    L.COLUMN_NAME,
    L.HOST,
    L.DURATION_MS,
    L.REASON_OR_HASH,
    L.ERROR,
    GREATEST(11, MAX(LENGTH(L.SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    GREATEST(10, MAX(LENGTH(L.TABLE_NAME)) OVER ()) TABLE_LEN,
    GREATEST(11, MAX(LENGTH(L.COLUMN_NAME)) OVER ()) COLUMN_LEN,
    BI.MAX_RESULT_LINES
  FROM
    BASIS_INFO BI,
  ( SELECT
      'UNLOAD' TYPE,
      U.UNLOAD_TIME ACTION_TIME,
      U.SCHEMA_NAME,
      U.TABLE_NAME || MAP(U.PART_ID, 0, '', CHAR(32) || '(' || U.PART_ID || ')') TABLE_NAME,
      U.COLUMN_NAME,
      U.HOST,
      -1 DURATION_MS,
      U.REASON REASON_OR_HASH,
      'n/a' ERROR
    FROM
      ACCESSED_TABLES AC,
      M_CS_UNLOADS U
    WHERE
      AC.SCHEMA_NAME = U.SCHEMA_NAME AND
      AC.TABLE_NAME = U.TABLE_NAME
    UNION ALL
    SELECT
      'LOAD' TYPE,
      L.LOAD_TIME ACTION_TIME,
      L.SCHEMA_NAME,
      L.TABLE_NAME || MAP(L.PART_ID, 0, '', CHAR(32) || '(' || L.PART_ID || ')') TABLE_NAME,
      L.COLUMN_NAME,
      L.HOST,
      L.LOAD_DURATION DURATION_MS,
      L.STATEMENT_HASH REASON_OR_HASH,
      MAP(L.ERROR_CODE, '0', '0', L.ERROR_CODE || CHAR(32) || L.ERROR_TEXT) ERROR
    FROM
      ACCESSED_TABLES AC,
      M_CS_LOADS L
    WHERE
      AC.SCHEMA_NAME = L.SCHEMA_NAME AND
      AC.TABLE_NAME = L.TABLE_NAME
  ) L
  WHERE
    L.ACTION_TIME BETWEEN BI.BEGIN_TIME AND BI.END_TIME
),
EXPENSIVE_STATEMENTS AS
( SELECT
    LINE_NO,
    START_TIME,
    OPERATION,
    DURATION_MICROSEC,
    CPU_TIME,
    RECORDS,
    MEMORY_SIZE,
    ERROR_CODE,
    ERROR_TEXT,
    APP_USER,
    APPLICATION_SOURCE,
    PARAMETERS,
    STATEMENT_HASH,
    WORKLOAD_CLASS,
    STATEMENT_STRING,
    GREATEST(14, MAX(LENGTH(WORKLOAD_CLASS)) OVER ()) WLC_LEN,
    GREATEST(9, MAX(LENGTH(OPERATION)) OVER ()) OPERATION_LEN,
    GREATEST(8, MAX(LENGTH(APP_USER)) OVER ()) APP_USER_LEN,
    MAX(LENGTH(APPLICATION_SOURCE)) OVER () APP_SOURCE_LEN
  FROM
  ( SELECT
      ROW_NUMBER() OVER (ORDER BY ES.START_TIME DESC, ES.OPERATION) LINE_NO,
      ES.START_TIME,
      ES.OPERATION,
      ES.DURATION_MICROSEC,
      ES.CPU_TIME,
      ES.RECORDS,
      ES.MEMORY_SIZE,
      ES.ERROR_CODE,
      LTRIM(REPLACE(ES.ERROR_TEXT, 'column store error: search table error:', '')) ERROR_TEXT,
      ES.APP_USER,
      ES.APPLICATION_SOURCE,
      ES.PARAMETERS,
      ES.STATEMENT_HASH,
      ES.WORKLOAD_CLASS_NAME WORKLOAD_CLASS,
      SUBSTR(ES.STATEMENT_STRING, 1, 5000) STATEMENT_STRING,
      BI.MAX_RESULT_LINES
    FROM
      BASIS_INFO BI,
      M_EXPENSIVE_STATEMENTS ES
    WHERE
      ES.STATEMENT_HASH = BI.STATEMENT_HASH AND
      ES.DB_USER LIKE BI.DB_USER
  )
  WHERE
    MAX_RESULT_LINES = -1 OR LINE_NO <= MAX_RESULT_LINES
),
EXECUTED_STATEMENTS AS
( SELECT
    LINE_NO,
    START_TIME,
    DURATION_MICROSEC,
    ERROR_CODE,
    APP_USER,
    APPLICATION_SOURCE,
    STATEMENT_HASH,
    STATEMENT_STRING,
    GREATEST(8, MAX(LENGTH(APP_USER)) OVER ()) APP_USER_LEN,
    MAX(LENGTH(APPLICATION_SOURCE)) OVER () APP_SOURCE_LEN
  FROM
  ( SELECT
      ROW_NUMBER() OVER (ORDER BY ES.START_TIME DESC) LINE_NO,
      ES.START_TIME,
      ES.DURATION_MICROSEC,
      ES.ERROR_CODE,
      ES.APP_USER,
      ES.APPLICATION_SOURCE,
      ES.STATEMENT_HASH,
      SUBSTR(ES.STATEMENT_STRING, 1, 5000) STATEMENT_STRING,
      BI.MAX_RESULT_LINES
    FROM
      BASIS_INFO BI,
      M_EXECUTED_STATEMENTS ES
    WHERE
      ES.STATEMENT_HASH = BI.STATEMENT_HASH AND
      ES.DB_USER LIKE BI.DB_USER
  )
  WHERE
    MAX_RESULT_LINES = -1 OR LINE_NO <= MAX_RESULT_LINES
),
MULTIDIMENSIONAL_STATEMENT_STATISTICS AS
( SELECT
    MS.HOST,
    MS.PORT,
    MS.STATEMENT_HASH,
    SUBSTR(MS.STATEMENT_STRING, 1, 5000) STATEMENT_STRING,
    MS.USER_NAME,
    MS.APPLICATION_USER_NAME,
    MS.APPLICATION_NAME,
    MS.STATEMENT_TYPE,
    MS.EXECUTION_COUNT,
    MS.TOTAL_EXECUTION_TIME,
    MS.MAX_EXECUTION_MEMORY_SIZE
  FROM
    BASIS_INFO BI,
    M_MULTIDIMENSIONAL_STATEMENT_STATISTICS MS
  WHERE
    MS.STATEMENT_HASH = BI.STATEMENT_HASH AND
    MS.USER_NAME LIKE BI.DB_USER
),
TRANSACTIONAL_LOCKS AS
( SELECT
    B.SERVER_TIMESTAMP,
    IFNULL(B.BLOCKED_STATEMENT_HASH, '') BLOCKED_STATEMENT_HASH,
    IFNULL(B.LOCK_OWNER_STATEMENT_HASH, '') LOCK_OWNER_STATEMENT_HASH,
    TO_DECIMAL(ROUND(GREATEST(0, IFNULL(B.WAITING_MINUTES, 0) * 60)), 10, 0) WAIT_S,
    B.LOCK_TYPE,
    B.LOCK_MODE,
    B.WAITING_SCHEMA_NAME || '.' || B.WAITING_OBJECT_NAME OBJECT_NAME,
    ROW_NUMBER () OVER (ORDER BY B.SERVER_TIMESTAMP DESC) ROW_NUM,
    MAX(LENGTH(B.LOCK_TYPE)) OVER () TYPE_LEN,
    MAX(LENGTH(B.LOCK_MODE)) OVER () MODE_LEN,
    BI.MAX_RESULT_LINES
  FROM
    BASIS_INFO BI,
    _SYS_STATISTICS.HOST_BLOCKED_TRANSACTIONS B
  WHERE
    ( BI.SITE_ID = -1 OR ( BI.SITE_ID = 0 AND B.SITE_ID IN (-1, 0) ) OR B.SITE_ID = BI.SITE_ID ) AND
    BI.STATEMENT_HASH IN ( B.BLOCKED_STATEMENT_HASH, B.LOCK_OWNER_STATEMENT_HASH ) AND
    B.WAITING_SCHEMA_NAME LIKE BI.DB_USER
),
ACTIVE_STATEMENTS AS
( SELECT
    A.*
  FROM
    M_ACTIVE_STATEMENTS A,
  ( SELECT PLAN_ID FROM SQL_CACHE_CURRENT UNION SELECT PLAN_ID FROM SQL_CACHE_HISTORY ) C
  WHERE
    A.PLAN_ID = C.PLAN_ID
),
ACTIVE_PROCEDURES AS
( SELECT
    *
  FROM
  ( SELECT
      P.*,
      AP.SCHEMA_LEN,
      AP.PROCEDURE_LEN,
      BI.MAX_RESULT_LINES,
      ROW_NUMBER() OVER (ORDER BY STATEMENT_COMPILE_TIME DESC) LINE_NO
    FROM
      BASIS_INFO BI,
      ACCESSED_PROCEDURES AP,
      M_ACTIVE_PROCEDURES P
    WHERE
      AP.SCHEMA_NAME = P.PROCEDURE_SCHEMA_NAME AND
      AP.PROCEDURE_NAME = P.PROCEDURE_NAME
  )
  WHERE
  ( MAX_RESULT_LINES = -1 OR LINE_NO <= MAX_RESULT_LINES )
),
CALLSTACKS AS
( SELECT
    TC.*,
    T.THREAD_TYPE,
    T.THREAD_STATE,
    T.LOCK_WAIT_NAME
  FROM
    BASIS_INFO BI,
    M_SERVICE_THREADS T,
    M_SERVICE_THREAD_CALLSTACKS TC
  WHERE
    T.STATEMENT_HASH = BI.STATEMENT_HASH AND
    T.THREAD_ID = TC.THREAD_ID AND
    T.USER_NAME LIKE BI.DB_USER
),
OOM_EVENTS AS
( SELECT
    O.TIME,
    O.HEAP_MEMORY_CATEGORY HEAP_ALLOCATOR,
    TO_DECIMAL(O.MEMORY_USED_SIZE / 1024 / 1024 / 1024, 10, 2) MEM_USED_GB,
    O.EVENT_REASON,
    BI.MAX_RESULT_LINES,
    ROW_NUMBER () OVER (ORDER BY TIME DESC) ROW_NUM
  FROM
    BASIS_INFO BI,
    M_OUT_OF_MEMORY_EVENTS O
  WHERE
    O.STATEMENT_HASH = BI.STATEMENT_HASH
),
ADMISSION_CONTROL_EVENTS AS
( SELECT
    A.HOST,
    A.PORT,
    A.EVENT_TIME,
    A.EVENT_REASON,
    A.QUEUE_WAIT_TIME,
    A.CPU_USAGE_RATIO,
    A.MEMORY_RATIO,
    BI.MAX_RESULT_LINES,
    ROW_NUMBER () OVER (ORDER BY A.EVENT_TIME DESC) ROW_NUM
  FROM
    BASIS_INFO BI,
    M_ADMISSION_CONTROL_EVENTS A
  WHERE
    A.STATEMENT_HASH = BI.STATEMENT_HASH
),
PINNED_PLANS AS
( SELECT
    P.*
  FROM
    BASIS_INFO BI,
    PINNED_SQL_PLANS P
  WHERE
    P.STATEMENT_HASH = BI.STATEMENT_HASH
),
STMT_HINTS AS
( SELECT
    S.*,
    GREATEST(11, MAX(LENGTH(S.HINT_STRING)) OVER ()) HINT_STRING_LEN
  FROM
    BASIS_INFO BI,
    STATEMENT_HINTS S
  WHERE
    S.STATEMENT_HASH = BI.STATEMENT_HASH
),
ANNOTS AS
( SELECT DISTINCT
    S.*,
    GREATEST(11, MAX(LENGTH(S.SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    GREATEST(11, MAX(LENGTH(S.OBJECT_NAME)) OVER ()) OBJECT_LEN
  FROM
    ANNOTATIONS S,
    ACCESSED_VIEWS V
  WHERE
    S.SCHEMA_NAME = V.SCHEMA_NAME AND
    S.OBJECT_NAME = V.VIEW_NAME
),
DATA_STATS AS
( SELECT
    ROW_NUMBER () OVER (ORDER BY S.DATA_SOURCE_SCHEMA_NAME, S.OBJECT_NAME, S.DATA_SOURCE_COLUMN_NAMES) LINE_NO,
    S.DATA_SOURCE_SCHEMA_NAME,
    S.OBJECT_NAME,
    S.DATA_SOURCE_COLUMN_NAMES,
    S.DATA_STATISTICS_TYPE,
    IFNULL(JSON_VALUE(DATA_STATISTICS_CONTENT, '$.LastRefreshProperties.COUNT'), '') COUNT,
    IFNULL(JSON_VALUE(DATA_STATISTICS_CONTENT, '$.LastRefreshProperties.DISTINCT COUNT'), '') DISTINCT_COUNT,
    IFNULL(JSON_VALUE(DATA_STATISTICS_CONTENT, '$.LastRefreshProperties.NULL COUNT'), '') NULL_COUNT,
    IFNULL(JSON_VALUE(DATA_STATISTICS_CONTENT, '$.LastRefreshProperties.MINVALUE STRING'), '') MINVALUE_STRING,
    IFNULL(JSON_VALUE(DATA_STATISTICS_CONTENT, '$.LastRefreshProperties.MAXVALUE STRING'), '') MAXVALUE_STRING,
    GREATEST(11, MAX(LENGTH(S.DATA_SOURCE_SCHEMA_NAME)) OVER ()) SCHEMA_LEN,
    GREATEST(11, MAX(LENGTH(S.OBJECT_NAME)) OVER ()) OBJECT_LEN,
    GREATEST(12, MAX(LENGTH(S.DATA_SOURCE_COLUMN_NAMES)) OVER ()) COLUMN_LEN,
    GREATEST(9, MAX(LENGTH(IFNULL(JSON_VALUE(DATA_STATISTICS_CONTENT, '$.LastRefreshProperties.MINVALUE_STRING'), ''))) OVER ()) MIN_VALUE_LEN,
    GREATEST(9, MAX(LENGTH(IFNULL(JSON_VALUE(DATA_STATISTICS_CONTENT, '$.LastRefreshProperties.MAXVALUE_STRING'), ''))) OVER ()) MAX_VALUE_LEN,
    GREATEST(4, MAX(LENGTH(S.DATA_STATISTICS_TYPE)) OVER ()) TYPE_LEN,
    BI.MAX_RESULT_LINES
  FROM
    BASIS_INFO BI,
    ACCESSED_TABLES T,
    ( SELECT
        S.*,
        S.DATA_SOURCE_OBJECT_NAME || MAP(S.DATA_SOURCE_PART_ID, 0, '', CHAR(32) || '(' || S.DATA_SOURCE_PART_ID || ')') OBJECT_NAME
      FROM
        M_DATA_STATISTICS S
    ) S
  WHERE
    S.DATA_SOURCE_SCHEMA_NAME = T.SCHEMA_NAME AND
    S.DATA_SOURCE_OBJECT_NAME  = T.TABLE_NAME
),
PARAMETERS AS
( SELECT
    LAYER_NAME,
    FILE_NAME,
    SECTION,
    KEY,
    VALUE,
    MAX(LENGTH(FILE_NAME)) OVER() FILE_LEN,
    MAX(LENGTH(SECTION)) OVER() SECTION_LEN,
    MAX(LENGTH(KEY)) OVER () KEY_LEN,
    MAX(LENGTH(VALUE)) OVER () VALUE_LEN
  FROM
  ( SELECT
      LAYER_NAME,
      FILE_NAME,
      SECTION,
      KEY,
      MAX(VALUE) VALUE
    FROM
      M_CONFIGURATION_PARAMETER_VALUES
    WHERE
      KEY IN
      ( 'default_statement_concurrency_limit',
        'esx_level',
        'garbage_collect_interval_s',
        'hex_enabled',
        'hex_enable_remote_table_access',
        'max_concurrency',
        'max_concurrency_hint',
        'multistore_feature_toggle',
        'num_cores',
        'qo_small_enough_exact_estimation',
        'qo_small_enough_rough_estimation',
        'singleindex_consider_for_compressed_columns',
        'single_thread_execution_for_partitioned_tables',
        'statement_memory_limit',
        'ut_delta_rollover_switch_values'
      ) OR
      ( SECTION IN ('sql', 'hex') AND
        LAYER_NAME != 'DEFAULT'
      )
    GROUP BY
      LAYER_NAME,
      FILE_NAME,
      SECTION,
      KEY
  )
),
PARAMETER_CHANGES AS
( SELECT
    PC.*,
    IFNULL(MAX(LENGTH(FILE_NAME)) OVER (), 0) FILE_LEN,
    IFNULL(MAX(LENGTH(SECTION)) OVER (), 0) SECTION_LEN,
    GREATEST(14, IFNULL(MAX(LENGTH(KEY)) OVER (), 0)) KEY_LEN,
    GREATEST(5, IFNULL(MAX(LENGTH(VALUE)) OVER (), 0)) VALUE_LEN,
    GREATEST(10, IFNULL(MAX(LENGTH(PREV_VALUE)) OVER (), 0)) PREV_VALUE_LEN
  FROM
  ( SELECT
      PH.*,
      BI.MAX_RESULT_LINES,
      ROW_NUMBER () OVER (ORDER BY PH.TIME DESC, PH.FILE_NAME, PH.SECTION, PH.KEY) LINE_NO
    FROM
      BASIS_INFO BI,
      M_INIFILE_CONTENT_HISTORY PH
    WHERE
      TIME >= ADD_DAYS(CURRENT_TIMESTAMP, -42) AND
      SECTION IS NOT NULL
  ) PC
  WHERE
    ( MAX_RESULT_LINES = -1 OR LINE_NO <= MAX_RESULT_LINES )
),
TRACE_ENTRIES AS
( SELECT
    ROW_NUMBER() OVER (ORDER BY T.TIMESTAMP DESC) LINE_NO,
    MAP(L.LINE_NO, 1, T.TIMESTAMP, T.TIMESTAMP_SUCC) TIMESTAMP,
    MAP(L.LINE_NO, 1, T.COMPONENT, T.COMPONENT_SUCC) COMPONENT,
    MAP(L.LINE_NO, 1, T.TRACE_TEXT, T.TRACE_TEXT_SUCC) TRACE_TEXT,
    T.MAX_RESULT_LINES
  FROM
  ( SELECT 1 LINE_NO FROM DUMMY UNION ALL
    SELECT 2 LINE_NO FROM DUMMY
  ) L,
  ( SELECT
      BI.STATEMENT_HASH,
      BI.MAX_RESULT_LINES,
      T.TIMESTAMP,
      LAG(T.TIMESTAMP) OVER (PARTITION BY T.HOST, T.PORT, T.THREAD_ID ORDER BY T.TIMESTAMP) TIMESTAMP_SUCC,
      T.COMPONENT,
      LAG(T.COMPONENT) OVER (PARTITION BY T.HOST, T.PORT, T.THREAD_ID ORDER BY T.TIMESTAMP) COMPONENT_SUCC,
      T.TRACE_TEXT,
      LAG(TO_VARCHAR(T.TRACE_TEXT)) OVER (PARTITION BY T.HOST, T.PORT, T.THREAD_ID ORDER BY T.TIMESTAMP) TRACE_TEXT_SUCC
    FROM
      BASIS_INFO BI,
      M_MERGED_TRACES T
    WHERE
    ( BI.TRACE_HISTORY_S = -1 OR T.TIMESTAMP >= ADD_SECONDS(CURRENT_TIMESTAMP, -BI.TRACE_HISTORY_S) )
  ) T
  WHERE
    TO_VARCHAR(T.TRACE_TEXT) LIKE '%' || T.STATEMENT_HASH || '%' AND
    MAP(L.LINE_NO, 1, T.TIMESTAMP, T.TIMESTAMP_SUCC) IS NOT NULL
),
FEATURE_USAGE AS
( SELECT
    U.*,
    GREATEST(14, MAX(LENGTH(COMPONENT_NAME)) OVER ()) COMPONENT_LEN,
    GREATEST(12, MAX(LENGTH(FEATURE_NAME)) OVER ()) FEATURE_LEN
  FROM
    BASIS_INFO BI,
    M_FEATURE_USAGE U
  WHERE
    U.LAST_STATEMENT_HASH = BI.STATEMENT_HASH
),
EXPLAIN_PLANS AS
( SELECT
    ROW_NUMBER () OVER (ORDER BY P.PLAN_ID, E.OPERATOR_ID, L.DETAIL_LINE) LINE_NO,
    MAP(E.OPERATOR_ID, 1, MAP(L.DETAIL_LINE, 1, TO_VARCHAR(P.PLAN_ID), ''), '') PLAN_ID,
    E.OPERATOR_ID,
    L.DETAIL_LINE,
    MAP(L.DETAIL_LINE, 1, IFNULL(SUBSTR(E.EXECUTION_ENGINE, 1, 1), ''), '') E,
    MAP(L.DETAIL_LINE, 1, IFNULL(E.TABLE_NAME, ''), '') TABLE_NAME,
    MAP(L.DETAIL_LINE, 1, IFNULL(REPLACE(E.OPERATOR_NAME, CHAR(32) || CHAR(32), CHAR(32)), ''), '') OPERATOR_NAME,
    IFNULL(SUBSTR(E.OPERATOR_PROPERTIES, 50 * L.DETAIL_LINE - 49, 50), '') OPERATOR_PROPERTIES,
    IFNULL(SUBSTR(E.OPERATOR_DETAILS, 80 * L.DETAIL_LINE - 79, 80), '') OPERATOR_DETAILS,
    GREATEST(10, MAX(LENGTH(E.TABLE_NAME)) OVER ()) TABLE_LEN,
    GREATEST(13, MAX(LENGTH(REPLACE(E.OPERATOR_NAME, CHAR(32) || CHAR(32), CHAR(32)))) OVER ()) OPERATOR_LEN,
    GREATEST(19, LEAST(50, MAX(LENGTH(E.OPERATOR_PROPERTIES)) OVER ())) OPERATOR_PROP_LEN
  FROM
  ( SELECT TOP 100 ROW_NUMBER () OVER () DETAIL_LINE FROM OBJECTS ) L,
  ( SELECT DISTINCT PLAN_ID FROM SQL_CACHE_CURRENT UNION SELECT DISTINCT PLAN_ID FROM SQL_CACHE_HISTORY ) P,
    EXPLAIN_PLAN_TABLE E
  WHERE
    E.STATEMENT_NAME = 'ZDC_' || P.PLAN_ID AND
    ( LENGTH(E.OPERATOR_DETAILS) > 80 * ( L.DETAIL_LINE - 1 ) OR
      LENGTH(E.OPERATOR_PROPERTIES) > 50 * ( L.DETAIL_LINE -1 )
    )
)
SELECT
  MAP(BI.LINE_LENGTH, -1, L.LINE, SUBSTR(L.LINE, 1, BI.LINE_LENGTH)) LINE
FROM
  BASIS_INFO BI,
( SELECT   10 LINE_NO, '*******************************************' LINE                                                            FROM DUMMY UNION ALL
  SELECT   20,         '* SAP HANA STATEMENT HASH DATA COLLECTION *'                                                                 FROM DUMMY UNION ALL
  SELECT   30,         '*******************************************'                                                                 FROM DUMMY UNION ALL
  SELECT   40,         ''                                                                                                            FROM DUMMY UNION ALL
  SELECT   82, RPAD('Generated with:',             27, CHAR(32)) || 'SQL: "HANA_SQL_StatementHash_DataCollector" (SAP Note 1969700)' FROM DUMMY UNION ALL
  SELECT   85, RPAD('Start time:',                 27, CHAR(32)) || TO_VARCHAR(BEGIN_TIME, 'YYYY/MM/DD HH24:MI:SS')                  FROM BASIS_INFO WHERE TO_VARCHAR(BEGIN_TIME, 'YYYY') >= '2000' UNION ALL
  SELECT   86, RPAD('End time:',                   27, CHAR(32)) || TO_VARCHAR(LEAST(CURRENT_TIMESTAMP, END_TIME), 'YYYY/MM/DD HH24:MI:SS') FROM BASIS_INFO UNION ALL
  SELECT   92, RPAD('System ID / database name:',  27, CHAR(32)) || SYSTEM_ID || CHAR(32) || '/' || CHAR(32) || DATABASE_NAME        FROM M_DATABASE UNION ALL
  SELECT   94, RPAD('Revision level:',             27, CHAR(32)) || VERSION                                                          FROM M_DATABASE UNION ALL
  SELECT  100, RPAD('Statement hash:',             27, CHAR(32)) || STATEMENT_HASH                                                   FROM BASIS_INFO UNION ALL
  SELECT  110, RPAD('Plan ID:',                    27, CHAR(32)) || TO_VARCHAR(PLAN_ID)                                              FROM BASIS_INFO WHERE PLAN_ID != -1 UNION ALL
  SELECT  120, ''                                                                                                                    FROM DUMMY UNION ALL
  SELECT 1000, '***************' FROM DUMMY UNION ALL
  SELECT 1010, '* KEY FIGURES *' FROM DUMMY UNION ALL
  SELECT 1020, '***************' FROM DUMMY UNION ALL
  SELECT 1030, ''                FROM DUMMY UNION ALL
  SELECT 1070, RPAD('STAT_NAME', 25) || RPAD('VALUE', 33) || LPAD('VALUE_PER_EXEC', 15) || LPAD('VALUE_PER_ROW', 15) FROM DUMMY UNION ALL
  SELECT 1080, RPAD('=', 24, '=') || CHAR(32) || RPAD('=', 32, '=') || CHAR(32) || LPAD('=', 15, '=') || CHAR(32) || LPAD('=', 14, '=') FROM DUMMY UNION ALL
  SELECT * FROM ( SELECT
    1100 + L.LINE_NO * 10 LINE_NO,
    RPAD(L.STAT_NAME, 25) ||
    RPAD(CASE
      WHEN L.LINE_NO =  1 THEN C.STATEMENT_HASH
      WHEN L.LINE_NO =  3 THEN RTRIM(MAX(CASE WHEN C.TABLE_TYPES LIKE '%COLUMN%' THEN 'COL' || ',' ELSE '' END) || MAX(CASE WHEN C.TABLE_TYPES LIKE '%ROW%' THEN 'ROW' || ',' ELSE '' END), ',') || CHAR(32) || '/' || CHAR(32) ||
        MAP(MAX(C.IS_DISTRIBUTED_EXECUTION), 'TRUE', 'dist.', 'local') || CHAR(32) || '/' || CHAR(32) ||
        RTRIM(MAX(CASE WHEN C.ENGINES LIKE '%COLUMN%' THEN 'COL' || ',' ELSE '' END) || MAX(CASE WHEN C.ENGINES LIKE '%ESX%' THEN 'ESX' || ',' ELSE '' END) ||
          MAX(CASE WHEN C.ENGINES LIKE '%HEX%' THEN 'HEX' || ',' ELSE '' END) || MAX(CASE WHEN C.ENGINES LIKE '%OLAP%' THEN 'OLAP' || ',' ELSE '' END) ||
          MAX(CASE WHEN C.ENGINES LIKE '%EXTERNAL%' THEN 'EXT' || ',' ELSE '' END) || MAX(CASE WHEN C.ENGINES LIKE '%SQLSCRIPT%' THEN 'SQLSCRIPT' || ',' ELSE '' END) ||
          MAX(CASE WHEN C.ENGINES LIKE '%ROW%' THEN 'ROW' || ',' ELSE '' END), ',')
      WHEN L.LINE_NO =  6 THEN MAX(C.APPLICATION_SOURCE)
      WHEN L.LINE_NO =  7 THEN MAX(C.USER_NAME)
      WHEN L.LINE_NO =  8 THEN TO_VARCHAR(MAX(C.LAST_CONNECTION_ID))
      WHEN L.LINE_NO = 10 THEN LPAD(SUM(C.EXECUTION_COUNT), 32)
      WHEN L.LINE_NO = 11 THEN LPAD(SUM(C.TOTAL_RESULT_RECORD_COUNT), 32)
      WHEN L.LINE_NO = 12 THEN LPAD(SUM(C.PREPARATION_COUNT), 32)
      WHEN L.LINE_NO = 14 THEN LPAD(SUM(C.TOTAL_SERVICE_NETWORK_REQUEST_COUNT), 32)
      WHEN L.LINE_NO = 15 THEN LPAD(SUM(C.TOTAL_CALLED_THREAD_COUNT), 32)
      WHEN L.LINE_NO = 20 THEN LPAD(TO_DECIMAL(SUM(C.TOTAL_CURSOR_DURATION)                     / 1000 / BI.TIME_FACTOR, 10, 2) || CHAR(32) || BI.TIME_UNIT, 32)
      WHEN L.LINE_NO = 21 THEN LPAD(TO_DECIMAL(SUM(C.TOTAL_EXECUTION_TIME)                      / 1000 / BI.TIME_FACTOR, 10, 2) || CHAR(32) || BI.TIME_UNIT, 32)
      WHEN L.LINE_NO = 22 THEN LPAD(TO_DECIMAL(SUM(C.TOTAL_EXECUTION_CPU_TIME)                  / 1000 / BI.TIME_FACTOR, 10, 2) || CHAR(32) || BI.TIME_UNIT, 32)
      WHEN L.LINE_NO = 23 THEN LPAD(TO_DECIMAL(SUM(C.TOTAL_TABLE_LOAD_TIME_DURING_PREPARATION)  / 1000 / BI.TIME_FACTOR, 10, 2) || CHAR(32) || BI.TIME_UNIT, 32)
      WHEN L.LINE_NO = 24 THEN LPAD(TO_DECIMAL(SUM(C.TOTAL_PREPARATION_TIME)                    / 1000 / BI.TIME_FACTOR, 10, 2) || CHAR(32) || BI.TIME_UNIT, 32)
      WHEN L.LINE_NO = 28 THEN LPAD(TO_DECIMAL(SUM(C.TOTAL_LOCK_WAIT_DURATION)                  / 1000 / BI.TIME_FACTOR, 10, 2) || CHAR(32) || BI.TIME_UNIT, 32)
      WHEN L.LINE_NO = 29 THEN LPAD(TO_DECIMAL(SUM(C.TOTAL_SERVICE_NETWORK_REQUEST_DURATION)    / 1000 / BI.TIME_FACTOR, 10, 2) || CHAR(32) || BI.TIME_UNIT, 32)
      WHEN L.LINE_NO = 31 THEN LPAD(TO_DECIMAL(SUM(C.TOTAL_EXECUTION_MEMORY_SIZE)               / 1024 / 1024 / 1024, 10, 2) || CHAR(32) || 'GB', 32)
      WHEN L.LINE_NO = 32 THEN LPAD(TO_DECIMAL(SUM(C.TOTAL_SERVICE_NETWORK_REQUEST_SIZE)        / 1024 / 1024 / 1024, 10, 2) || CHAR(32) || 'GB', 32)
      WHEN L.LINE_NO = 33 THEN LPAD(TO_DECIMAL(SUM(C.TOTAL_BUFFER_CACHE_IO_READ_SIZE)           / 1024 / 1024 / 1024, 10, 2) || CHAR(32) || 'GB', 32)
      ELSE ' '
    END , MAP(L.LINE_NO, 3, 100, 6, 100, 32)) ||
    LPAD(CASE
      WHEN L.LINE_NO = 11 THEN LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.TOTAL_RESULT_RECORD_COUNT)                       / SUM(C.EXECUTION_COUNT)), 12, 2), 14)
      WHEN L.LINE_NO = 12 THEN LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.PREPARATION_COUNT)                               / SUM(C.EXECUTION_COUNT)), 12, 2), 14)
      WHEN L.LINE_NO = 14 THEN LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.TOTAL_SERVICE_NETWORK_REQUEST_COUNT)             / SUM(C.EXECUTION_COUNT)), 12, 2), 14)
      WHEN L.LINE_NO = 15 THEN LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.TOTAL_CALLED_THREAD_COUNT)                       / SUM(C.EXECUTION_COUNT)), 12, 2), 14)
      WHEN L.LINE_NO = 20 THEN LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.TOTAL_CURSOR_DURATION)                    / 1000 / SUM(C.EXECUTION_COUNT)), 12, 2) || ' ms', 14)
      WHEN L.LINE_NO = 21 THEN LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.TOTAL_EXECUTION_TIME)                     / 1000 / SUM(C.EXECUTION_COUNT)), 12, 2) || ' ms', 14)
      WHEN L.LINE_NO = 22 THEN LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.TOTAL_EXECUTION_CPU_TIME)                 / 1000 / SUM(C.EXECUTION_COUNT)), 12, 2) || ' ms', 14)
      WHEN L.LINE_NO = 23 THEN LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.TOTAL_TABLE_LOAD_TIME_DURING_PREPARATION) / 1000 / SUM(C.EXECUTION_COUNT)), 12, 2) || ' ms', 14)
      WHEN L.LINE_NO = 24 THEN LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.TOTAL_PREPARATION_TIME)                   / 1000 / SUM(C.EXECUTION_COUNT)), 12, 2) || ' ms', 14)
      WHEN L.LINE_NO = 28 THEN LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.TOTAL_LOCK_WAIT_DURATION)                 / 1000 / SUM(C.EXECUTION_COUNT)), 12, 2) || ' ms', 14)
      WHEN L.LINE_NO = 29 THEN LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.TOTAL_SERVICE_NETWORK_REQUEST_DURATION)   / 1000 / SUM(C.EXECUTION_COUNT)), 12, 2) || ' ms', 14)
      WHEN L.LINE_NO = 31 THEN LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.TOTAL_EXECUTION_MEMORY_SIZE)        / 1024 / 1024 / SUM(C.EXECUTION_COUNT)), 12, 2) || ' MB', 14)
      WHEN L.LINE_NO = 32 THEN LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.TOTAL_SERVICE_NETWORK_REQUEST_SIZE) / 1024 / 1024 / SUM(C.EXECUTION_COUNT)), 12, 2) || ' MB', 14)
      WHEN L.LINE_NO = 33 THEN LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.TOTAL_BUFFER_CACHE_IO_READ_SIZE)    / 1024 / 1024 / SUM(C.EXECUTION_COUNT)), 12, 2) || ' MB', 14)
      ELSE ' ' END, 16) ||
    LPAD(CASE
      WHEN L.LINE_NO = 20 THEN LPAD(TO_DECIMAL(MAP(SUM(C.TOTAL_RESULT_RECORD_COUNT), 0, 0, SUM(C.TOTAL_CURSOR_DURATION)                    / 1000 / SUM(C.TOTAL_RESULT_RECORD_COUNT)), 12, 2) || ' ms', 13)
      WHEN L.LINE_NO = 21 THEN LPAD(TO_DECIMAL(MAP(SUM(C.TOTAL_RESULT_RECORD_COUNT), 0, 0, SUM(C.TOTAL_EXECUTION_TIME)                     / 1000 / SUM(C.TOTAL_RESULT_RECORD_COUNT)), 12, 2) || ' ms', 13)
      WHEN L.LINE_NO = 22 THEN LPAD(TO_DECIMAL(MAP(SUM(C.TOTAL_RESULT_RECORD_COUNT), 0, 0, SUM(C.TOTAL_EXECUTION_CPU_TIME)                 / 1000 / SUM(C.TOTAL_RESULT_RECORD_COUNT)), 12, 2) || ' ms', 13)
      WHEN L.LINE_NO = 23 THEN LPAD(TO_DECIMAL(MAP(SUM(C.TOTAL_RESULT_RECORD_COUNT), 0, 0, SUM(C.TOTAL_TABLE_LOAD_TIME_DURING_PREPARATION) / 1000 / SUM(C.TOTAL_RESULT_RECORD_COUNT)), 12, 2) || ' ms', 13)
      WHEN L.LINE_NO = 24 THEN LPAD(TO_DECIMAL(MAP(SUM(C.TOTAL_RESULT_RECORD_COUNT), 0, 0, SUM(C.TOTAL_PREPARATION_TIME)                   / 1000 / SUM(C.TOTAL_RESULT_RECORD_COUNT)), 12, 2) || ' ms', 13)
      WHEN L.LINE_NO = 28 THEN LPAD(TO_DECIMAL(MAP(SUM(C.TOTAL_RESULT_RECORD_COUNT), 0, 0, SUM(C.TOTAL_LOCK_WAIT_DURATION)                 / 1000 / SUM(C.TOTAL_RESULT_RECORD_COUNT)), 12, 2) || ' ms', 13)
      WHEN L.LINE_NO = 29 THEN LPAD(TO_DECIMAL(MAP(SUM(C.TOTAL_RESULT_RECORD_COUNT), 0, 0, SUM(C.TOTAL_SERVICE_NETWORK_REQUEST_DURATION)   / 1000 / SUM(C.TOTAL_RESULT_RECORD_COUNT)), 12, 2) || ' ms', 13)
      ELSE ' ' END, 15) LINE
  FROM
    BASIS_INFO BI,
    ( SELECT
        *
      FROM
        SQL_CACHE_HISTORY
      UNION ALL
      SELECT
        *
      FROM
        SQL_CACHE_CURRENT
      WHERE
        NOT EXISTS ( SELECT * FROM SQL_CACHE_HISTORY )
    ) C,
    ( SELECT  1 LINE_NO, 'Statement hash' STAT_NAME FROM DUMMY UNION ALL
      SELECT  3, 'Type / dist. / engines'           FROM DUMMY UNION ALL
      SELECT  6, 'Application source'               FROM DUMMY UNION ALL
      SELECT  7, 'Database user name'               FROM DUMMY UNION ALL
      SELECT  8, 'Last connection ID'               FROM DUMMY UNION ALL
      SELECT  9, ''                                 FROM DUMMY UNION ALL
      SELECT 10, 'Executions'                       FROM DUMMY UNION ALL
      SELECT 11, 'Records'                          FROM DUMMY UNION ALL
      SELECT 12, 'Preparations'                     FROM DUMMY UNION ALL
      SELECT 14, 'Network requests'                 FROM DUMMY UNION ALL
      SELECT 15, 'Called thread count'              FROM DUMMY UNION ALL
      SELECT 19, ''                                 FROM DUMMY UNION ALL
      SELECT 20, 'Cursor duration'                  FROM DUMMY UNION ALL
      SELECT 21, 'Execution time'                   FROM DUMMY UNION ALL
      SELECT 22, 'CPU time'                         FROM DUMMY UNION ALL
      SELECT 23, 'Table load time'                  FROM DUMMY UNION ALL
      SELECT 24, 'Preparation time'                 FROM DUMMY UNION ALL
      SELECT 28, 'Lock wait time'                   FROM DUMMY UNION ALL
      SELECT 29, 'Network request time'             FROM DUMMY UNION ALL
      SELECT 30, ''                                 FROM DUMMY UNION ALL
      SELECT 31, 'Memory size'                      FROM DUMMY UNION ALL
      SELECT 32, 'Network request size'             FROM DUMMY UNION ALL
      SELECT 33, 'NSE I/O read size'                FROM DUMMY
    ) L
  GROUP BY
    C.STATEMENT_HASH,
    L.LINE_NO,
    L.STAT_NAME,
    BI.BEGIN_TIME,
    BI.END_TIME,
    BI.TIME_FACTOR,
    BI.TIME_UNIT
  )
  WHERE
    LINE_NO = 1210 OR ( LINE NOT LIKE '% 0 % 0.00 %' AND LINE NOT LIKE '% 0.00 % 0.00 %' )
  UNION ALL
  SELECT 1990, ''                   FROM DUMMY UNION ALL
  SELECT 2000, '******************' FROM DUMMY UNION ALL
  SELECT 2010, '* STATEMENT TEXT *' FROM DUMMY UNION ALL
  SELECT 2020, '******************' FROM DUMMY UNION ALL
  SELECT 2030, ''                   FROM DUMMY UNION ALL
  SELECT 2100 + LINE_NO / 1000, SUBSTR(SQL_TEXT, START_POS, END_POS - START_POS - 1)
  FROM
  ( SELECT
      SQL_TEXT,
      SQL_TEXT_LENGTH,
      LINE_NO,
      LAST_LINE_NO,
      MAP(LINE_NO, 1, 0, ( 80 * ( LINE_NO - 1) ) + START_POS) START_POS,
      MAP(END_POS, 0, SQL_TEXT_LENGTH + 2, ( 80 * LINE_NO ) + END_POS) END_POS
    FROM
    ( SELECT
        SQL_TEXT,
        SQL_TEXT_LENGTH,
        LINE_NO,
        CEIL(SQL_TEXT_LENGTH / 80) LAST_LINE_NO,
        CASE
          WHEN NUM_BLANKS >= NUM_COMMAS THEN LOCATE(SUBSTR(SQL_TEXT, ( LINE_NO - 1) * 80), CHAR(32))
          WHEN NUM_COMMAS >  NUM_BLANKS THEN LOCATE(SUBSTR(SQL_TEXT, ( LINE_NO - 1) * 80), ',')
        END START_POS,
        CASE
          WHEN NUM_BLANKS >= NUM_COMMAS THEN LOCATE(SUBSTR(SQL_TEXT, LINE_NO        * 80), CHAR(32))
          WHEN NUM_COMMAS >  NUM_BLANKS THEN LOCATE(SUBSTR(SQL_TEXT, LINE_NO        * 80), ',')
        END END_POS
      FROM
      ( SELECT
          O.LINE_NO,
          S.SQL_TEXT_LENGTH,
          S.SQL_TEXT,
          LENGTH(S.SQL_TEXT) - LENGTH(REPLACE(S.SQL_TEXT, ',', '')) NUM_COMMAS,
          LENGTH(S.SQL_TEXT) - LENGTH(REPLACE(S.SQL_TEXT, CHAR(32), '')) NUM_BLANKS
        FROM
          BASIS_INFO BI,
        ( SELECT TOP 1
            *
          FROM
          ( SELECT TOP 1
              STATEMENT_HASH,
              STATEMENT_STRING SQL_TEXT,
              LENGTH(STATEMENT_STRING) SQL_TEXT_LENGTH
            FROM
              SQL_CACHE_CURRENT
            UNION
            SELECT TOP 1
              STATEMENT_HASH,
              STATEMENT_STRING SQL_TEXT,
              LENGTH(STATEMENT_STRING) SQL_TEXT_LENGTH
            FROM
              SQL_CACHE_HISTORY
            UNION
            SELECT TOP 1
              STATEMENT_HASH,
              STATEMENT_STRING SQL_TEXT,
              LENGTH(STATEMENT_STRING) SQL_TEXT_LENGTH
            FROM
              EXPENSIVE_STATEMENTS
            UNION
            SELECT TOP 1
              STATEMENT_HASH,
              STATEMENT_STRING SQL_TEXT,
              LENGTH(STATEMENT_STRING) SQL_TEXT_LENGTH
            FROM
              EXECUTED_STATEMENTS
            UNION
            SELECT TOP 1
              STATEMENT_HASH,
              STATEMENT_STRING SQL_TEXT,
              LENGTH(STATEMENT_STRING) SQL_TEXT_LENGTH
            FROM
              MULTIDIMENSIONAL_STATEMENT_STATISTICS
          )
        ) S,
        ( SELECT TOP 1000
            ROW_NUMBER () OVER () LINE_NO
          FROM
            OBJECTS
        ) O
        WHERE
          BI.STATEMENT_HASH = S.STATEMENT_HASH AND
          O.LINE_NO <= CEIL(S.SQL_TEXT_LENGTH / 80)
      )
    )
    WHERE
      START_POS != 0
  ) UNION ALL
  SELECT TOP 1 2490, ''                FROM BIND_VALUES UNION ALL
  SELECT TOP 1 2500, '***************' FROM BIND_VALUES UNION ALL
  SELECT TOP 1 2510, '* BIND VALUES *' FROM BIND_VALUES UNION ALL
  SELECT TOP 1 2520, '***************' FROM BIND_VALUES UNION ALL
  SELECT TOP 1 2530, ''                FROM BIND_VALUES UNION ALL
  SELECT TOP 1 2580, RPAD('EXECUTION_TIME', 19) || CHAR(32) || RPAD('DATA_TYPE', 14) || CHAR(32) || LPAD('POS', 4) || CHAR(32) || RPAD('BIND_VALUE', 50) FROM BIND_VALUES UNION ALL
  SELECT TOP 1 2590, RPAD('=', 19, '=') || CHAR(32) || RPAD('=', 14, '=') || CHAR(32) || LPAD('=', 4, '=') || CHAR(32) || RPAD('=', 50, '=') FROM BIND_VALUES UNION ALL
  SELECT 2600 + LINE_NO / 1000,
    RPAD(IFNULL(TO_VARCHAR(EXECUTION_TIMESTAMP, 'YYYY/MM/DD HH24:MI:SS'), ''), 20) || RPAD(DATA_TYPE_NAME, 15) || LPAD(POSITION, 4) || CHAR(32) || RPAD(PARAMETER_VALUE, 80)
  FROM
    BIND_VALUES
  WHERE
  ( MAX_RESULT_LINES = -1 OR SHOW_COMPLETE_BIND_VALUE_LIST = 'X' OR LINE_NO <= MAX_RESULT_LINES ) UNION ALL
  SELECT TOP 1 2690, ''                  FROM EXPLAIN_PLANS UNION ALL
  SELECT TOP 1 2700, '*****************' FROM EXPLAIN_PLANS UNION ALL
  SELECT TOP 1 2710, '* EXPLAIN PLANS *' FROM EXPLAIN_PLANS UNION ALL
  SELECT TOP 1 2720, '*****************' FROM EXPLAIN_PLANS UNION ALL
  SELECT TOP 1 2730, ''                  FROM EXPLAIN_PLANS UNION ALL
  SELECT TOP 1 2780, LPAD('PLAN_ID', 13) || CHAR(32) || RPAD('E', 1) || CHAR(32) || RPAD('TABLE_NAME', TABLE_LEN) || CHAR(32) || RPAD('OPERATOR_NAME', OPERATOR_LEN) || CHAR(32) ||
    RPAD('OPERATOR_PROPERTIES', OPERATOR_PROP_LEN) || CHAR(32) || RPAD('OPERATOR_DETAILS', 80) FROM EXPLAIN_PLANS UNION ALL
  SELECT TOP 1 2790, LPAD('=', 13, '=') || CHAR(32) || RPAD('=', 1, '=') || CHAR(32) || RPAD('=', TABLE_LEN, '=') || CHAR(32) || RPAD('=', OPERATOR_LEN, '=') || CHAR(32) ||
    RPAD('=', OPERATOR_PROP_LEN, '=') || CHAR(32) || RPAD('=', 80, '=') FROM EXPLAIN_PLANS UNION ALL
  SELECT 2800 + LINE_NO / 1000, LPAD(PLAN_ID, 13) || CHAR(32) || RPAD(E, 1) || CHAR(32) || RPAD(TABLE_NAME, TABLE_LEN) || CHAR(32) || RPAD(OPERATOR_NAME, OPERATOR_LEN) || CHAR(32) ||
    RPAD(OPERATOR_PROPERTIES, OPERATOR_PROP_LEN) || CHAR(32) || RPAD(OPERATOR_DETAILS, 80) FROM EXPLAIN_PLANS UNION ALL
  SELECT 2990, ''              FROM DUMMY UNION ALL
  SELECT 3000, '*************' FROM DUMMY UNION ALL
  SELECT 3010, '* SQL CACHE *' FROM DUMMY UNION ALL
  SELECT 3020, '*************' FROM DUMMY UNION ALL
  SELECT 3030, ''              FROM DUMMY UNION ALL
  SELECT 3080, RPAD('SNAPSHOT_TIME', 20) || RPAD('HOST', HOST_LEN) || CHAR(32) || LPAD('PLAN_ID', 13) || CHAR(32) || RPAD('ENG', 4) || CHAR(32) || LPAD('EXECUTIONS', 14) || CHAR(32) ||
    LPAD('RECORDS', 14) || CHAR(32) || LPAD('REC_PER_EXEC', 14) || CHAR(32) || LPAD('EXEC_S', 12) || CHAR(32) || LPAD('AVG_EXEC_MS', 13) || CHAR(32) || LPAD('AVG_CPU_MS', 13) || CHAR(32) || LPAD('AVG_REC_MS', 12) || CHAR(32) ||
    LPAD('PREPARES', 8) || CHAR(32) || LPAD('PREPARE_MS', 11) || CHAR(32) || LPAD('LOCK_S', 10) || CHAR(32) || RPAD('HINT', 4) FROM BASIS_INFO UNION ALL
  SELECT 3090, RPAD('=', 19, '=') || CHAR(32) || RPAD('=', HOST_LEN, '=') || CHAR(32) || LPAD('=', 13, '=') || CHAR(32) || RPAD('=', 4, '=') || CHAR(32) || LPAD('=', 14, '=') || CHAR(32) ||
    LPAD('=', 14, '=') || CHAR(32) || LPAD('=', 14, '=') || CHAR(32) || LPAD('=', 12, '=') || CHAR(32) || LPAD('=', 13, '=') || CHAR(32) || LPAD('=', 13, '=') || CHAR(32) || LPAD('=', 12, '=') || CHAR(32) ||
    LPAD('=', 8, '=') || CHAR(32) || LPAD('=', 11, '=') || CHAR(32) || LPAD('=', 10, '=') || CHAR(32) || RPAD('=', 4, '=') FROM BASIS_INFO UNION ALL
  SELECT 3100, RPAD('CURRENT', 20) ||
    RPAD(HOST, HOST_LEN) || CHAR(32) ||
    LPAD(PLAN_ID, 13) || CHAR(32) ||
    RPAD(CASE WHEN ENGINES LIKE '%COLUMN%' THEN 'C' ELSE '' END || CASE WHEN ENGINES LIKE '%ESX%' THEN 'E' ELSE '' END ||
      CASE WHEN ENGINES LIKE '%HEX%' THEN 'H' ELSE '' END || CASE WHEN ENGINES LIKE '%OLAP%' THEN 'O' ELSE '' END ||
      CASE WHEN ENGINES LIKE '%EXTERNAL%' THEN 'X' ELSE '' END || CASE WHEN ENGINES LIKE '%SQLSCRIPT%' THEN 'S' ELSE '' END ||
      CASE WHEN ENGINES LIKE '%ROW%' THEN 'R' ELSE '' END, 4) || CHAR(32) ||
    LPAD(EXECUTION_COUNT, 14) || CHAR(32) ||
    LPAD(TOTAL_RESULT_RECORD_COUNT, 14) || CHAR(32) ||
    LPAD(TO_DECIMAL(MAP(EXECUTION_COUNT, 0, 0, TOTAL_RESULT_RECORD_COUNT / EXECUTION_COUNT), 10, 2), 14) || CHAR(32) ||
    LPAD(TO_DECIMAL(TOTAL_EXECUTION_TIME / 1000000, 20, 2), 12) || CHAR(32) ||
    LPAD(TO_DECIMAL(MAP(EXECUTION_COUNT, 0, 0, TOTAL_EXECUTION_TIME / EXECUTION_COUNT / 1000), 10, 2), 13) || CHAR(32) ||
    LPAD(TO_DECIMAL(MAP(EXECUTION_COUNT, 0, 0, TOTAL_EXECUTION_CPU_TIME / EXECUTION_COUNT / 1000), 10, 2), 13) || CHAR(32) ||
    LPAD(TO_DECIMAL(MAP(TOTAL_RESULT_RECORD_COUNT, 0, 0, TOTAL_EXECUTION_TIME / TOTAL_RESULT_RECORD_COUNT / 1000), 10, 2), 12) || CHAR(32) ||
    LPAD(PREPARATION_COUNT, 8) || CHAR(32) ||
    LPAD(TO_DECIMAL(ROUND(TOTAL_PREPARATION_TIME / 1000), 14, 0), 11) || CHAR(32) ||
    LPAD(TO_DECIMAL(ROUND(TOTAL_LOCK_WAIT_DURATION / 1000000), 14, 0), 10) || CHAR(32) ||
    RPAD(HINT, 4)
  FROM
  ( SELECT HOST_LEN FROM BASIS_INFO ),
    SQL_CACHE_CURRENT
  UNION ALL
  SELECT 3200 + C.LINE_NO / 100, RPAD(TO_VARCHAR(C.SERVER_TIMESTAMP, 'YYYY/MM/DD HH24:MI:SS'), 20) ||
    RPAD(C.HOST, BI.HOST_LEN) || CHAR(32) ||
    LPAD(C.PLAN_ID, 13) || CHAR(32) ||
    RPAD(CASE WHEN ENGINES LIKE '%COLUMN%' THEN 'C' ELSE '' END || CASE WHEN ENGINES LIKE '%ESX%' THEN 'E' ELSE '' END ||
      CASE WHEN ENGINES LIKE '%HEX%' THEN 'H' ELSE '' END || CASE WHEN ENGINES LIKE '%OLAP%' THEN 'O' ELSE '' END ||
      CASE WHEN ENGINES LIKE '%EXTERNAL%' THEN 'X' ELSE '' END || CASE WHEN ENGINES LIKE '%SQLSCRIPT%' THEN 'S' ELSE '' END ||
      CASE WHEN ENGINES LIKE '%ROW%' THEN 'R' ELSE '' END, 4) ||
    LPAD(C.EXECUTION_COUNT, 15) ||
    LPAD(C.TOTAL_RESULT_RECORD_COUNT, 15) ||
    LPAD(TO_DECIMAL(MAP(C.EXECUTION_COUNT, 0, 0, C.TOTAL_RESULT_RECORD_COUNT / C.EXECUTION_COUNT), 10, 2), 15) ||
    LPAD(TO_DECIMAL(C.TOTAL_EXECUTION_TIME / 1000000, 20, 2), 13) ||
    LPAD(TO_DECIMAL(MAP(C.EXECUTION_COUNT, 0, 0, C.TOTAL_EXECUTION_TIME / C.EXECUTION_COUNT / 1000), 10, 2), 14) ||
    LPAD(TO_DECIMAL(MAP(C.EXECUTION_COUNT, 0, 0, C.TOTAL_EXECUTION_CPU_TIME / C.EXECUTION_COUNT / 1000), 10, 2), 14) ||
    LPAD(TO_DECIMAL(MAP(TOTAL_RESULT_RECORD_COUNT, 0, 0, TOTAL_EXECUTION_TIME / TOTAL_RESULT_RECORD_COUNT / 1000), 10, 2), 13) ||
    LPAD(C.PREPARATION_COUNT, 9) ||
    LPAD(TO_DECIMAL(ROUND(C.TOTAL_PREPARATION_TIME / 1000), 15, 0), 12) ||
    LPAD(TO_DECIMAL(ROUND(C.TOTAL_LOCK_WAIT_DURATION / 1000000), 15, 0), 11) || CHAR(32) ||
    RPAD(HINT, 4)
  FROM
    BASIS_INFO BI,
    SQL_CACHE_HISTORY C
  WHERE
  ( BI.MAX_RESULT_LINES = -1 OR C.LINE_NO <= BI.MAX_RESULT_LINES ) UNION ALL
  SELECT 3300, ''              FROM DUMMY UNION ALL
  SELECT 3310, RPAD('SNP_TIME', 10) || CHAR(32) || RPAD('HOST', HOST_LEN) || CHAR(32) || LPAD('PLAN_ID', 13) || CHAR(32) || RPAD('ENG', 4) || CHAR(32) || LPAD('EXECUTIONS', 14) || CHAR(32) ||
    LPAD('RECORDS', 14) || CHAR(32) || LPAD('REC_PER_EXEC', 14) || CHAR(32) || LPAD('EXEC_S', 12) || CHAR(32) || LPAD('AVG_EXEC_MS', 13) || CHAR(32) || LPAD('AVG_CPU_MS', 13) || CHAR(32) || LPAD('AVG_REC_MS', 12) || CHAR(32) ||
    LPAD('PREPARES', 8) || CHAR(32) || LPAD('PREPARE_MS', 11) || CHAR(32) || LPAD('LOCK_S', 10) || CHAR(32) || RPAD('HINT', 4) FROM ( SELECT HOST_LEN FROM BASIS_INFO ) UNION ALL
  SELECT 3320, RPAD('=', 10, '=') || CHAR(32) || RPAD('=', HOST_LEN, '=') || CHAR(32) || LPAD('=', 13, '=')  || CHAR(32) || RPAD('=', 4, '=') || CHAR(32) || LPAD('=', 14, '=') || CHAR(32) ||
    LPAD('=', 14, '=') || CHAR(32) || LPAD('=', 14, '=') || CHAR(32) || LPAD('=', 12, '=') || CHAR(32) || LPAD('=', 13, '=') || CHAR(32) || LPAD('=', 13, '=') || CHAR(32) || LPAD('=', 12, '=') || CHAR(32) ||
    LPAD('=', 8, '=') || CHAR(32) || LPAD('=', 11, '=') || CHAR(32) || LPAD('=', 10, '=') || CHAR(32) || RPAD('=', 4, '=') FROM ( SELECT HOST_LEN FROM BASIS_INFO ) UNION ALL
  SELECT
    LINE_NO,
    LINE
  FROM
  ( SELECT BI.MAX_RESULT_LINES, ROW_NUMBER () OVER (ORDER BY TO_VARCHAR(C.SERVER_TIMESTAMP, 'YYYY/MM/DD') DESC) ROWNO, 3330 + MIN(C.LINE_NO) / 1000 LINE_NO, RPAD(TO_VARCHAR(C.SERVER_TIMESTAMP, 'YYYY/MM/DD'), 10) || CHAR(32) ||
      RPAD(C.HOST, BI.HOST_LEN) || CHAR(32) ||
      LPAD(C.PLAN_ID, 13) || CHAR(32) ||
      RPAD(MAX(CASE WHEN ENGINES LIKE '%COLUMN%' THEN 'C' ELSE '' END) || MAX(CASE WHEN ENGINES LIKE '%ESX%' THEN 'E' ELSE '' END) ||
        MAX(CASE WHEN ENGINES LIKE '%HEX%' THEN 'H' ELSE '' END) || MAX(CASE WHEN ENGINES LIKE '%OLAP%' THEN 'O' ELSE '' END) ||
        MAX(CASE WHEN ENGINES LIKE '%EXTERNAL%' THEN 'X' ELSE '' END) || MAX(CASE WHEN ENGINES LIKE '%SQLSCRIPT%' THEN 'S' ELSE '' END) ||
        MAX(CASE WHEN ENGINES LIKE '%ROW%' THEN 'R' ELSE '' END), 4) || CHAR(32) ||
      LPAD(SUM(C.EXECUTION_COUNT), 14) || CHAR(32) ||
      LPAD(SUM(C.TOTAL_RESULT_RECORD_COUNT), 14) || CHAR(32) ||
      LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.TOTAL_RESULT_RECORD_COUNT) / SUM(C.EXECUTION_COUNT)), 10, 2), 14) || CHAR(32) ||
      LPAD(TO_DECIMAL(SUM(C.TOTAL_EXECUTION_TIME) / 1000000, 20, 2), 12) || CHAR(32) ||
      LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.TOTAL_EXECUTION_TIME) / SUM(C.EXECUTION_COUNT) / 1000), 10, 2), 13) || CHAR(32) ||
      LPAD(TO_DECIMAL(MAP(SUM(C.EXECUTION_COUNT), 0, 0, SUM(C.TOTAL_EXECUTION_CPU_TIME) / SUM(C.EXECUTION_COUNT) / 1000), 10, 2), 13) || CHAR(32) ||
      LPAD(TO_DECIMAL(MAP(SUM(C.TOTAL_RESULT_RECORD_COUNT), 0, 0, SUM(C.TOTAL_EXECUTION_TIME) / SUM(C.TOTAL_RESULT_RECORD_COUNT) / 1000), 10, 2), 12) || CHAR(32) ||
      LPAD(SUM(C.PREPARATION_COUNT), 8) || CHAR(32) ||
      LPAD(TO_DECIMAL(ROUND(SUM(C.TOTAL_PREPARATION_TIME) / 1000), 15, 0), 11) || CHAR(32) ||
      LPAD(TO_DECIMAL(ROUND(SUM(C.TOTAL_LOCK_WAIT_DURATION) / 1000000), 15, 0), 10)  || CHAR(32) ||
      RPAD(MAX(HINT), 4) LINE
    FROM
      BASIS_INFO BI,
      SQL_CACHE_HISTORY C
    GROUP BY
      BI.MAX_RESULT_LINES,
      BI.HOST_LEN,
      TO_VARCHAR(C.SERVER_TIMESTAMP, 'YYYY/MM/DD'),
      C.PLAN_ID,
      C.HOST
  )
  WHERE
  ( MAX_RESULT_LINES = -1 OR ROWNO <= GREATEST(42, MAX_RESULT_LINES) )
  UNION ALL
  SELECT 3340, ''              FROM DUMMY UNION ALL
  SELECT 3341, RPAD('SNAPSHOT_TIME', 19) || CHAR(32) || LPAD('PLAN_MEM_KB', 11) || CHAR(32) || LPAD('AVG_MEM_MB', 10) || CHAR(32) || RPAD('MAX_MEM_MB', 10) || CHAR(32) ||
    LPAD('AVG_NSE_PINNED_MB', 17) || CHAR(32) || LPAD('MAX_NSE_PINNED_MB', 17) || CHAR(32) || LPAD('AVG_NSE_IO_MB', 13) || CHAR(32) || LPAD('MAX_NSE_IO_MB', 13) || CHAR(32) ||
    RPAD('LAST_PREPARE_TIME', 19) || CHAR(32) || RPAD('LAST_INVALIDATION_REASON', 50) FROM BASIS_INFO UNION ALL
  SELECT 3342, RPAD('=', 19, '=') || CHAR(32) || RPAD('=', 11, '=') || CHAR(32) || LPAD('=', 10, '=') || CHAR(32) || RPAD('=', 10, '=') || CHAR(32) ||
    LPAD('=', 17, '=') || CHAR(32) || LPAD('=', 17, '=') || CHAR(32) || LPAD('=', 13, '=') || CHAR(32) || LPAD('=', 13, '=') || CHAR(32) ||
    RPAD('=', 19, '=') || CHAR(32) || RPAD('=', 50, '=') FROM BASIS_INFO UNION ALL
  SELECT 3343, RPAD('CURRENT', 19) || CHAR(32) ||
    LPAD(TO_DECIMAL(ROUND(PLAN_MEMORY_SIZE / 1024)), 11) || CHAR(32) ||
    LPAD(TO_DECIMAL(ROUND(AVG_EXECUTION_MEMORY_SIZE / 1024 / 1024)), 10) || CHAR(32) ||
    LPAD(TO_DECIMAL(ROUND(MAX_EXECUTION_MEMORY_SIZE / 1024 / 1024)), 10) || CHAR(32) ||
    LPAD(TO_DECIMAL(ROUND(AVG_BUFFER_CACHE_PINNED_MEMORY_SIZE / 1024 / 1024)), 17) || CHAR(32) ||
    LPAD(TO_DECIMAL(ROUND(MAX_BUFFER_CACHE_PINNED_MEMORY_SIZE / 1024 / 1024)), 17) || CHAR(32) ||
    LPAD(TO_DECIMAL(ROUND(AVG_BUFFER_CACHE_IO_READ_SIZE / 1024 / 1024)), 13) || CHAR(32) ||
    LPAD(TO_DECIMAL(ROUND(MAX_BUFFER_CACHE_IO_READ_SIZE / 1024 / 1024)), 13) || CHAR(32) ||
    RPAD(TO_VARCHAR(LAST_PREPARATION_TIMESTAMP, 'YYYY/MM/DD HH24:MI:SS'), 19) || CHAR(32) ||
    LAST_INVALIDATION_REASON
  FROM
  ( SELECT HOST_LEN FROM BASIS_INFO ),
    SQL_CACHE_CURRENT
  UNION ALL
  SELECT 3345 + C.LINE_NO / 100, RPAD(TO_VARCHAR(C.SERVER_TIMESTAMP, 'YYYY/MM/DD HH24:MI:SS'), 20) ||
    LPAD(TO_DECIMAL(ROUND(C.PLAN_MEMORY_SIZE / 1024)), 11) || CHAR(32) ||
    LPAD(TO_DECIMAL(ROUND(C.AVG_EXECUTION_MEMORY_SIZE / 1024 / 1024)), 10) || CHAR(32) ||
    LPAD(TO_DECIMAL(ROUND(C.MAX_EXECUTION_MEMORY_SIZE / 1024 / 1024)), 10) || CHAR(32) ||
    LPAD(IFNULL(TO_VARCHAR(TO_DECIMAL(ROUND(C.AVG_BUFFER_CACHE_PINNED_MEMORY_SIZE / 1024 / 1024))), 'n/a'), 17) || CHAR(32) ||
    LPAD(IFNULL(TO_VARCHAR(TO_DECIMAL(ROUND(C.MAX_BUFFER_CACHE_PINNED_MEMORY_SIZE / 1024 / 1024))), 'n/a'), 17) || CHAR(32) ||
    LPAD(IFNULL(TO_VARCHAR(TO_DECIMAL(ROUND(C.AVG_BUFFER_CACHE_IO_READ_SIZE / 1024 / 1024))), 'n/a'), 13) || CHAR(32) ||
    LPAD(IFNULL(TO_VARCHAR(TO_DECIMAL(ROUND(C.MAX_BUFFER_CACHE_IO_READ_SIZE / 1024 / 1024))), 'n/a'), 13) || CHAR(32) ||
    RPAD(TO_VARCHAR(LAST_PREPARATION_TIMESTAMP, 'YYYY/MM/DD HH24:MI:SS'), 19) || CHAR(32) ||
    C.LAST_INVALIDATION_REASON
  FROM
    BASIS_INFO BI,
    SQL_CACHE_HISTORY C
  WHERE
  ( BI.MAX_RESULT_LINES = -1 OR C.LINE_NO <= BI.MAX_RESULT_LINES )
  UNION ALL
  SELECT 3350, ''              FROM DUMMY UNION ALL
  SELECT 3351, RPAD('SNP_TIME', 10) || CHAR(32) || LPAD('PLAN_MEM_KB', 11) || CHAR(32) || LPAD('AVG_MEM_MB', 10) || CHAR(32) || RPAD('MAX_MEM_MB', 10) || CHAR(32) ||
    LPAD('AVG_NSE_PINNED_MB', 17) || CHAR(32) || LPAD('MAX_NSE_PINNED_MB', 17) || CHAR(32) || LPAD('AVG_NSE_IO_MB', 13) || CHAR(32) || LPAD('MAX_NSE_IO_MB', 13) || CHAR(32) ||
    RPAD('LAST_PREPARE_TIME', 19) || CHAR(32) || RPAD('LAST_INVALIDATION_REASON', 50) FROM BASIS_INFO UNION ALL
  SELECT 3352, RPAD('=', 10, '=') || CHAR(32) || RPAD('=', 11, '=') || CHAR(32) || LPAD('=', 10, '=') || CHAR(32) || RPAD('=', 10, '=') || CHAR(32) ||
    LPAD('=', 17, '=') || CHAR(32) || LPAD('=', 17, '=') || CHAR(32) || LPAD('=', 13, '=') || CHAR(32) || LPAD('=', 13, '=') || CHAR(32) ||
    RPAD('=', 19, '=') || CHAR(32) || RPAD('=', 50, '=') FROM BASIS_INFO UNION ALL
  SELECT
    LINE_NO,
    LINE
  FROM
  ( SELECT BI.MAX_RESULT_LINES, ROW_NUMBER () OVER (ORDER BY TO_VARCHAR(C.SERVER_TIMESTAMP, 'YYYY/MM/DD') DESC) ROWNO, 3355 + MIN(C.LINE_NO) / 1000 LINE_NO, RPAD(TO_VARCHAR(C.SERVER_TIMESTAMP, 'YYYY/MM/DD'), 10) || CHAR(32) ||
      LPAD(TO_DECIMAL(ROUND(MAX(C.PLAN_MEMORY_SIZE) / 1024)), 11) || CHAR(32) ||
      LPAD(TO_DECIMAL(ROUND(AVG(C.AVG_EXECUTION_MEMORY_SIZE) / 1024 / 1024)), 10) || CHAR(32) ||
      LPAD(TO_DECIMAL(ROUND(MAX(C.MAX_EXECUTION_MEMORY_SIZE) / 1024 / 1024)), 10) || CHAR(32) ||
      LPAD(TO_DECIMAL(ROUND(AVG(C.AVG_BUFFER_CACHE_PINNED_MEMORY_SIZE) / 1024 / 1024)), 17) || CHAR(32) ||
      LPAD(TO_DECIMAL(ROUND(MAX(C.MAX_BUFFER_CACHE_PINNED_MEMORY_SIZE) / 1024 / 1024)), 17) || CHAR(32) ||
      LPAD(TO_DECIMAL(ROUND(AVG(C.AVG_BUFFER_CACHE_IO_READ_SIZE) / 1024 / 1024)), 13) || CHAR(32) ||
      LPAD(TO_DECIMAL(ROUND(MAX(C.MAX_BUFFER_CACHE_IO_READ_SIZE) / 1024 / 1024)), 13) || CHAR(32) ||
      RPAD(TO_VARCHAR(MAX(LAST_PREPARATION_TIMESTAMP), 'YYYY/MM/DD HH24:MI:SS'), 19) || CHAR(32) ||
      MAP(MIN(C.LAST_INVALIDATION_REASON), MAX(C.LAST_INVALIDATION_REASON), MIN(C.LAST_INVALIDATION_REASON), 'various') LINE
    FROM
      BASIS_INFO BI,
      SQL_CACHE_HISTORY C
    GROUP BY
      BI.MAX_RESULT_LINES,
      BI.HOST_LEN,
      TO_VARCHAR(C.SERVER_TIMESTAMP, 'YYYY/MM/DD'),
      C.PLAN_ID,
      C.HOST
  )
  WHERE
  ( MAX_RESULT_LINES = -1 OR ROWNO <= GREATEST(42, MAX_RESULT_LINES) )
  UNION ALL
  SELECT 3390, ''                             FROM MULTIDIMENSIONAL_STATEMENT_STATISTICS UNION ALL
  SELECT 3400, '****************************' FROM MULTIDIMENSIONAL_STATEMENT_STATISTICS UNION ALL
  SELECT 3401, '* MDS STATEMENT STATISTICS *' FROM MULTIDIMENSIONAL_STATEMENT_STATISTICS UNION ALL
  SELECT 3402, '****************************' FROM MULTIDIMENSIONAL_STATEMENT_STATISTICS UNION ALL
  SELECT 3403, ''                             FROM MULTIDIMENSIONAL_STATEMENT_STATISTICS UNION ALL
  SELECT 3410, RPAD('HOST', HOST_LEN) || CHAR(32) ||  'EXECUTIONS TOT_TIME_S AVG_TIME_S MAX_MEM_MB TYPE      APPLICATION_NAME              DB_USER                       APPLICATION_USER             ' FROM ( SELECT HOST_LEN FROM BASIS_INFO ), MULTIDIMENSIONAL_STATEMENT_STATISTICS UNION ALL
  SELECT 3420, RPAD('=', HOST_LEN, '=') || CHAR(32) || '========== ========== ========== ========== ========= ============================= ============================= =============================' FROM ( SELECT HOST_LEN FROM BASIS_INFO ), MULTIDIMENSIONAL_STATEMENT_STATISTICS UNION ALL
  SELECT 3430, RPAD(HOST, HOST_LEN) || CHAR(32) || LPAD(EXECUTION_COUNT, 10) || LPAD(TO_DECIMAL(TOTAL_EXECUTION_TIME / 1000, 10, 2), 11) ||
    LPAD(TO_DECIMAL(MAP(EXECUTION_COUNT, 0, 0, TOTAL_EXECUTION_TIME / EXECUTION_COUNT), 10, 2), 11) || LPAD(TO_DECIMAL(MAX_EXECUTION_MEMORY_SIZE / 1024 / 1024, 10, 2), 11) || CHAR(32) ||
    RPAD(STATEMENT_TYPE, 10) || RPAD(APPLICATION_NAME, 30) || RPAD(USER_NAME, 30) || RPAD(APPLICATION_USER_NAME, 30)
  FROM
    ( SELECT HOST_LEN FROM BASIS_INFO ),
    MULTIDIMENSIONAL_STATEMENT_STATISTICS
  UNION ALL
  SELECT TOP 1 3490, ''                     FROM ACCESSED_VIEWS UNION ALL
  SELECT TOP 1 3491, '********************' FROM ACCESSED_VIEWS UNION ALL
  SELECT TOP 1 3492, '* VIEW INFORMATION *' FROM ACCESSED_VIEWS UNION ALL
  SELECT TOP 1 3493, '********************' FROM ACCESSED_VIEWS UNION ALL
  SELECT TOP 1 3494, ''                     FROM ACCESSED_VIEWS UNION ALL
  SELECT TOP 1 3495, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('VIEW_NAME', VIEW_LEN) || CHAR(32) || RPAD('VIEW_TYPE', 10) || CHAR(32) || RPAD('DEPENDENT_OBJECTS', 79) FROM ACCESSED_VIEWS UNION ALL
  SELECT TOP 1 3496, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', VIEW_LEN, '=') || CHAR(32) || RPAD('=', 10, '=') || CHAR(32) || RPAD('=', 79, '=') FROM ACCESSED_VIEWS UNION ALL
  SELECT 3500 + ROW_NUMBER() OVER (ORDER BY V.SCHEMA_NAME, V.VIEW_NAME) / 1000, RPAD(V.SCHEMA_NAME, SCHEMA_LEN) || CHAR(32) || RPAD(V.VIEW_NAME, VIEW_LEN) || CHAR(32) || RPAD(V.VIEW_TYPE, 10) ||
    CHAR(32) || STRING_AGG(D.BASE_OBJECT_NAME, ', ' ORDER BY D.BASE_OBJECT_NAME)
  FROM
    ACCESSED_VIEWS V,
    OBJECT_DEPENDENCIES D
  WHERE
    V.SCHEMA_NAME = D.DEPENDENT_SCHEMA_NAME AND
    V.VIEW_NAME = D.DEPENDENT_OBJECT_NAME
  GROUP BY
    V.SCHEMA_NAME,
    V.VIEW_NAME,
    V.VIEW_TYPE,
    V.VIEW_LEN,
    V.SCHEMA_LEN
  UNION ALL
  SELECT TOP 1 3590, ''                          FROM ACCESSED_PROCEDURES UNION ALL
  SELECT TOP 1 3591, '*************************' FROM ACCESSED_PROCEDURES UNION ALL
  SELECT TOP 1 3592, '* PROCEDURE INFORMATION *' FROM ACCESSED_PROCEDURES UNION ALL
  SELECT TOP 1 3593, '*************************' FROM ACCESSED_PROCEDURES UNION ALL
  SELECT TOP 1 3594, ''                          FROM ACCESSED_PROCEDURES UNION ALL
  SELECT TOP 1 3595, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('PROCEDURE_NAME', PROCEDURE_LEN) || CHAR(32) || RPAD('PROC_TYPE', 10) || CHAR(32) || RPAD('DEPENDENT_OBJECTS', 79) FROM ACCESSED_PROCEDURES UNION ALL
  SELECT TOP 1 3596, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', PROCEDURE_LEN, '=') || CHAR(32) || RPAD('=', 10, '=') || CHAR(32) || RPAD('=', 79, '=') FROM ACCESSED_PROCEDURES UNION ALL
  SELECT 3600 + ROW_NUMBER() OVER (ORDER BY P.SCHEMA_NAME, P.PROCEDURE_NAME) / 100, RPAD(P.SCHEMA_NAME, SCHEMA_LEN) || CHAR(32) || RPAD(P.PROCEDURE_NAME, PROCEDURE_LEN) || CHAR(32) || RPAD(P.PROCEDURE_TYPE, 10) ||
    CHAR(32) || IFNULL(STRING_AGG(D.BASE_OBJECT_NAME, ', ' ORDER BY D.BASE_OBJECT_NAME), '')
  FROM
    ACCESSED_PROCEDURES P LEFT OUTER JOIN
    OBJECT_DEPENDENCIES D ON
      P.SCHEMA_NAME = D.DEPENDENT_SCHEMA_NAME AND
      P.PROCEDURE_NAME = D.DEPENDENT_OBJECT_NAME
  GROUP BY
    P.SCHEMA_NAME,
    P.PROCEDURE_NAME,
    P.PROCEDURE_TYPE,
    P.PROCEDURE_LEN,
    P.SCHEMA_LEN
  UNION ALL
  SELECT TOP 1 3650, ''                         FROM ACCESSED_FUNCTIONS UNION ALL
  SELECT TOP 1 3651, '************************' FROM ACCESSED_FUNCTIONS UNION ALL
  SELECT TOP 1 3652, '* FUNCTION INFORMATION *' FROM ACCESSED_FUNCTIONS UNION ALL
  SELECT TOP 1 3653, '************************' FROM ACCESSED_FUNCTIONS UNION ALL
  SELECT TOP 1 3654, ''                         FROM ACCESSED_FUNCTIONS UNION ALL
  SELECT TOP 1 3655, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('FUNCTION_NAME', FUNCTION_LEN) || CHAR(32) || RPAD('FUNC_TYPE', 10) || CHAR(32) ||
    RPAD('USAGE_TYPE', 10) || CHAR(32) || RPAD('DEPENDENT_OBJECTS', 79) FROM ACCESSED_FUNCTIONS UNION ALL
  SELECT TOP 1 3656, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', FUNCTION_LEN, '=') || CHAR(32) || RPAD('=', 10, '=') || CHAR(32) ||
    RPAD('=', 10, '=') || CHAR(32) || RPAD('=', 79, '=') FROM ACCESSED_FUNCTIONS UNION ALL
  SELECT 3660 + ROW_NUMBER() OVER (ORDER BY F.SCHEMA_NAME, F.FUNCTION_NAME) / 100, RPAD(F.SCHEMA_NAME, SCHEMA_LEN) || CHAR(32) || RPAD(F.FUNCTION_NAME, FUNCTION_LEN) || CHAR(32) || RPAD(F.FUNCTION_TYPE, 10) || CHAR(32) ||
    RPAD(F.USAGE_TYPE, 10) || CHAR(32) ||IFNULL(STRING_AGG(D.BASE_OBJECT_NAME, ', ' ORDER BY D.BASE_OBJECT_NAME), '')
  FROM
    ACCESSED_FUNCTIONS F LEFT OUTER JOIN
    OBJECT_DEPENDENCIES D ON
      F.SCHEMA_NAME = D.DEPENDENT_SCHEMA_NAME AND
      F.FUNCTION_NAME = D.DEPENDENT_OBJECT_NAME
  GROUP BY
    F.SCHEMA_NAME,
    F.FUNCTION_NAME,
    F.FUNCTION_TYPE,
    F.USAGE_TYPE,
    F.FUNCTION_LEN,
    F.SCHEMA_LEN
  UNION ALL
  SELECT TOP 1 3700, ''                                 FROM ACCESSED_CALCVIEWS UNION ALL
  SELECT TOP 1 3701, '********************************' FROM ACCESSED_CALCVIEWS UNION ALL
  SELECT TOP 1 3702, '* CALCULATION VIEW INFORMATION *' FROM ACCESSED_CALCVIEWS UNION ALL
  SELECT TOP 1 3703, '********************************' FROM ACCESSED_CALCVIEWS UNION ALL
  SELECT TOP 1 3704, ''                                 FROM ACCESSED_CALCVIEWS UNION ALL
  SELECT TOP 1 3708, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('CALCVIEW_NAME', VIEW_LEN) || CHAR(32) || RPAD('CALCNODE_NAME', 29) || CHAR(32) || 'SCENARIO_NAME' FROM ACCESSED_CALCVIEWS UNION ALL
  SELECT TOP 1 3709, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', VIEW_LEN, '=') || CHAR(32) || RPAD('=', 29, '=') || CHAR(32) || RPAD('=', 59, '=') FROM ACCESSED_CALCVIEWS UNION ALL
  SELECT 3710 + ROW_NUMBER() OVER (ORDER BY SCHEMA_NAME, VIEW_NAME) / 100, RPAD(SCHEMA_NAME, SCHEMA_LEN) || CHAR(32) || RPAD(VIEW_NAME, VIEW_LEN) || CHAR(32) || RPAD(CALCNODE_NAME, 29) || CHAR(32) || SCENARIO_NAME
  FROM
    ACCESSED_CALCVIEWS
  UNION ALL
  SELECT TOP 1 3800, ''                                     FROM ACCESSED_CALCSCENARIOS UNION ALL
  SELECT TOP 1 3801, '************************************' FROM ACCESSED_CALCSCENARIOS UNION ALL
  SELECT TOP 1 3802, '* CALCULATION SCENARIO INFORMATION *' FROM ACCESSED_CALCSCENARIOS UNION ALL
  SELECT TOP 1 3803, '************************************' FROM ACCESSED_CALCSCENARIOS UNION ALL
  SELECT TOP 1 3804, ''                                     FROM ACCESSED_CALCSCENARIOS UNION ALL
  SELECT TOP 1 3808, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('SCENARIO_NAME', SCENARIO_LEN) || CHAR(32) || RPAD('PERSISTENT', 10) || CHAR(32) ||
    RPAD('CREATE_TIME', 19) || CHAR(32) || LPAD('MEM_SIZE_KB', 11) || CHAR(32) || RPAD('SCENARIO_HINTS', 40) || CHAR(32) || 'COMPONENT' FROM ACCESSED_CALCSCENARIOS UNION ALL
  SELECT TOP 1 3809, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', SCENARIO_LEN, '=') || CHAR(32) || RPAD('=', 10, '=') || CHAR(32) ||
    RPAD('=', 19, '=') || CHAR(32) || LPAD('=', 11, '=') || CHAR(32) || RPAD('=', 40, '=') || CHAR(32) || RPAD('=', 59, '=') FROM ACCESSED_CALCSCENARIOS UNION ALL
  SELECT 3810 + ROW_NUMBER() OVER (ORDER BY SCENARIO_NAME) / 1000, RPAD(SCHEMA_NAME, SCHEMA_LEN) || CHAR(32) || RPAD(SCENARIO_NAME, SCENARIO_LEN) || CHAR(32) || RPAD(IS_PERSISTENT, 10) || CHAR(32) ||
    RPAD(CREATE_TIME, 19) || CHAR(32) || LPAD(TO_DECIMAL(MEMORY_SIZE / 1024, 10, 2), 11) || CHAR(32) || RPAD(SCENARIO_HINTS, 40) || CHAR(32) || COMPONENT
  FROM
    ACCESSED_CALCSCENARIOS
  UNION ALL
  SELECT TOP 1 3990, ''                      FROM ACCESSED_TABLES UNION ALL
  SELECT TOP 1 4000, '*********************' FROM ACCESSED_TABLES UNION ALL
  SELECT TOP 1 4010, '* TABLE INFORMATION *' FROM ACCESSED_TABLES UNION ALL
  SELECT TOP 1 4020, '*********************' FROM ACCESSED_TABLES UNION ALL
  SELECT TOP 1 4030, ''                      FROM ACCESSED_TABLES UNION ALL
  SELECT TOP 1 4080, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('TABLE_NAME', TABLE_LEN) || CHAR(32) || RPAD('TYPE', 6) || CHAR(32) ||
    LPAD('PARTS', 6) || CHAR(32) || LPAD('RECORDS', 11) || CHAR(32) || LPAD('MEM_TOTAL_GB', 12) || CHAR(32) || LPAD('MEM_DELTA_GB', 12) || CHAR(32) || LPAD('CURR_DISK_GB', 12) || CHAR(32) ||
    LPAD('MIN_DISK_GB', 11) || CHAR(32) || LPAD('MAX_DISK_GB', 11) || CHAR(32) || RPAD('LOAD_UNIT', 9) || CHAR(32) || RPAD('HOST', HOST_LEN) || CHAR(32) ||
    LPAD('TABLE_SCANS_PER_S', 17) FROM ( SELECT HOST_LEN FROM BASIS_INFO ), ACCESSED_TABLES UNION ALL
  SELECT TOP 1 4090, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', TABLE_LEN, '=') || CHAR(32) || RPAD('=', 6, '=') || CHAR(32) ||
    LPAD('=', 6, '=') || CHAR(32) || LPAD('=', 11, '=') || CHAR(32) || LPAD('=', 12, '=') || CHAR(32) || LPAD('=', 12, '=') || CHAR(32) || LPAD('=', 12, '=') || CHAR(32) ||
    LPAD('=', 11, '=') || CHAR(32) || LPAD('=', 11, '=') || CHAR(32) || RPAD('=', 9, '=') || CHAR(32) || RPAD('=', HOST_LEN, '=') || CHAR(32) ||
    LPAD('=', 17, '=') FROM ( SELECT HOST_LEN FROM BASIS_INFO ), ACCESSED_TABLES UNION ALL
  SELECT 4100 + ROW_NUMBER() OVER (ORDER BY SCHEMA_NAME, TABLE_NAME), RPAD(SCHEMA_NAME, SCHEMA_LEN) || CHAR(32) || RPAD(TABLE_NAME, TABLE_LEN) || CHAR(32) || RPAD(TABLE_TYPE, 6) || CHAR(32) ||
    LPAD(PARTITIONS, 6) || CHAR(32) || LPAD(RECORDS, 11) || CHAR(32) || LPAD(IFNULL(MEM_TOTAL_GB, 0.00), 12) || CHAR(32) || LPAD(IFNULL(MEM_DELTA_GB, 0.00), 12) || CHAR(32) || LPAD(IFNULL(CURR_DISK_GB, 0.00), 12) || CHAR(32) ||
    LPAD(IFNULL(TO_VARCHAR(MIN_DISK_GB), 'n/a'), 11) || CHAR(32) || LPAD(IFNULL(TO_VARCHAR(MAX_DISK_GB), 'n/a'), 11) || CHAR(32) || RPAD(LOAD_UNIT, 9) || CHAR(32) ||
    RPAD(HOST, HOST_LEN) || CHAR(32) || LPAD(TABLE_SCANS_PER_S, 17)
  FROM
  ( SELECT HOST_LEN FROM BASIS_INFO ),
  ( SELECT TOP 1 TABLE_LEN FROM ACCESSED_TABLES ),
  ( SELECT
      T.SCHEMA_NAME,
      T.TABLE_NAME,
      T.HOST,
      T.TABLE_TYPE,
      T.PARTITIONS,
      T.RECORDS,
      T.MEM_TOTAL_GB,
      T.MEM_DELTA_GB,
      T.TABLE_SCANS_PER_S,
      T.SCHEMA_LEN,
      T.LOAD_UNIT,
      ( SELECT TO_DECIMAL(SUM(D.DISK_SIZE / 1024 / 1024 / 1024), 10, 2) FROM M_TABLE_PERSISTENCE_STATISTICS D WHERE D.SCHEMA_NAME = T.SCHEMA_NAME AND D.TABLE_NAME = T.TABLE_NAME ) CURR_DISK_GB,
      ( SELECT TO_DECIMAL(MIN(DISK_SIZE / 1024 / 1024 / 1024), 10, 2) FROM ( SELECT SUM(D.DISK_SIZE) DISK_SIZE FROM
          _SYS_STATISTICS.GLOBAL_TABLE_PERSISTENCE_STATISTICS D WHERE D.SITE_ID IN (-1, 0, CURRENT_SITE_ID()) AND D.SCHEMA_NAME = T.SCHEMA_NAME AND D.TABLE_NAME = T.TABLE_NAME GROUP BY D.SNAPSHOT_ID ) ) MIN_DISK_GB,
      ( SELECT TO_DECIMAL(MAX(DISK_SIZE / 1024 / 1024 / 1024), 10, 2) FROM ( SELECT SUM(D.DISK_SIZE) DISK_SIZE FROM
          _SYS_STATISTICS.GLOBAL_TABLE_PERSISTENCE_STATISTICS D WHERE D.SITE_ID IN (-1, 0, CURRENT_SITE_ID()) AND D.SCHEMA_NAME = T.SCHEMA_NAME AND D.TABLE_NAME = T.TABLE_NAME GROUP BY D.SNAPSHOT_ID ) ) MAX_DISK_GB
    FROM
    ( SELECT
        T.SCHEMA_NAME,
        T.TABLE_NAME,
        MAP(MIN(T.HOST), MAX(T.HOST), MIN(T.HOST), 'various') HOST,
        'COLUMN' TABLE_TYPE,
        COUNT(*) PARTITIONS,
        SUM(T.RECORD_COUNT) RECORDS,
        TO_DECIMAL(SUM((T.MEMORY_SIZE_IN_TOTAL + T.PERSISTENT_MEMORY_SIZE_IN_TOTAL) / 1024 / 1024 / 1024), 10, 2) MEM_TOTAL_GB,
        TO_DECIMAL(SUM(T.MEMORY_SIZE_IN_DELTA / 1024 / 1024 / 1024), 10, 2) MEM_DELTA_GB,
        0 TABLE_SCANS_PER_S,
        MAX(AC.LOAD_UNIT) LOAD_UNIT,
        AC.SCHEMA_LEN
      FROM
        ACCESSED_TABLES AC,
        M_CS_TABLES T
      WHERE
        AC.SCHEMA_NAME = T.SCHEMA_NAME AND
        AC.TABLE_NAME = T.TABLE_NAME
      GROUP BY
        T.SCHEMA_NAME,
        T.TABLE_NAME,
        AC.SCHEMA_LEN
      UNION ALL
      SELECT
        T.SCHEMA_NAME,
        T.TABLE_NAME,
        MAP(MIN(T.HOST), MAX(T.HOST), MIN(T.HOST), 'various') HOST,
        'ROW' TABLE_TYPE,
        1 PARTITIONS,
        SUM(T.RECORD_COUNT) RECORDS,
        TO_DECIMAL(SUM((T.ALLOCATED_FIXED_PART_SIZE + T.ALLOCATED_VARIABLE_PART_SIZE) / 1024 / 1024 / 1024), 10, 2) MEM_TOTAL_GB,
        0 MEM_DELTA_GB,
        TO_DECIMAL(SUM(T.SCAN_COUNT) / S.TIMEFRAME_S, 10, 2) TABLE_SCANS_PER_S,
        'COLUMN' LOAD_UNIT,
        AC.SCHEMA_LEN
      FROM
      ( SELECT MAX(SECONDS_BETWEEN(START_TIME, CURRENT_TIMESTAMP)) TIMEFRAME_S FROM M_SERVICE_STATISTICS ) S,
        ACCESSED_TABLES AC,
        M_RS_TABLES T
      WHERE
        AC.SCHEMA_NAME = T.SCHEMA_NAME AND
        AC.TABLE_NAME = T.TABLE_NAME
      GROUP BY
        S.TIMEFRAME_S,
        T.SCHEMA_NAME,
        T.TABLE_NAME,
        AC.SCHEMA_LEN
    ) T
  ) UNION ALL
  SELECT TOP 1 4490, ''                              FROM ACCESSED_VIRTUAL_TABLES UNION ALL
  SELECT TOP 1 4500, '*****************************' FROM ACCESSED_VIRTUAL_TABLES UNION ALL
  SELECT TOP 1 4510, '* VIRTUAL TABLE INFORMATION *' FROM ACCESSED_VIRTUAL_TABLES UNION ALL
  SELECT TOP 1 4520, '*****************************' FROM ACCESSED_VIRTUAL_TABLES UNION ALL
  SELECT TOP 1 4530, ''                              FROM ACCESSED_VIRTUAL_TABLES UNION ALL
  SELECT TOP 1 4580, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('TABLE_NAME', TABLE_LEN) || CHAR(32) || RPAD('REMOTE_SOURCE_NAME', REMOTE_SOURCE_LEN) || CHAR(32) ||
    RPAD('REMOTE_OBJECT_NAME', REMOTE_OBJECT_LEN) FROM ACCESSED_VIRTUAL_TABLES UNION ALL
  SELECT TOP 1 4590, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', TABLE_LEN, '=') || CHAR(32) || RPAD('=', REMOTE_SOURCE_LEN, '=') || CHAR(32) ||
    RPAD('=', REMOTE_OBJECT_LEN, '=') FROM ACCESSED_VIRTUAL_TABLES UNION ALL
  SELECT 4600 + ROW_NUMBER() OVER (ORDER BY SCHEMA_NAME, TABLE_NAME) / 100, RPAD(SCHEMA_NAME, SCHEMA_LEN) || CHAR(32) || RPAD(TABLE_NAME, TABLE_LEN) || CHAR(32) || RPAD(REMOTE_SOURCE_NAME, REMOTE_SOURCE_LEN) || CHAR(32) ||
    RPAD(REMOTE_OBJECT_NAME, REMOTE_OBJECT_LEN) FROM ACCESSED_VIRTUAL_TABLES
  UNION ALL
  SELECT TOP 1 4890, ''                      FROM ( SELECT 1 FROM ACCESSED_INDEXES UNION ALL SELECT 1 FROM ACCESSED_INDEXES UNION ALL SELECT 1 FROM ACCESSED_INDEX_COLUMNS_2 ) UNION ALL
  SELECT TOP 1 4900, '*********************' FROM ( SELECT 1 FROM ACCESSED_INDEXES UNION ALL SELECT 1 FROM ACCESSED_INDEXES UNION ALL SELECT 1 FROM ACCESSED_INDEX_COLUMNS_2 ) UNION ALL
  SELECT TOP 1 4910, '* INDEX INFORMATION *' FROM ( SELECT 1 FROM ACCESSED_INDEXES UNION ALL SELECT 1 FROM ACCESSED_INDEXES UNION ALL SELECT 1 FROM ACCESSED_INDEX_COLUMNS_2 ) UNION ALL
  SELECT TOP 1 4920, '*********************' FROM ( SELECT 1 FROM ACCESSED_INDEXES UNION ALL SELECT 1 FROM ACCESSED_INDEXES UNION ALL SELECT 1 FROM ACCESSED_INDEX_COLUMNS_2 ) UNION ALL
  SELECT TOP 1 4930, ''                      FROM ( SELECT 1 FROM ACCESSED_INDEXES UNION ALL SELECT 1 FROM ACCESSED_INDEXES UNION ALL SELECT 1 FROM ACCESSED_INDEX_COLUMNS_2 ) UNION ALL
  SELECT TOP 1 4980, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('TABLE_NAME', TABLE_LEN) || CHAR(32) || RPAD('INDEX_NAME', INDEX_LEN) || CHAR(32) ||
    RPAD('TY', 2) || CHAR(32) || LPAD('MEM_TOT_MB', 10) || CHAR(32) || LPAD('MEM_CONC_MB', 11) || CHAR(32) || LPAD('INDIV_COSTS', 11) || CHAR(32) || RPAD('INDIV_COLUMN', INDIV_COL_LEN) FROM ACCESSED_INDEXES UNION ALL
  SELECT TOP 1 4990, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', TABLE_LEN, '=') || CHAR(32) || RPAD('=', INDEX_LEN, '=') || CHAR(32) ||
    RPAD('=', 2, '=') || CHAR(32) || RPAD('=', 10, '=') || CHAR(32) || RPAD('=', 11, '=') || CHAR(32) || RPAD('=', 11, '=') || CHAR(32) || RPAD('=', INDIV_COL_LEN, '=') FROM ACCESSED_INDEXES UNION ALL
  SELECT 5000 + ROW_NUMBER() OVER (ORDER BY SCHEMA_NAME, TABLE_NAME, INDEX_NAME_NO_PART, PART_ID) / 100, RPAD(SCHEMA_NAME, SCHEMA_LEN) || CHAR(32) || RPAD(TABLE_NAME, TABLE_LEN) || CHAR(32) || RPAD(INDEX_NAME, INDEX_LEN) || CHAR(32) ||
    RPAD(TY, 2) || CHAR(32) || LPAD(MEM_TOT_MB, 10) || CHAR(32) || LPAD(MEM_CONC_MB, 11) || CHAR(32) || MAP(INDIV_COSTS, -1, LPAD('', 11), LPAD(INDIV_COSTS, 11)) || CHAR(32) || RPAD(INDIV_COLUMN, INDIV_COL_LEN)
  FROM
    ACCESSED_INDEXES UNION ALL
  SELECT TOP 1 5070, ''                       FROM DUMMY UNION ALL
  SELECT TOP 1 5080, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('TABLE_NAME', TABLE_LEN) || CHAR(32) || RPAD('INDEX_NAME', INDEX_LEN) || CHAR(32) ||
    RPAD('COLUMN_NAME', COLUMN_LEN) || CHAR(32) || RPAD('INDEX_TYPE', INDEX_TYPE_LEN) || CHAR(32) || RPAD('CONSTRAINT_NAME', 19) FROM ACCESSED_INDEX_COLUMNS UNION ALL
  SELECT TOP 1 5090, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', TABLE_LEN, '=') || CHAR(32) || RPAD('=', INDEX_LEN, '=') || CHAR(32) ||
    RPAD('=', COLUMN_LEN, '=') || CHAR(32) || RPAD('=', INDEX_TYPE_LEN, '=') || CHAR(32) || RPAD('=', 19, '=') FROM ACCESSED_INDEX_COLUMNS UNION ALL
  SELECT 5100 + ROW_NUMBER() OVER (ORDER BY SCHEMA_NAME, TABLE_NAME, INDEX_NAME, POSITION) / 100, RPAD(MAP(POSITION, 1, SCHEMA_NAME, ''), SCHEMA_LEN) || CHAR(32) ||
    RPAD(MAP(POSITION, 1, TABLE_NAME, ''), TABLE_LEN) || CHAR(32) || RPAD(MAP(POSITION, 1, INDEX_NAME, ''), INDEX_LEN) || CHAR(32) ||
    RPAD(COLUMN_NAME, COLUMN_LEN) || CHAR(32) || RPAD(MAP(POSITION, 1, INDEX_TYPE, ''), INDEX_TYPE_LEN) || CHAR(32) || RPAD(MAP(POSITION, 1, IFNULL(CONSTRAINT, ''), ''), 20)
  FROM
    ACCESSED_INDEX_COLUMNS UNION ALL
  SELECT TOP 1 5490, '' FROM ACCESSED_INDEX_COLUMNS_2 UNION ALL
  SELECT TOP 1 5580, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('TABLE_NAME', TABLE_LEN) || CHAR(32) || RPAD('INDEX_NAME', 10) || CHAR(32) ||
    RPAD('COLUMN_NAME', COLUMN_LEN) || CHAR(32) || RPAD('INDEX_TYPE', INDEX_TYPE_LEN) FROM ACCESSED_INDEX_COLUMNS_2 UNION ALL
  SELECT TOP 1 5590, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', TABLE_LEN, '=') || CHAR(32) || RPAD('=', 10, '=') || CHAR(32) ||
    RPAD('=', COLUMN_LEN, '=') || CHAR(32) || RPAD('=', INDEX_TYPE_LEN, '=') FROM ACCESSED_INDEX_COLUMNS_2 UNION ALL
  SELECT 5600 + ROW_NUM / 100, RPAD(MAP(ROW_NUM_PER_TAB, 1, SCHEMA_NAME, ''), SCHEMA_LEN) || CHAR(32) ||
    RPAD(MAP(ROW_NUM_PER_TAB, 1, TABLE_NAME, ''), TABLE_LEN) || CHAR(32) || RPAD('implicit', 10) || CHAR(32) ||
    RPAD(COLUMN_NAME, COLUMN_LEN) || CHAR(32) || INDEX_TYPE
  FROM
    ACCESSED_INDEX_COLUMNS_2
  UNION ALL
  SELECT TOP 1 5990, ''                       FROM DUMMY UNION ALL
  SELECT TOP 1 6000, '**********************' FROM DUMMY UNION ALL
  SELECT TOP 1 6010, '* COLUMN INFORMATION *' FROM DUMMY UNION ALL
  SELECT TOP 1 6020, '**********************' FROM DUMMY UNION ALL
  SELECT TOP 1 6030, ''                       FROM DUMMY UNION ALL
  SELECT TOP 1 6080, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('TABLE_NAME', TABLE_LEN) || CHAR(32) || RPAD('COLUMN_NAME', COLUMN_LEN) || CHAR(32) || LPAD('NUM_DISTINCT', 12) ||
    CHAR(32) || LPAD('SIZE_MB', 12) || CHAR(32) || LPAD('LENGTH', 7) || CHAR(32) || RPAD('DATA_TYPE', 14) || CHAR(32) || RPAD('N', 1) || CHAR(32) || RPAD('COMPRESSION', 11) || CHAR(32) || RPAD('INDEX_TYPE', 10) || CHAR(32) ||
    RPAD('LOAD_UNIT', 9) || CHAR(32) || LPAD('SCANNED_RECS_PER_S', 18) || CHAR(32) || LPAD('INDEX_LOOKUPS_PER_H', 19) FROM ACCESSED_COLUMNS UNION ALL
  SELECT TOP 1 6090, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', TABLE_LEN, '=') || CHAR(32) || RPAD('=', COLUMN_LEN, '=') || CHAR(32) || LPAD('=', 12, '=') ||
    CHAR(32) || LPAD('=', 12, '=') || CHAR(32) || LPAD('=', 7, '=') || CHAR(32) || RPAD('=', 14, '=') || CHAR(32) || RPAD('=', 1, '=') || CHAR(32) || RPAD('=', 11, '=') || CHAR(32) || RPAD('=', 10, '=') || CHAR(32) ||
    RPAD('=', 9, '=') || CHAR(32) || LPAD('=', 18, '=') || CHAR(32) || LPAD('=', 19, '=') FROM ACCESSED_COLUMNS UNION ALL
  SELECT 6100 + ROW_NUMBER() OVER (ORDER BY SCHEMA_NAME, TABLE_NAME, COLUMN_NAME) / 100,
    RPAD(MAP(ROW_NUMBER() OVER (PARTITION BY SCHEMA_NAME, TABLE_NAME ORDER BY SCHEMA_NAME, TABLE_NAME, COLUMN_NAME), 1, SCHEMA_NAME, ''), SCHEMA_LEN) || CHAR(32) ||
    RPAD(MAP(ROW_NUMBER() OVER (PARTITION BY SCHEMA_NAME, TABLE_NAME ORDER BY SCHEMA_NAME, TABLE_NAME, COLUMN_NAME), 1, TABLE_NAME, ''), TABLE_LEN) || CHAR(32) ||
    RPAD(COLUMN_NAME, COLUMN_LEN) || CHAR(32) || LPAD(NUM_DISTINCT, 12) || CHAR(32) || LPAD(SIZE_MB, 12) || CHAR(32) || LPAD(LENGTH, 7) || CHAR(32) ||
    RPAD(DATA_TYPE, 14) || CHAR(32) || RPAD(IS_NULLABLE, 1) || CHAR(32) || RPAD(COMPRESSION, 11) || CHAR(32) || RPAD(INDEX_TYPE, 10) || CHAR(32) ||
    RPAD(LOAD_UNIT, 9) || CHAR(32) || LPAD(MAP(SCANNED_RECS_PER_S, -1, 'n/a', TO_VARCHAR(SCANNED_RECS_PER_S)), 18) || CHAR(32) || LPAD(MAP(INDEX_LOOKUPS_PER_H, -1, 'n/a', TO_VARCHAR(INDEX_LOOKUPS_PER_H)), 19)
  FROM
    ACCESSED_COLUMNS
  UNION ALL
  SELECT TOP 1 6290, ''                    FROM ACCESSED_LOBS UNION ALL
  SELECT TOP 1 6300, '*******************' FROM ACCESSED_LOBS UNION ALL
  SELECT TOP 1 6310, '* LOB INFORMATION *' FROM ACCESSED_LOBS UNION ALL
  SELECT TOP 1 6320, '*******************' FROM ACCESSED_LOBS UNION ALL
  SELECT TOP 1 6330, ''                    FROM ACCESSED_LOBS UNION ALL
  SELECT TOP 1 6380, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('TABLE_NAME', 40) || CHAR(32) || RPAD('COLUMN_NAME', 30) || CHAR(32) || RPAD('LOB_TYPE', 8) ||
    CHAR(32) || LPAD('DISK_GB', 10) || CHAR(32) || LPAD('BINARY_GB', 10) || CHAR(32) || LPAD('LOB_COUNT', 10) FROM ACCESSED_LOBS UNION ALL
  SELECT TOP 1 6390, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', 40, '=') || CHAR(32) || RPAD('=', 30, '=') || CHAR(32) || RPAD('=', 8, '=') || CHAR(32) ||
    LPAD('=', 10, '=') || CHAR(32) || LPAD('=', 10, '=') || CHAR(32) || LPAD('=', 10, '=') FROM ACCESSED_LOBS UNION ALL
  SELECT 6400 + ROW_NUMBER() OVER (ORDER BY L.SCHEMA_NAME, L.TABLE_NAME, L.COLUMN_NAME) / 100,
    RPAD(L.SCHEMA_NAME, SCHEMA_LEN) || CHAR(32) || RPAD(L.TABLE_NAME, 40) || CHAR(32) || RPAD(L.COLUMN_NAME, 30) || CHAR(32) || RPAD(L.LOB_TYPE, 8) ||
    CHAR(32) || LPAD(L.DISK_GB, 10) || CHAR(32) || LPAD(L.BINARY_GB, 10) || CHAR(32) || LPAD(L.LOB_COUNT, 10)
  FROM
    ACCESSED_LOBS L UNION ALL
  SELECT TOP 1 6490, ''                          FROM ACCESSED_PARTITIONS UNION ALL
  SELECT TOP 1 6500, '*************************' FROM ACCESSED_PARTITIONS UNION ALL
  SELECT TOP 1 6510, '* PARTITION INFORMATION *' FROM ACCESSED_PARTITIONS UNION ALL
  SELECT TOP 1 6520, '*************************' FROM ACCESSED_PARTITIONS UNION ALL
  SELECT TOP 1 6530, ''                          FROM ACCESSED_PARTITIONS UNION ALL
  SELECT TOP 1 6580, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('TABLE_NAME', TABLE_LEN) || CHAR(32) ||
    RPAD('HOST', HOST_LEN) || CHAR(32) || LPAD('MEM_SIZE_GB', 11) || CHAR(32) ||
    LPAD('RECORDS', 12) || CHAR(32) || RPAD('LOAD_UNIT', 9) || CHAR(32) || RPAD('LEVEL_1_PARTITIONING', L1_LEN) || CHAR(32) || RPAD('LEVEL_2_PARTITIONING', L2_LEN) FROM ACCESSED_PARTITIONS UNION ALL
  SELECT TOP 1 6590, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', TABLE_LEN, '=') || CHAR(32) ||
    RPAD('=', HOST_LEN, '=') || CHAR(32) || LPAD('=', 11, '=') || CHAR(32) ||
    LPAD('=', 12, '=') || CHAR(32) || RPAD('=', 9, '=') || CHAR(32) || RPAD('=', L1_LEN, '=') || CHAR(32) || RPAD('=', L2_LEN, '=') FROM ACCESSED_PARTITIONS UNION ALL
  SELECT 6600 + ROW_NUMBER() OVER (ORDER BY TP.SCHEMA_NAME, TP.TABLE_NAME, TP.PART_ID) / 100,
    RPAD(MAP(TP.PART_ID, 0, TP.SCHEMA_NAME, 1, TP.SCHEMA_NAME, ''), SCHEMA_LEN) || CHAR(32) || RPAD(TP.TABLE_NAME || CHAR(32) || '(' || TP.PART_ID || ')', TP.TABLE_LEN) || CHAR(32) ||
    RPAD(TP.HOST, TP.HOST_LEN) || CHAR(32) || LPAD(TO_DECIMAL(TP.MEM_SIZE_GB, 10, 2), 11) || CHAR(32) ||
    LPAD(TP.RECORDS, 12) || CHAR(32) || RPAD(TP.LOAD_UNIT, 9) || CHAR(32) || RPAD(TP.LEVEL_1_PARTITIONING, L1_LEN) || CHAR(32) || RPAD(TP.LEVEL_2_PARTITIONING, L2_LEN)
  FROM
    ACCESSED_PARTITIONS TP UNION ALL
  SELECT TOP 1 6690, ''                            FROM ACCESSED_REFERENTIAL_CONSTRAINTS UNION ALL
  SELECT TOP 1 6700, '***************************' FROM ACCESSED_REFERENTIAL_CONSTRAINTS UNION ALL
  SELECT TOP 1 6710, '* REFERENTIAL CONSTRAINTS *' FROM ACCESSED_REFERENTIAL_CONSTRAINTS UNION ALL
  SELECT TOP 1 6720, '***************************' FROM ACCESSED_REFERENTIAL_CONSTRAINTS UNION ALL
  SELECT TOP 1 6730, ''                            FROM ACCESSED_REFERENTIAL_CONSTRAINTS UNION ALL
  SELECT TOP 1 6780, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('TABLE_NAME', TABLE_LEN) || CHAR(32) || RPAD('COLUMN_NAME', COLUMN_LEN) || CHAR(32) || LPAD('POS', 3) || CHAR(32) ||
    RPAD('REF_SCHEMA_NAME', 19) || CHAR(32) || RPAD('REF_TABLE_NAME', REF_TABLE_LEN) || CHAR(32) || RPAD('REF_COLUMN_NAME', REF_COLUMN_LEN) FROM ACCESSED_REFERENTIAL_CONSTRAINTS UNION ALL
  SELECT TOP 1 6790, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', TABLE_LEN, '=') || CHAR(32) || LPAD('=', COLUMN_LEN, '=') || CHAR(32) || LPAD('=', 3, '=') || CHAR(32) ||
    RPAD('=', 19, '=') || CHAR(32) || RPAD('=', REF_TABLE_LEN, '=') || CHAR(32) || LPAD('=', REF_COLUMN_LEN, '=') FROM ACCESSED_REFERENTIAL_CONSTRAINTS UNION ALL
  SELECT 6800 + ROW_NUMBER() OVER (ORDER BY AC.SCHEMA_NAME, AC.TABLE_NAME, AC.COLUMN_NAME) / 100, RPAD(AC.SCHEMA_NAME, SCHEMA_LEN) || CHAR(32) || RPAD(AC.TABLE_NAME, TABLE_LEN) || CHAR(32) ||
    RPAD(AC.COLUMN_NAME, COLUMN_LEN) || CHAR(32) || LPAD(AC.POSITION, 3) || CHAR(32) || RPAD(AC.REFERENCED_SCHEMA_NAME, 20) ||
    RPAD(AC.REFERENCED_TABLE_NAME, REF_TABLE_LEN) || CHAR(32) || RPAD(AC.REFERENCED_COLUMN_NAME, REF_COLUMN_LEN)
  FROM
    ACCESSED_REFERENTIAL_CONSTRAINTS AC UNION ALL
  SELECT TOP 1 6890, ''             FROM ACCESSED_TRIGGERS UNION ALL
  SELECT TOP 1 6891, '************' FROM ACCESSED_TRIGGERS UNION ALL
  SELECT TOP 1 6892, '* TRIGGERS *' FROM ACCESSED_TRIGGERS UNION ALL
  SELECT TOP 1 6893, '************' FROM ACCESSED_TRIGGERS UNION ALL
  SELECT TOP 1 6894, ''             FROM ACCESSED_TRIGGERS UNION ALL
  SELECT TOP 1 6895, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('TABLE_NAME', TABLE_LEN) || CHAR(32) ||
    RPAD('TRIGGER_NAME', TRIGGER_LEN) || CHAR(32) || RPAD('ACTION_TIME', 11) || CHAR(32) || RPAD('EVENT', 6) || CHAR(32) ||
    RPAD('ACTION_LEVEL', 12) || CHAR(32) || RPAD('IS_VALID', 8) || CHAR(32) || RPAD('IS_ENABLED', 10) || CHAR(32) || RPAD('CREATE_TIME', 19) FROM ACCESSED_TRIGGERS UNION ALL
  SELECT TOP 1 6896, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', TABLE_LEN, '=') || CHAR(32) ||
    RPAD('=', TRIGGER_LEN, '=') || CHAR(32) || RPAD('=', 11, '=') || CHAR(32) || RPAD('=', 6, '=') || CHAR(32) ||
    RPAD('=', 12, '=') || CHAR(32) || RPAD('=', 8, '=') || CHAR(32) || RPAD('=', 10, '=') || CHAR(32) || RPAD('=', 19, '=') FROM ACCESSED_TRIGGERS UNION ALL
  SELECT 6900 + ROW_NUMBER() OVER (ORDER BY TRIGGER_NAME) / 100, RPAD(SUBJECT_TABLE_SCHEMA, SCHEMA_LEN) || CHAR(32) || RPAD(SUBJECT_TABLE_NAME, TABLE_LEN) || CHAR(32) ||
    RPAD(TRIGGER_NAME, TRIGGER_LEN) || CHAR(32) || RPAD(TRIGGER_ACTION_TIME, 11) || CHAR(32) || RPAD(TRIGGER_EVENT, 6) || CHAR(32) ||
    RPAD(TRIGGERED_ACTION_LEVEL, 12) || CHAR(32) || RPAD(IS_VALID, 8) || CHAR(32) || RPAD(IS_ENABLED, 10) || CHAR(32) || RPAD(CREATE_TIME, 19)
  FROM
    ACCESSED_TRIGGERS UNION ALL
  SELECT TOP 1 6990, ''                   FROM ACCESSED_REPLICAS UNION ALL
  SELECT TOP 1 7000, '******************' FROM ACCESSED_REPLICAS UNION ALL
  SELECT TOP 1 7010, '* TABLE REPLICAS *' FROM ACCESSED_REPLICAS UNION ALL
  SELECT TOP 1 7020, '******************' FROM ACCESSED_REPLICAS UNION ALL
  SELECT TOP 1 7030, ''                   FROM ACCESSED_REPLICAS UNION ALL
  SELECT TOP 1 7080, RPAD('HOST', 29) || CHAR(32) || RPAD('SOURCE_SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('SOURCE_TABLE_NAME', SRC_TABLE_LEN) || CHAR(32) || LPAD('PART_ID', 7) ||
    CHAR(32) || RPAD('REPLICA_TYPE', 13) || CHAR(32) || 'REPLICA_NAME' FROM ACCESSED_REPLICAS UNION ALL
  SELECT TOP 1 7090, RPAD('=', 29, '=') || CHAR(32) || RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', SRC_TABLE_LEN, '=') || CHAR(32) || LPAD('=', 7, '=') ||
    CHAR(32) || RPAD('=', 13, '=') || CHAR(32) || RPAD('=', 50, '=') FROM ACCESSED_REPLICAS UNION ALL
  SELECT 7100 + ROW_NUMBER() OVER (ORDER BY R.SOURCE_SCHEMA_NAME, R.SOURCE_TABLE_NAME, R.PART_ID, R.HOST) / 1000, RPAD(R.HOST, 30) || RPAD(R.SOURCE_SCHEMA_NAME, SCHEMA_LEN) || CHAR(32) ||
    RPAD(R.SOURCE_TABLE_NAME, SRC_TABLE_LEN) || CHAR(32) || LPAD(R.PART_ID, 7) || CHAR(32) || RPAD(R.REPLICA_TYPE, 13) || CHAR(32) || R.TABLE_NAME
  FROM
    ACCESSED_REPLICAS R UNION ALL
  SELECT TOP 1 7190, ''                       FROM ACCESSED_TRANSLATION_TABLES UNION ALL
  SELECT TOP 1 7200, '**********************' FROM ACCESSED_TRANSLATION_TABLES UNION ALL
  SELECT TOP 1 7210, '* TRANSLATION TABLES *' FROM ACCESSED_TRANSLATION_TABLES UNION ALL
  SELECT TOP 1 7220, '**********************' FROM ACCESSED_TRANSLATION_TABLES UNION ALL
  SELECT TOP 1 7230, ''                       FROM ACCESSED_TRANSLATION_TABLES UNION ALL
  SELECT TOP 1 7280, RPAD('SCHEMA_NAME_1', SCHEMA_NAME_1_LEN) || CHAR(32) || RPAD('TABLE_NAME_1', TABLE_NAME_1_LEN) || CHAR(32) || RPAD('COLUMN_NAME_1', COLUMN_NAME_1_LEN) || CHAR(32) ||
    RPAD('SCHEMA_NAME_2', SCHEMA_NAME_2_LEN) || CHAR(32) || RPAD('TABLE_NAME_2', TABLE_NAME_2_LEN) || CHAR(32) || RPAD('COLUMN_NAME_2', COLUMN_NAME_2_LEN) || CHAR(32) ||
    LPAD('NUM_TTS', 7) || CHAR(32) || LPAD('SIZE_MB', 9) FROM ACCESSED_TRANSLATION_TABLES UNION ALL
  SELECT TOP 1 7290, RPAD('=', SCHEMA_NAME_1_LEN, '=') || CHAR(32) || RPAD('=', TABLE_NAME_1_LEN, '=') || CHAR(32) || RPAD('=', COLUMN_NAME_1_LEN, '=') || CHAR(32) ||
    RPAD('=', SCHEMA_NAME_2_LEN, '=') || CHAR(32) || RPAD('=', TABLE_NAME_2_LEN, '=') || CHAR(32) || RPAD('=', COLUMN_NAME_2_LEN, '=') || CHAR(32) ||
    LPAD('=', 7, '=') || CHAR(32) || LPAD('=', 9, '=') FROM ACCESSED_TRANSLATION_TABLES UNION ALL
  SELECT 7300 + ROW_NUMBER() OVER (ORDER BY NUM_TTS DESC, SIZE_MB DESC) / 100, RPAD(SCHEMA_NAME_1, SCHEMA_NAME_1_LEN) || CHAR(32) || RPAD(TABLE_NAME_1, TABLE_NAME_1_LEN) || CHAR(32) || RPAD(COLUMN_NAME_1, COLUMN_NAME_1_LEN) || CHAR(32) ||
    RPAD(SCHEMA_NAME_2, SCHEMA_NAME_2_LEN) || CHAR(32) || RPAD(TABLE_NAME_2, TABLE_NAME_2_LEN) || CHAR(32) || RPAD(COLUMN_NAME_2, COLUMN_NAME_2_LEN) || CHAR(32) ||
    LPAD(NUM_TTS, 7) || CHAR(32) || LPAD(SIZE_MB, 9) FROM ACCESSED_TRANSLATION_TABLES UNION ALL
  SELECT TOP 1 7490, ''                        FROM TABLE_OPTIMIZATIONS UNION ALL
  SELECT TOP 1 7500, '***********************' FROM TABLE_OPTIMIZATIONS UNION ALL
  SELECT TOP 1 7510, '* TABLE OPTIMIZATIONS *' FROM TABLE_OPTIMIZATIONS UNION ALL
  SELECT TOP 1 7520, '***********************' FROM TABLE_OPTIMIZATIONS UNION ALL
  SELECT TOP 1 7530, ''                        FROM TABLE_OPTIMIZATIONS UNION ALL
  SELECT TOP 1 7580, RPAD('OPTIMIZATION_TIME', 20) || RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('TABLE_NAME', TABLE_LEN) || CHAR(32) ||
    RPAD('HOST', HOST_LEN) || CHAR(32) || RPAD('TYPE', 14) || CHAR(32) || RPAD('MOTIVATION', 10) || LPAD('MERGED_ROWS', 12) ||
    LPAD('RUNTIME_S', 10) || CHAR(32) || LPAD('RW_S', 5) || CHAR(32) || LPAD('P1_HLW_S', 8) || CHAR(32) || LPAD('P1_BLW_S', 8) || CHAR(32) ||
    LPAD('P1_L_S', 6) || CHAR(32) || LPAD('P2_HLW_S', 8) || CHAR(32) || LPAD('P2_BLW_S', 8) || CHAR(32) ||
    LPAD('P2_L_S', 6) || CHAR(32) || 'LAST_ERROR' FROM ( SELECT HOST_LEN FROM BASIS_INFO ), TABLE_OPTIMIZATIONS UNION ALL
  SELECT TOP 1 7590, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', 19, '=') || CHAR(32) || RPAD('=', TABLE_LEN, '=') ||
    CHAR(32) || RPAD('=', HOST_LEN, '=') || CHAR(32) || RPAD('=', 14, '=') || CHAR(32) || RPAD('=', 10, '=') || CHAR(32) || LPAD('=', 11, '=') ||
    CHAR(32) || LPAD('=', 9, '=') || CHAR(32) || LPAD('=', 5, '=') || CHAR(32) || LPAD('=', 8, '=') || CHAR(32) || LPAD('=', 8, '=') || CHAR(32) ||
    LPAD('=', 6, '=') || CHAR(32) || LPAD('=', 8, '=') || CHAR(32) || LPAD('=', 8, '=') || CHAR(32) ||
    LPAD('=', 6, '=') || CHAR(32) || RPAD('=', 70, '=') FROM ( SELECT HOST_LEN FROM BASIS_INFO ), TABLE_OPTIMIZATIONS UNION ALL
  SELECT 7600 + ROW_NUMBER() OVER (ORDER BY START_TIME DESC, SCHEMA_NAME, TABLE_NAME) / 1000, RPAD(TO_VARCHAR(START_TIME, 'YYYY/MM/DD HH24:MI:SS'), 20) ||
    RPAD(SCHEMA_NAME, SCHEMA_LEN) || CHAR(32) || RPAD(TABLE_NAME, TABLE_LEN) || CHAR(32) ||
    RPAD(HOST, HOST_LEN) || CHAR(32) || RPAD(TYPE, 14) || CHAR(32) || RPAD(MOTIVATION, 10) || LPAD(MERGED_ROWS, 12) ||
    LPAD(RUNTIME_S, 10) || CHAR(32) || LPAD(RW_S, 5) || CHAR(32) || LPAD(P1_HLW_S, 8) || CHAR(32) || LPAD(P1_BLW_S, 8) || CHAR(32) ||
    LPAD(P1_L_S, 6) || CHAR(32) || LPAD(P2_HLW_S, 8) || CHAR(32) || LPAD(P2_BLW_S, 8) || CHAR(32) ||
    LPAD(P2_L_S, 6) || CHAR(32) || LAST_ERROR
  FROM
    ( SELECT HOST_LEN FROM BASIS_INFO ),
    TABLE_OPTIMIZATIONS
  WHERE
  ( MAX_RESULT_LINES = -1 OR LINE_NO <= MAX_RESULT_LINES ) UNION ALL
  SELECT TOP 1 7690, ''                      FROM UNLOADS_AND_LOADS UNION ALL
  SELECT TOP 1 7700, '*********************' FROM UNLOADS_AND_LOADS UNION ALL
  SELECT TOP 1 7710, '* UNLOADS AND LOADS *' FROM UNLOADS_AND_LOADS UNION ALL
  SELECT TOP 1 7720, '*********************' FROM UNLOADS_AND_LOADS UNION ALL
  SELECT TOP 1 7730, ''                      FROM UNLOADS_AND_LOADS UNION ALL
  SELECT TOP 1 7780, RPAD('ACTION_TIME', 20) || RPAD('TYPE', 7) || RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('TABLE_NAME', TABLE_LEN) || CHAR(32) ||
    RPAD('COLUMN_NAME', COLUMN_LEN) || CHAR(32) || RPAD('HOST', HOST_LEN) || CHAR(32) ||
    LPAD('DURATION_MS', 11) || CHAR(32) || RPAD('REASON_OR_HASH', 33) || 'ERROR' FROM ( SELECT HOST_LEN FROM BASIS_INFO ), UNLOADS_AND_LOADS UNION ALL
  SELECT TOP 1 7790, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', 6, '=') || CHAR(32) || RPAD('=', 19, '=') || CHAR(32) || RPAD('=', TABLE_LEN, '=') ||
    CHAR(32) || RPAD('=', COLUMN_LEN, '=') || CHAR(32) || RPAD('=', HOST_LEN, '=') || CHAR(32) || LPAD('=', 11, '=') || CHAR(32) || RPAD('=', 32, '=') ||
    CHAR(32) || RPAD('=', 60, '=') FROM ( SELECT HOST_LEN FROM BASIS_INFO ), UNLOADS_AND_LOADS UNION ALL
  SELECT 7800 + ROW_NUMBER() OVER (ORDER BY ACTION_TIME DESC, SCHEMA_NAME, TABLE_NAME) / 1000, RPAD(TO_VARCHAR(ACTION_TIME, 'YYYY/MM/DD HH24:MI:SS'), 20) || RPAD(TYPE, 7) ||
    RPAD(SCHEMA_NAME, SCHEMA_LEN) || CHAR(32) || RPAD(TABLE_NAME, TABLE_LEN) || CHAR(32) || RPAD(COLUMN_NAME, COLUMN_LEN) || CHAR(32) || RPAD(HOST, HOST_LEN) || CHAR(32) || LPAD(MAP(DURATION_MS, -1, 'n/a',
    TO_VARCHAR(DURATION_MS)), 11) || CHAR(32) || RPAD(REASON_OR_HASH, 33) || ERROR
  FROM
    ( SELECT HOST_LEN FROM BASIS_INFO ),
     UNLOADS_AND_LOADS
  WHERE
  ( MAX_RESULT_LINES = -1 OR LINE_NO <= MAX_RESULT_LINES ) UNION ALL
  SELECT TOP 1 7990, ''                               FROM EXPENSIVE_STATEMENTS UNION ALL
  SELECT TOP 1 8000, '******************************' FROM EXPENSIVE_STATEMENTS UNION ALL
  SELECT TOP 1 8010, '* EXPENSIVE STATEMENTS TRACE *' FROM EXPENSIVE_STATEMENTS UNION ALL
  SELECT TOP 1 8020, '******************************' FROM EXPENSIVE_STATEMENTS UNION ALL
  SELECT TOP 1 8030, ''                               FROM EXPENSIVE_STATEMENTS UNION ALL
  SELECT TOP 1 8080, RPAD('START_TIME', 19) || CHAR(32) || RPAD('OPERATION', OPERATION_LEN) || CHAR(32) || LPAD('DURATION_S', 11) || CHAR(32) || LPAD('CPU_S', 10) || CHAR(32) || LPAD('RECORDS', 9) ||
    CHAR(32) || LPAD('MEM_MB', 8) ||  CHAR(32) || RPAD('WORKLOAD_CLASS', WLC_LEN) || CHAR(32) || RPAD('APP_USER', APP_USER_LEN) || CHAR(32) || RPAD('APP_SOURCE', APP_SOURCE_LEN) || CHAR(32) || 'ERROR' FROM EXPENSIVE_STATEMENTS UNION ALL
  SELECT TOP 1 8090, RPAD('=', 19, '=') || CHAR(32) || RPAD('=', OPERATION_LEN, '=') || CHAR(32) || LPAD('=', 11, '=') || CHAR(32) || LPAD('=', 10, '=') || CHAR(32) || LPAD('=', 9, '=') || CHAR(32) ||
    LPAD('=', 8, '=') || CHAR(32) || RPAD('=', WLC_LEN, '=') || CHAR(32) || RPAD('=', APP_USER_LEN, '=') || CHAR(32) || RPAD('=', APP_SOURCE_LEN, '=') || CHAR(32) || LPAD('=', 50, '=') FROM EXPENSIVE_STATEMENTS UNION ALL
  SELECT 8100 + ROW_NUMBER() OVER (ORDER BY START_TIME DESC, OPERATION) / 100, RPAD(TO_VARCHAR(START_TIME, 'YYYY/MM/DD HH24:MI:SS'), 20) || RPAD(OPERATION, OPERATION_LEN) || CHAR(32) ||
    LPAD(TO_VARCHAR(TO_DECIMAL(DURATION_MICROSEC / 1000000, 10, 2)), 11) || LPAD(TO_VARCHAR(TO_DECIMAL(CPU_TIME / 1000000, 10, 2)), 11) || LPAD(RECORDS, 10) ||
    LPAD(TO_DECIMAL(ROUND(MEMORY_SIZE / 1024 / 1024), 10, 0), 9) || CHAR(32) || RPAD(WORKLOAD_CLASS, WLC_LEN) || CHAR(32) || RPAD(APP_USER, APP_USER_LEN) || CHAR(32) || RPAD(APPLICATION_SOURCE, APP_SOURCE_LEN) || CHAR(32) ||
    ERROR_CODE || MAP(ERROR_TEXT, '', '', ':' || CHAR(32) || ERROR_TEXT)
  FROM
    EXPENSIVE_STATEMENTS
  UNION ALL
  SELECT TOP 1 8570, '' FROM EXPENSIVE_STATEMENTS UNION ALL
  SELECT TOP 1 8580, RPAD('START_TIME', 19) || CHAR(32) || LPAD('DURATION_S', 11) || CHAR(32) || RPAD('BIND_VALUES', 100) FROM EXPENSIVE_STATEMENTS UNION ALL
  SELECT TOP 1 8590, RPAD('=', 19, '=') || CHAR(32) || LPAD('=', 11, '=') || CHAR(32) || RPAD('=', 100, '=') FROM EXPENSIVE_STATEMENTS UNION ALL
  SELECT 8600 + ROW_NUMBER() OVER (ORDER BY START_TIME DESC) / 100, RPAD(TO_VARCHAR(START_TIME, 'YYYY/MM/DD HH24:MI:SS'), 19) || CHAR(32) || LPAD(TO_VARCHAR(TO_DECIMAL(DURATION_MICROSEC / 1000000, 10, 2)), 11) || CHAR(32) || RPAD(PARAMETERS, 180)
  FROM
  ( SELECT
      ROW_NUMBER() OVER (ORDER BY ES.START_TIME DESC) LINE_NO,
      ES.START_TIME,
      ES.DURATION_MICROSEC,
      ES.PARAMETERS,
      BI.MAX_RESULT_LINES
    FROM
      BASIS_INFO BI,
      EXPENSIVE_STATEMENTS ES
    WHERE
      ES.STATEMENT_HASH = BI.STATEMENT_HASH AND
      ES.PARAMETERS != ''
  )
  UNION ALL
  SELECT TOP 1 8690, ''                              FROM EXECUTED_STATEMENTS UNION ALL
  SELECT TOP 1 8700, '*****************************' FROM EXECUTED_STATEMENTS UNION ALL
  SELECT TOP 1 8710, '* EXECUTED STATEMENTS TRACE *' FROM EXECUTED_STATEMENTS UNION ALL
  SELECT TOP 1 8720, '*****************************' FROM EXECUTED_STATEMENTS UNION ALL
  SELECT TOP 1 8730, ''                              FROM EXECUTED_STATEMENTS UNION ALL
  SELECT TOP 1 8780, RPAD('START_TIME', 19) || CHAR(32) || LPAD('DURATION_S', 11) ||  CHAR(32) || LPAD('ERROR', 5) || CHAR(32) || RPAD('APP_USER', APP_USER_LEN) || CHAR(32) ||
    RPAD('APP_SOURCE', APP_SOURCE_LEN) FROM EXECUTED_STATEMENTS UNION ALL
  SELECT TOP 1 8790, RPAD('=', 19, '=') || CHAR(32) || LPAD('=', 11, '=') || CHAR(32) || LPAD('=', 5, '=') || CHAR(32) || RPAD('=', APP_USER_LEN, '=') || CHAR(32) ||
    RPAD('=', APP_SOURCE_LEN, '=') FROM EXECUTED_STATEMENTS UNION ALL
  SELECT 8800 + ROW_NUMBER() OVER (ORDER BY START_TIME DESC) / 100, RPAD(TO_VARCHAR(START_TIME, 'YYYY/MM/DD HH24:MI:SS'), 20) ||
    LPAD(TO_VARCHAR(TO_DECIMAL(DURATION_MICROSEC / 1000000, 10, 2)), 11) || LPAD(ERROR_CODE, 6) || CHAR(32) || RPAD(APP_USER, APP_USER_LEN) || CHAR(32) || RPAD(APPLICATION_SOURCE, APP_SOURCE_LEN)
  FROM
    EXECUTED_STATEMENTS
  UNION ALL
  SELECT TOP 1 8990, ''                        FROM TRANSACTIONAL_LOCKS UNION ALL
  SELECT TOP 1 9000, '***********************' FROM TRANSACTIONAL_LOCKS UNION ALL
  SELECT TOP 1 9010, '* TRANSACTIONAL LOCKS *' FROM TRANSACTIONAL_LOCKS UNION ALL
  SELECT TOP 1 9020, '***********************' FROM TRANSACTIONAL_LOCKS UNION ALL
  SELECT TOP 1 9030, ''                        FROM TRANSACTIONAL_LOCKS UNION ALL
  SELECT TOP 1 9100, RPAD('LOCK_TIME', 19) || CHAR(32) || RPAD('BLOCKED_STATEMENT_HASH', 32) || CHAR(32) || RPAD('BLOCKING_STATEMENT_HASH', 32) || CHAR(32) || LPAD('WAIT_S', 8) || CHAR(32) ||
    RPAD('LOCK_TYPE', TYPE_LEN) || CHAR(32) || RPAD('LOCK_MODE', MODE_LEN) || CHAR(32) || RPAD('OBJECT_NAME', 40) FROM TRANSACTIONAL_LOCKS UNION ALL
  SELECT TOP 1 9110, RPAD('=', 19, '=') || CHAR(32) || RPAD('=', 32, '=') || CHAR(32) || RPAD('=', 32, '=') || CHAR(32) || LPAD('=', 8, '=') || CHAR(32) ||
    RPAD('=', TYPE_LEN, '=') || CHAR(32) || RPAD('=', MODE_LEN, '=') || CHAR(32) || RPAD('=', 40, '=') FROM TRANSACTIONAL_LOCKS UNION ALL
  SELECT 9120 + ROW_NUMBER() OVER (ORDER BY SERVER_TIMESTAMP DESC), RPAD(SERVER_TIMESTAMP, 19) || CHAR(32) || RPAD(BLOCKED_STATEMENT_HASH, 32) || CHAR(32) ||
    RPAD(LOCK_OWNER_STATEMENT_HASH, 32) || CHAR(32) || LPAD(WAIT_S, 8) || CHAR(32) ||
    RPAD(LOCK_TYPE, TYPE_LEN) || CHAR(32) || RPAD(LOCK_MODE, MODE_LEN) || CHAR(32) || OBJECT_NAME
  FROM
    TRANSACTIONAL_LOCKS
  WHERE
    MAX_RESULT_LINES = -1 OR ROW_NUM <= MAX_RESULT_LINES UNION ALL
  SELECT TOP 1  9990, ''                   FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 10000, '******************' FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 10010, '* THREAD SAMPLES *' FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 10020, '******************' FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 10030, ''                   FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 10080, LPAD('SAMPLES', 7) || CHAR(32) || LPAD('PERCENT', 7) || CHAR(32) || RPAD('HOST', HOST_LEN) || CHAR(32) || RPAD('PORT', 5) || CHAR(32) || 'THREAD_TYPE' FROM ( SELECT HOST_LEN FROM BASIS_INFO ), THREAD_SAMPLES UNION ALL
  SELECT TOP 1 10090, LPAD('=', 7, '=') || CHAR(32) || LPAD('=', 7, '=') || CHAR(32) || RPAD('=', HOST_LEN, '=') || CHAR(32) || RPAD('=', 5, '=') || CHAR(32) || RPAD('=', 30, '=') FROM ( SELECT HOST_LEN FROM BASIS_INFO ), THREAD_SAMPLES UNION ALL
  SELECT 10100 + ROW_NUM / 100, LPAD(SAMPLES, 7) || CHAR(32) || LPAD(PERCENT, 7) || CHAR(32) || RPAD(HOST, HOST_LEN) || CHAR(32) || RPAD(PORT, 5) || CHAR(32) || THREAD_TYPE
  FROM
  ( SELECT HOST_LEN FROM BASIS_INFO ),
  ( SELECT
      SAMPLES,
      TO_DECIMAL(SAMPLES / TOTAL_SAMPLES * 100, 10, 2) PERCENT,
      HOST,
      PORT,
      THREAD_TYPE,
      MAX_RESULT_LINES,
      ROW_NUMBER () OVER (ORDER BY SAMPLES DESC, HOST, PORT, THREAD_TYPE) ROW_NUM
    FROM
    ( SELECT
        SUM(TS.SAMPLES) SAMPLES,
        TS.TOTAL_SAMPLES,
        TS.HOST,
        TS.PORT,
        TS.THREAD_TYPE,
        BI.MAX_RESULT_LINES
      FROM
        BASIS_INFO BI,
        THREAD_SAMPLES TS
      GROUP BY
        TS.TOTAL_SAMPLES,
        TS.HOST,
        TS.PORT,
        TS.THREAD_TYPE,
        BI.MAX_RESULT_LINES
    )
  )
  WHERE
  ( MAX_RESULT_LINES = -1 OR ROW_NUM <= MAX_RESULT_LINES ) UNION ALL
  SELECT TOP 1 10470, ''                   FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 10480, LPAD('SAMPLES', 7) || CHAR(32) || LPAD('PERCENT', 7) || CHAR(32) || RPAD('THREAD_TYPE', TYPE_LEN) || CHAR(32) ||
    RPAD('THREAD_STATE', STATE_LEN) || CHAR(32) || RPAD('Q', 1) || CHAR(32) || RPAD('LOCK_NAME', 70) FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 10490, LPAD('=', 7, '=') || CHAR(32) || LPAD('=', 7, '=') || CHAR(32) || RPAD('=', TYPE_LEN, '=') || CHAR(32) ||
    RPAD('=', STATE_LEN, '=') || CHAR(32) || RPAD('=', 1, '=') || CHAR(32) || RPAD('=', 70, '=') FROM THREAD_SAMPLES UNION ALL
  SELECT 10500 + ROW_NUM / 100, LPAD(SAMPLES, 7) || CHAR(32) || LPAD(PERCENT, 7) || CHAR(32) || RPAD(THREAD_TYPE, TYPE_LEN) || CHAR(32) ||
    RPAD(THREAD_STATE, STATE_LEN) || CHAR(32) || RPAD(Q, 1) || CHAR(32) || LOCK_NAME
  FROM
  ( SELECT
      SAMPLES,
      TO_DECIMAL(SAMPLES / TOTAL_SAMPLES * 100, 10, 2) PERCENT,
      THREAD_STATE,
      THREAD_TYPE,
      LOCK_NAME,
      Q,
      MAX_RESULT_LINES,
      GREATEST(12, MAX(LENGTH(THREAD_STATE)) OVER ()) STATE_LEN,
      MAX(LENGTH(THREAD_TYPE)) OVER () TYPE_LEN,
      ROW_NUMBER () OVER (ORDER BY SAMPLES DESC, THREAD_STATE, LOCK_NAME) ROW_NUM
    FROM
    ( SELECT
        SUM(TS.SAMPLES) SAMPLES,
        TS.TOTAL_SAMPLES,
        TS.THREAD_STATE,
        TS.THREAD_TYPE,
        TS.LOCK_NAME,
        TS.Q,
        BI.MAX_RESULT_LINES
      FROM
        BASIS_INFO BI,
        THREAD_SAMPLES TS
      GROUP BY
        TS.TOTAL_SAMPLES,
        TS.THREAD_STATE,
        TS.THREAD_TYPE,
        TS.LOCK_NAME,
        TS.Q,
        BI.MAX_RESULT_LINES
    )
  )
  WHERE
  ( MAX_RESULT_LINES = -1 OR ROW_NUM <= MAX_RESULT_LINES ) UNION ALL
  SELECT TOP 1 10730, ''                   FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 10780, LPAD('SAMPLES', 7) || CHAR(32) || LPAD('PERCENT', 7) || CHAR(32) || RPAD('THREAD_TYPE', TYPE_LEN) || CHAR(32) || RPAD('THREAD_METHOD', 50) FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 10790, LPAD('=', 7, '=') || CHAR(32) || LPAD('=', 7, '=') || CHAR(32) || RPAD('=', TYPE_LEN, '=') || CHAR(32) || RPAD('=', 50, '=') FROM THREAD_SAMPLES UNION ALL
  SELECT 10800 + ROW_NUM / 100, LPAD(SAMPLES, 7) || CHAR(32) || LPAD(PERCENT, 7) || CHAR(32) || RPAD(THREAD_TYPE, TYPE_LEN) || CHAR(32) || THREAD_METHOD
  FROM
  ( SELECT
      SAMPLES,
      TO_DECIMAL(SAMPLES / TOTAL_SAMPLES * 100, 10, 2) PERCENT,
      THREAD_TYPE,
      THREAD_METHOD,
      TYPE_LEN,
      MAX_RESULT_LINES,
      ROW_NUMBER () OVER (ORDER BY SAMPLES DESC, THREAD_TYPE, THREAD_METHOD) ROW_NUM
    FROM
    ( SELECT
        SUM(TS.SAMPLES) SAMPLES,
        TS.TOTAL_SAMPLES,
        TS.THREAD_TYPE,
        TS.THREAD_METHOD,
        TS.TYPE_LEN,
        BI.MAX_RESULT_LINES
      FROM
        BASIS_INFO BI,
        THREAD_SAMPLES TS
      GROUP BY
        TS.TOTAL_SAMPLES,
        TS.THREAD_TYPE,
        TS.THREAD_METHOD,
        TS.TYPE_LEN,
        BI.MAX_RESULT_LINES
    )
  )
  WHERE
  ( MAX_RESULT_LINES = -1 OR ROW_NUM <= MAX_RESULT_LINES ) UNION ALL
  SELECT TOP 1 11030, ''                   FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 11080, LPAD('SAMPLES', 7) || CHAR(32) || LPAD('PERCENT', 7) || CHAR(32) || RPAD('THREAD_TYPE', TYPE_LEN) || CHAR(32) || RPAD('THREAD_METHOD', METHOD_LEN) || CHAR(32) ||
    RPAD('THREAD_DETAIL', 80) FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 11090, LPAD('=', 7, '=') || CHAR(32) || LPAD('=', 7, '=') || CHAR(32) || RPAD('=', TYPE_LEN, '=') || CHAR(32) || RPAD('=', METHOD_LEN, '=') || CHAR(32) ||
    RPAD('=', 80, '=') FROM THREAD_SAMPLES UNION ALL
  SELECT 11100 + ROW_NUM / 100, LPAD(SAMPLES, 7) || CHAR(32) || LPAD(PERCENT, 7) || CHAR(32) || RPAD(THREAD_TYPE, TYPE_LEN) || CHAR(32) || RPAD(THREAD_METHOD, METHOD_LEN) || CHAR(32) || THREAD_DETAIL
  FROM
  ( SELECT
      SAMPLES,
      TO_DECIMAL(SAMPLES / TOTAL_SAMPLES * 100, 10, 2) PERCENT,
      THREAD_TYPE,
      THREAD_METHOD,
      THREAD_DETAIL,
      MAX_RESULT_LINES,
      TYPE_LEN,
      METHOD_LEN,
      ROW_NUMBER () OVER (ORDER BY SAMPLES DESC, THREAD_TYPE, THREAD_METHOD, THREAD_DETAIL) ROW_NUM
    FROM
    ( SELECT
        SUM(TS.SAMPLES) SAMPLES,
        TS.TOTAL_SAMPLES,
        TS.THREAD_TYPE,
        TS.THREAD_METHOD,
        TS.THREAD_DETAIL,
        TS.TYPE_LEN,
        TS.METHOD_LEN,
        BI.MAX_RESULT_LINES
      FROM
        BASIS_INFO BI,
        THREAD_SAMPLES TS
      GROUP BY
        TS.TOTAL_SAMPLES,
        TS.THREAD_TYPE,
        TS.THREAD_METHOD,
        TS.THREAD_DETAIL,
        TS.TYPE_LEN,
        TS.METHOD_LEN,
        BI.MAX_RESULT_LINES
    )
  )
  WHERE
  ( MAX_RESULT_LINES = -1 OR ROW_NUM <= MAX_RESULT_LINES ) UNION ALL
  SELECT TOP 1 12030, ''                   FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 12080, LPAD('SAMPLES', 7) || CHAR(32) || LPAD('PERCENT', 7) || CHAR(32) || RPAD('DB_USER', DB_USER_LEN) || CHAR(32) || RPAD('APP_USER', APP_USER_LEN) || CHAR(32) ||
    RPAD('APP_NAME', APP_NAME_LEN) || CHAR(32) || RPAD('APP_SOURCE', 50) FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 12090, LPAD('=', 7, '=') || CHAR(32) || LPAD('=', 7, '=') || CHAR(32) || RPAD('=', DB_USER_LEN, '=') || CHAR(32) || RPAD('=', APP_USER_LEN, '=') || CHAR(32) ||
    RPAD('=', APP_NAME_LEN, '=') || CHAR(32) || RPAD('=', 50, '=') FROM THREAD_SAMPLES UNION ALL
  SELECT 12100 + ROW_NUM / 100, LPAD(SAMPLES, 7) || CHAR(32) || LPAD(PERCENT, 7) || CHAR(32) || RPAD(DB_USER, DB_USER_LEN) || CHAR(32) || RPAD(APP_USER, APP_USER_LEN) || CHAR(32) ||
    RPAD(APP_NAME, APP_NAME_LEN) || CHAR(32) || APP_SOURCE
  FROM
  ( SELECT
      SAMPLES,
      TO_DECIMAL(SAMPLES / TOTAL_SAMPLES * 100, 10, 2) PERCENT,
      DB_USER,
      APP_USER,
      APP_NAME,
      APP_SOURCE,
      MAX_RESULT_LINES,
      DB_USER_LEN,
      APP_USER_LEN,
      APP_NAME_LEN,
      APP_SOURCE_LEN,
      ROW_NUMBER () OVER (ORDER BY SAMPLES DESC, DB_USER, APP_USER, APP_NAME, APP_SOURCE) ROW_NUM
    FROM
    ( SELECT
        SUM(TS.SAMPLES) SAMPLES,
        TS.TOTAL_SAMPLES,
        TS.DB_USER,
        TS.APP_USER,
        TS.APP_NAME,
        TS.APP_SOURCE,
        TS.DB_USER_LEN,
        TS.APP_USER_LEN,
        TS.APP_NAME_LEN,
        TS.APP_SOURCE_LEN,
        BI.MAX_RESULT_LINES
      FROM
        BASIS_INFO BI,
        THREAD_SAMPLES TS
      GROUP BY
        TS.TOTAL_SAMPLES,
        TS.DB_USER,
        TS.APP_USER,
        TS.APP_NAME,
        TS.APP_SOURCE,
        TS.DB_USER_LEN,
        TS.APP_USER_LEN,
        TS.APP_NAME_LEN,
        TS.APP_SOURCE_LEN,
        BI.MAX_RESULT_LINES
    )
  )
  WHERE
  ( MAX_RESULT_LINES = -1 OR ROW_NUM <= MAX_RESULT_LINES ) UNION ALL
  SELECT TOP 1 12130, ''                   FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 12180, LPAD('SAMPLES', 7) || CHAR(32) || LPAD('PERCENT', 7) || CHAR(32) || RPAD('PASSPORT_COMPONENT', PASSPORT_COMPONENT_LEN) || CHAR(32) ||
    RPAD('PASSPORT_ACTION', PASSPORT_ACTION_LEN) FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 12190, LPAD('=', 7, '=') || CHAR(32) || LPAD('=', 7, '=') || CHAR(32) || RPAD('=', PASSPORT_COMPONENT_LEN, '=') || CHAR(32) ||
    RPAD('=', PASSPORT_ACTION_LEN, '=') FROM THREAD_SAMPLES UNION ALL
  SELECT 12200 + ROW_NUM / 100, LPAD(SAMPLES, 7) || CHAR(32) || LPAD(PERCENT, 7) || CHAR(32) || RPAD(PASSPORT_COMPONENT, PASSPORT_COMPONENT_LEN) || CHAR(32) ||
    RPAD(PASSPORT_ACTION, PASSPORT_ACTION_LEN)
  FROM
  ( SELECT
      SAMPLES,
      TO_DECIMAL(SAMPLES / TOTAL_SAMPLES * 100, 10, 2) PERCENT,
      PASSPORT_ACTION,
      PASSPORT_COMPONENT,
      MAX_RESULT_LINES,
      PASSPORT_ACTION_LEN,
      PASSPORT_COMPONENT_LEN,
      ROW_NUMBER () OVER (ORDER BY SAMPLES DESC, PASSPORT_COMPONENT, PASSPORT_ACTION) ROW_NUM
    FROM
    ( SELECT
        SUM(TS.SAMPLES) SAMPLES,
        TS.TOTAL_SAMPLES,
        TS.PASSPORT_ACTION,
        TS.PASSPORT_COMPONENT,
        TS.DB_USER_LEN,
        TS.PASSPORT_ACTION_LEN,
        TS.PASSPORT_COMPONENT_LEN,
        BI.MAX_RESULT_LINES
      FROM
        BASIS_INFO BI,
        THREAD_SAMPLES TS
      GROUP BY
        TS.TOTAL_SAMPLES,
        TS.PASSPORT_ACTION,
        TS.PASSPORT_COMPONENT,
        TS.DB_USER_LEN,
        TS.PASSPORT_ACTION_LEN,
        TS.PASSPORT_COMPONENT_LEN,
        BI.MAX_RESULT_LINES
    )
  )
  WHERE
  ( MAX_RESULT_LINES = -1 OR ROW_NUM <= MAX_RESULT_LINES ) UNION ALL
  SELECT TOP 1 12230, ''                   FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 12280, LPAD('SAMPLES', 7) || CHAR(32) || LPAD('PERCENT', 7) || CHAR(32) ||
    RPAD('PASSPORT_ACTION', PASSPORT_ACTION_LEN) || CHAR(32) || RPAD('APP_COMP_NAME', APP_COMP_NAME_LEN) FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 12290, LPAD('=', 7, '=') || CHAR(32) || LPAD('=', 7, '=') || CHAR(32) ||
    RPAD('=', PASSPORT_ACTION_LEN, '=') || CHAR(32) || RPAD('=', APP_COMP_NAME_LEN, '=') FROM THREAD_SAMPLES UNION ALL
  SELECT 12300 + ROW_NUM / 100, LPAD(SAMPLES, 7) || CHAR(32) || LPAD(PERCENT, 7) || CHAR(32) ||
    RPAD(PASSPORT_ACTION, PASSPORT_ACTION_LEN) || CHAR(32) || RPAD(APP_COMP_NAME, APP_COMP_NAME_LEN)
  FROM
  ( SELECT
      SAMPLES,
      TO_DECIMAL(SAMPLES / TOTAL_SAMPLES * 100, 10, 2) PERCENT,
      PASSPORT_ACTION,
      APP_COMP_NAME,
      MAX_RESULT_LINES,
      PASSPORT_ACTION_LEN,
      APP_COMP_NAME_LEN,
      ROW_NUMBER () OVER (ORDER BY SAMPLES DESC, PASSPORT_ACTION, APP_COMP_NAME) ROW_NUM
    FROM
    ( SELECT
        SUM(TS.SAMPLES) SAMPLES,
        TS.TOTAL_SAMPLES,
        TS.PASSPORT_ACTION,
        TS.APP_COMP_NAME,
        TS.DB_USER_LEN,
        TS.PASSPORT_ACTION_LEN,
        TS.APP_COMP_NAME_LEN,
        BI.MAX_RESULT_LINES
      FROM
        BASIS_INFO BI,
        THREAD_SAMPLES TS
      GROUP BY
        TS.TOTAL_SAMPLES,
        TS.PASSPORT_ACTION,
        TS.APP_COMP_NAME,
        TS.DB_USER_LEN,
        TS.PASSPORT_ACTION_LEN,
        TS.APP_COMP_NAME_LEN,
        BI.MAX_RESULT_LINES
    )
  )
  WHERE
  ( MAX_RESULT_LINES = -1 OR ROW_NUM <= MAX_RESULT_LINES ) UNION ALL
  SELECT TOP 1 12330, ''                   FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 12380, LPAD('SAMPLES', 7) || CHAR(32) || LPAD('PERCENT', 7) || CHAR(32) || RPAD('CLIENT_IP', 15) || CHAR(32) || LPAD('CLIENT_PID', 10) FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 12390, LPAD('=', 7, '=') || CHAR(32) || LPAD('=', 7, '=') || CHAR(32) || RPAD('=', 15, '=') || CHAR(32) || RPAD('=', 10, '=') FROM THREAD_SAMPLES UNION ALL
  SELECT 12400 + ROW_NUM / 100, LPAD(SAMPLES, 7) || CHAR(32) || LPAD(PERCENT, 7) || CHAR(32) || RPAD(CLIENT_IP, 15) || CHAR(32) || LPAD(CLIENT_PID, 10)
  FROM
  ( SELECT
      SAMPLES,
      TO_DECIMAL(SAMPLES / TOTAL_SAMPLES * 100, 10, 2) PERCENT,
      CLIENT_IP,
      CLIENT_PID,
      ROW_NUMBER () OVER (ORDER BY SAMPLES DESC, CLIENT_IP, CLIENT_PID) ROW_NUM,
      MAX_RESULT_LINES
    FROM
    ( SELECT
        SUM(TS.SAMPLES) SAMPLES,
        TS.TOTAL_SAMPLES,
        TS.CLIENT_IP,
        TS.CLIENT_PID,
        BI.MAX_RESULT_LINES
      FROM
        BASIS_INFO BI,
        THREAD_SAMPLES TS
      GROUP BY
        TS.TOTAL_SAMPLES,
        TS.CLIENT_IP,
        TS.CLIENT_PID,
        BI.MAX_RESULT_LINES
    ) T
  )
  WHERE
  ( MAX_RESULT_LINES = -1 OR ROW_NUM <= MAX_RESULT_LINES ) UNION ALL
  SELECT TOP 1 12530, ''                   FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 12580, LPAD('SAMPLES', 7) || CHAR(32) || LPAD('PERCENT', 7) || CHAR(32) || RPAD('ROOT_STATEMENT_HASH', 32) || CHAR(32) || 'STATEMENT_STRING' FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 12590, LPAD('=', 7, '=') || CHAR(32) || LPAD('=', 7, '=') || CHAR(32) || RPAD('=', 32, '=') || CHAR(32) || RPAD('=', 50, '=') FROM THREAD_SAMPLES UNION ALL
  SELECT 12600 + ROW_NUM / 100, LPAD(SAMPLES, 7) || CHAR(32) || LPAD(PERCENT, 7) || CHAR(32) || RPAD(ROOT_STATEMENT_HASH, 32) || CHAR(32) || IFNULL(STATEMENT_STRING, '')
  FROM
  ( SELECT
      SAMPLES,
      TO_DECIMAL(SAMPLES / TOTAL_SAMPLES * 100, 10, 2) PERCENT,
      ROOT_STATEMENT_HASH,
      ( SELECT MAX(SUBSTR(STATEMENT_STRING, 1, 1000)) FROM _SYS_STATISTICS.HOST_SQL_PLAN_CACHE SP WHERE SP.STATEMENT_HASH = T.ROOT_STATEMENT_HASH ) STATEMENT_STRING,
      ROW_NUMBER () OVER (ORDER BY SAMPLES DESC, ROOT_STATEMENT_HASH) ROW_NUM,
      MAX_RESULT_LINES
    FROM
    ( SELECT
        SUM(TS.SAMPLES) SAMPLES,
        TS.TOTAL_SAMPLES,
        TS.ROOT_STATEMENT_HASH,
        BI.MAX_RESULT_LINES
      FROM
        BASIS_INFO BI,
        THREAD_SAMPLES TS
      GROUP BY
        TS.TOTAL_SAMPLES,
        TS.ROOT_STATEMENT_HASH,
        BI.MAX_RESULT_LINES
    ) T
  )
  WHERE
  ( MAX_RESULT_LINES = -1 OR ROW_NUM <= MAX_RESULT_LINES ) UNION ALL
  SELECT TOP 1 12730, ''                   FROM THREAD_SAMPLES_ROOT_HASH UNION ALL
  SELECT TOP 1 12780, LPAD('SAMPLES', 7) || CHAR(32) || LPAD('PERCENT', 7) || CHAR(32) || RPAD('CHILD_STATEMENT_HASH', 32) || CHAR(32) || 'STATEMENT_STRING' FROM THREAD_SAMPLES_ROOT_HASH UNION ALL
  SELECT TOP 1 12790, LPAD('=', 7, '=') || CHAR(32) || LPAD('=', 7, '=') || CHAR(32) || RPAD('=', 32, '=') || CHAR(32) || RPAD('=', 50, '=') FROM THREAD_SAMPLES_ROOT_HASH UNION ALL
  SELECT 12800 + ROW_NUM / 100, LPAD(SAMPLES, 7) || CHAR(32) || LPAD(PERCENT, 7) || CHAR(32) || RPAD(CHILD_STATEMENT_HASH, 32) || CHAR(32) || IFNULL(STATEMENT_STRING, '')
  FROM
  ( SELECT
      SAMPLES,
      TO_DECIMAL(SAMPLES / TOTAL_SAMPLES * 100, 10, 2) PERCENT,
      CHILD_STATEMENT_HASH,
      ( SELECT MAX(SUBSTR(STATEMENT_STRING, 1, 1000)) FROM _SYS_STATISTICS.HOST_SQL_PLAN_CACHE SP WHERE SP.STATEMENT_HASH = T.CHILD_STATEMENT_HASH ) STATEMENT_STRING,
      ROW_NUMBER () OVER (ORDER BY SAMPLES DESC, CHILD_STATEMENT_HASH) ROW_NUM,
      MAX_RESULT_LINES
    FROM
    ( SELECT
        SUM(TS.SAMPLES) SAMPLES,
        TS.TOTAL_SAMPLES,
        TS.CHILD_STATEMENT_HASH,
        BI.MAX_RESULT_LINES
      FROM
        BASIS_INFO BI,
        THREAD_SAMPLES_ROOT_HASH TS
      GROUP BY
        TS.TOTAL_SAMPLES,
        TS.CHILD_STATEMENT_HASH,
        BI.MAX_RESULT_LINES
    ) T
  )
  WHERE
  ( MAX_RESULT_LINES = -1 OR ROW_NUM <= MAX_RESULT_LINES ) UNION ALL
  SELECT TOP 1 13030, ''                   FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 13080, LPAD('AVG_PARALLELISM', 15) || CHAR(32) || LPAD('MAX_PARALLELISM', 15) || CHAR(32) || LPAD('MAX_TOTAL_THREADS', 30) || CHAR(32) || LPAD('MAX_TOTAL_RUNNING_THREADS', 30) FROM THREAD_SAMPLES UNION ALL
  SELECT TOP 1 13090, LPAD('=', 15, '=') || CHAR(32) || LPAD('=', 15, '=') || CHAR(32) || LPAD('=', 30, '=') || CHAR(32) || LPAD('=', 30, '=') FROM THREAD_SAMPLES UNION ALL
  SELECT 13100, LPAD(TO_DECIMAL(AVG_PARALLELISM, 10, 2), 15) || CHAR(32) || LPAD(MAX_PARALLELISM, 15) || CHAR(32) || LPAD(MAX_THREADS, 30) || CHAR(32) || LPAD(MAX_RUNNING_THREADS, 30) FROM
  ( SELECT
      IFNULL(AVG(NUM), 0) AVG_PARALLELISM,
      IFNULL(MAX(NUM), 0) MAX_PARALLELISM
    FROM
    ( SELECT
        SUM(SAMPLES) NUM
      FROM
        THREAD_SAMPLES
      WHERE
        THREAD_TYPE = 'JobWorker'
      GROUP BY
        TIMESTAMP,
        CONNECTION_ID
    )
  ),
  ( SELECT
      IFNULL(MAX(NUM), 0) MAX_THREADS,
      IFNULL(MAX(NUM_RUNNING), 0) MAX_RUNNING_THREADS
    FROM
    ( SELECT
        SUM(SAMPLES) NUM,
        SUM(MAP(THREAD_STATE, 'Running', SAMPLES, 0)) NUM_RUNNING
      FROM
        THREAD_SAMPLES
      GROUP BY
        TIMESTAMP
    )
  )
  WHERE
    MAX_THREADS > 0
  UNION ALL
  SELECT TOP 1 14990, ''                      FROM ACTIVE_STATEMENTS UNION ALL
  SELECT TOP 1 15000, '*********************' FROM ACTIVE_STATEMENTS UNION ALL
  SELECT TOP 1 15010, '* ACTIVE STATEMENTS *' FROM ACTIVE_STATEMENTS UNION ALL
  SELECT TOP 1 15020, '*********************' FROM ACTIVE_STATEMENTS UNION ALL
  SELECT TOP 1 15030, ''                      FROM ACTIVE_STATEMENTS UNION ALL
  SELECT TOP 1 15080, RPAD('START_TIME', 19) || CHAR(32) || LPAD('EXEC_TIME_MS', 15) || CHAR(32) || LPAD('LAST_ACT_MS', 15) || CHAR(32) || LPAD('CONN_ID', 12) || CHAR(32) || RPAD('STATUS', 19) || CHAR(32) || LPAD('MEM_GB', 10) FROM ACTIVE_STATEMENTS UNION ALL
  SELECT TOP 1 15090, RPAD('=', 19, '=') || CHAR(32) || RPAD('=', 15, '=') || CHAR(32) || RPAD('=', 15, '=') || CHAR(32) || LPAD('=', 12, '=') || CHAR(32) || RPAD('=', 19, '=') || CHAR(32) || LPAD('=', 10, '=') FROM ACTIVE_STATEMENTS UNION ALL
  SELECT 15100 + ROW_NUMBER () OVER (ORDER BY A.LAST_EXECUTED_TIME), RPAD(TO_VARCHAR(A.LAST_EXECUTED_TIME, 'YYYY/MM/DD HH24:MI:SS'), 19) || CHAR(32) ||
    LPAD(TO_DECIMAL(GREATEST(NANO100_BETWEEN(A.LAST_EXECUTED_TIME, CURRENT_TIMESTAMP) / 10000, 0), 10, 2), 15) || CHAR(32) ||
    LPAD(TO_DECIMAL(GREATEST(NANO100_BETWEEN(A.LAST_ACTION_TIME, CURRENT_TIMESTAMP) / 10000, 0), 10, 2), 15) || CHAR(32) ||
    LPAD(A.CONNECTION_ID, 12) || CHAR(32) ||
    RPAD(A.STATEMENT_STATUS, 19) || CHAR(32) || LPAD(TO_DECIMAL(A.ALLOCATED_MEMORY_SIZE / 1024 / 1024 / 1024, 10, 2), 10)
  FROM
    ACTIVE_STATEMENTS A
  UNION ALL
  SELECT TOP 1 15490, ''                      FROM ACTIVE_PROCEDURES UNION ALL
  SELECT TOP 1 15500, '*********************' FROM ACTIVE_PROCEDURES UNION ALL
  SELECT TOP 1 15510, '* ACTIVE PROCEDURES *' FROM ACTIVE_PROCEDURES UNION ALL
  SELECT TOP 1 15520, '*********************' FROM ACTIVE_PROCEDURES UNION ALL
  SELECT TOP 1 15530, ''                      FROM ACTIVE_PROCEDURES UNION ALL
  SELECT TOP 1 15580, RPAD('START_TIME', 19) || CHAR(32) || LPAD('EXEC_TIME_MS', 15) || CHAR(32) || LPAD('COMPILE_TIME_MS', 15) || CHAR(32) ||
    LPAD('CONN_ID', 12) || CHAR(32) || RPAD('STATUS', 19) || CHAR(32) || LPAD('EXECS', 5) || CHAR(32) || LPAD('DEPTH', 5) || CHAR(32) || RPAD('PROCEDURE_NAME', PROCEDURE_LEN) FROM ACTIVE_PROCEDURES UNION ALL
  SELECT TOP 1 15590, RPAD('=', 19, '=') || CHAR(32) || RPAD('=', 15, '=') || CHAR(32) || RPAD('=', 15, '=') || CHAR(32) ||
    LPAD('=', 12, '=') || CHAR(32) || RPAD('=', 19, '=') || CHAR(32) || LPAD('=', 5, '=') || CHAR(32) || LPAD('=', 5, '=') || CHAR(32) || RPAD('=', PROCEDURE_LEN, '=') FROM ACTIVE_PROCEDURES UNION ALL
  SELECT 15600 + ROW_NUMBER () OVER (ORDER BY P.STATEMENT_START_TIME), RPAD(TO_VARCHAR(P.STATEMENT_START_TIME, 'YYYY/MM/DD HH24:MI:SS'), 19) || CHAR(32) ||
    LPAD(TO_DECIMAL(P.STATEMENT_EXECUTION_TIME / 1000000, 10, 2), 15) || CHAR(32) ||
    LPAD(TO_DECIMAL(P.STATEMENT_COMPILE_TIME / 1000000, 10, 2), 15) || CHAR(32) ||
    LPAD(P.STATEMENT_CONNECTION_ID, 12) || CHAR(32) ||
    RPAD(P.STATEMENT_STATUS, 19) || CHAR(32) ||
    LPAD(P.STATEMENT_EXECUTION_COUNT, 5) || CHAR(32) ||
    LPAD(P.STATEMENT_DEPTH, 5) || CHAR(32) ||
    RPAD(P.PROCEDURE_NAME, PROCEDURE_LEN)
  FROM
    ACTIVE_PROCEDURES P
  UNION ALL
  SELECT TOP 1 15990, ''                FROM CALLSTACKS UNION ALL
  SELECT TOP 1 16000, '***************' FROM CALLSTACKS UNION ALL
  SELECT TOP 1 16010, '* CALL STACKS *' FROM CALLSTACKS UNION ALL
  SELECT TOP 1 16020, '***************' FROM CALLSTACKS UNION ALL
  SELECT TOP 1 16030, ''                FROM CALLSTACKS UNION ALL
  SELECT TOP 1 16080, LPAD('THREAD_ID', 10) || CHAR(32) || RPAD('THREAD_TYPE', 29) || CHAR(32) || RPAD('THREAD_STATE', 35) || CHAR(32) || RPAD('LOCK_NAME', 29) || CHAR(32) || RPAD('CALL_STACK', 100) FROM CALLSTACKS UNION ALL
  SELECT TOP 1 16090, LPAD('=', 10, '=') || CHAR(32) || RPAD('=', 29, '=') || CHAR(32) || RPAD('=', 35, '=') || CHAR(32) || RPAD('=', 29, '=') || CHAR(32) || RPAD('=', 100, '=') FROM CALLSTACKS UNION ALL
  SELECT 16100 + ROW_NUMBER () OVER (ORDER BY TC.THREAD_ID, TC.FRAME_LEVEL) / 100, LPAD(MAP(TC.FRAME_LEVEL, 1, TO_VARCHAR(TC.THREAD_ID), ''), 10) || CHAR(32) ||
    RPAD(MAP(TC.FRAME_LEVEL, 1, TC.THREAD_TYPE, ''), 29) || CHAR(32) || RPAD(MAP(TC.FRAME_LEVEL, 1, TC.THREAD_STATE, ''), 35) || CHAR(32) ||
    RPAD(MAP(TC.FRAME_LEVEL, 1, TC.LOCK_WAIT_NAME, ''), 29) || CHAR(32) || MAP(INSTR(TC.FRAME_NAME, '('), 0, TC.FRAME_NAME, SUBSTR_BEFORE(TC.FRAME_NAME, '('))
  FROM
    CALLSTACKS TC
  UNION ALL
  SELECT TOP 1 19990, ''               FROM OOM_EVENTS UNION ALL
  SELECT TOP 1 20000, '**************' FROM OOM_EVENTS UNION ALL
  SELECT TOP 1 20010, '* OOM EVENTS *' FROM OOM_EVENTS UNION ALL
  SELECT TOP 1 20020, '**************' FROM OOM_EVENTS UNION ALL
  SELECT TOP 1 20030, ''               FROM OOM_EVENTS UNION ALL
  SELECT TOP 1 20080, RPAD('OOM_TIME', 19) || CHAR(32) || RPAD('HEAP_AREA', 50) || CHAR(32) || RPAD('REASON', 41) || CHAR(32) || LPAD('MEM_USED_GB', 12) FROM OOM_EVENTS UNION ALL
  SELECT TOP 1 20090, RPAD('=', 19, '=') || CHAR(32) || RPAD('=', 50, '=') || CHAR(32) || RPAD('=', 41, '=') || CHAR(32) || LPAD('=', 12, '=') FROM OOM_EVENTS UNION ALL
  SELECT 20100 + ROW_NUM, RPAD(TO_VARCHAR(TIME, 'YYYY/MM/DD HH24:MI:SS'), 19) || CHAR(32) || RPAD(HEAP_ALLOCATOR, 50) || CHAR(32) || RPAD(EVENT_REASON, 41) || CHAR(32) || LPAD(MEM_USED_GB, 12) FROM
    OOM_EVENTS
  WHERE
  ( MAX_RESULT_LINES = -1 OR ROW_NUM <= MAX_RESULT_LINES )
  UNION ALL
  SELECT TOP 1 20490, ''                             FROM ADMISSION_CONTROL_EVENTS UNION ALL
  SELECT TOP 1 20500, '****************************' FROM ADMISSION_CONTROL_EVENTS UNION ALL
  SELECT TOP 1 20510, '* ADMISSION CONTROL EVENTS *' FROM ADMISSION_CONTROL_EVENTS UNION ALL
  SELECT TOP 1 20520, '****************************' FROM ADMISSION_CONTROL_EVENTS UNION ALL
  SELECT TOP 1 20530, ''                             FROM ADMISSION_CONTROL_EVENTS UNION ALL
  SELECT TOP 1 20580, RPAD('EVENT_TIME', 19) || CHAR(32) || RPAD('HOST', HOST_LEN) || CHAR(32) || 'WAIT_TIME_S CPU_PCT MEM_PCT EVENT_REASON' FROM ( SELECT HOST_LEN FROM BASIS_INFO ), ADMISSION_CONTROL_EVENTS UNION ALL
  SELECT TOP 1 20590, RPAD('=', 19, '=') || CHAR(32) || RPAD('=', HOST_LEN, '=') || CHAR(32) ||   '=========== ======= ======= ==================================================' FROM ( SELECT HOST_LEN FROM BASIS_INFO ), ADMISSION_CONTROL_EVENTS UNION ALL
  SELECT 20600 + ROW_NUM, RPAD(TO_VARCHAR(EVENT_TIME, 'YYYY/MM/DD HH24:MI:SS'), 20) || RPAD(HOST, HOST_LEN) || CHAR(32) || LPAD(TO_DECIMAL(QUEUE_WAIT_TIME / 1000000, 10, 2), 11) ||
    LPAD(CPU_USAGE_RATIO, 8) || LPAD(MEMORY_RATIO, 8) || CHAR(32) || EVENT_REASON FROM
    ( SELECT HOST_LEN FROM BASIS_INFO ),
    ADMISSION_CONTROL_EVENTS
  WHERE
  ( MAX_RESULT_LINES = -1 OR ROW_NUM <= MAX_RESULT_LINES )
  UNION ALL
  SELECT TOP 1 20990, ''                     FROM PINNED_PLANS UNION ALL
  SELECT TOP 1 21000, '********************' FROM PINNED_PLANS UNION ALL
  SELECT TOP 1 21010, '* PINNED SQL PLANS *' FROM PINNED_PLANS UNION ALL
  SELECT TOP 1 21020, '********************' FROM PINNED_PLANS UNION ALL
  SELECT TOP 1 21030, ''                     FROM PINNED_PLANS UNION ALL
  SELECT TOP 1 21080, RPAD('PIN_TIME', 19) || CHAR(32) || RPAD('MODIFY_TIME', 19) || CHAR(32) || RPAD('HINT_STRING', 50) FROM PINNED_PLANS UNION ALL
  SELECT TOP 1 21090, RPAD('=', 19 , '=') || CHAR(32) || RPAD('=', 19, '=') || CHAR(32) || RPAD('=', 50, '=') FROM PINNED_PLANS UNION ALL
  SELECT 21100 + ROW_NUMBER() OVER (ORDER BY PIN_TIME DESC), RPAD(TO_VARCHAR(PIN_TIME, 'YYYY/MM/DD HH24:MI:SS'), 20) || RPAD(TO_VARCHAR(LAST_MODIFY_TIME, 'YYYY/MM/DD HH24:MI:SS'), 20) || HINT_STRING FROM
    PINNED_PLANS
  UNION ALL
  SELECT TOP 1 21990, ''                    FROM STMT_HINTS UNION ALL
  SELECT TOP 1 22000, '*******************' FROM STMT_HINTS UNION ALL
  SELECT TOP 1 22010, '* STATEMENT HINTS *' FROM STMT_HINTS UNION ALL
  SELECT TOP 1 22020, '*******************' FROM STMT_HINTS UNION ALL
  SELECT TOP 1 22030, ''                    FROM STMT_HINTS UNION ALL
  SELECT TOP 1 22080, RPAD('ENABLE_TIME', 19) || CHAR(32) || RPAD('ENABLED', 9) || CHAR(32) ||
    RPAD('HINT_STRING', HINT_STRING_LEN) || CHAR(32) || RPAD('COMMENTS', 9) FROM STMT_HINTS UNION ALL
  SELECT TOP 1 22090, RPAD('=', 19 , '=') || CHAR(32) || RPAD('=', 9, '=') || CHAR(32) ||
    RPAD('=', HINT_STRING_LEN, '=') || CHAR(32) || RPAD('=', 30, '=') FROM STMT_HINTS UNION ALL
  SELECT 22100 + ROW_NUMBER() OVER (ORDER BY LAST_ENABLE_TIME DESC), RPAD(TO_VARCHAR(LAST_ENABLE_TIME, 'YYYY/MM/DD HH24:MI:SS'), 20) || RPAD(IS_ENABLED, 9) || CHAR(32) ||
    RPAD(HINT_STRING, HINT_STRING_LEN) || CHAR(32) || COMMENTS FROM
    STMT_HINTS
  UNION ALL
  SELECT TOP 1 22490, ''                                      FROM DATA_STATS UNION ALL
  SELECT TOP 1 22500, '*************************************' FROM DATA_STATS UNION ALL
  SELECT TOP 1 22510, '* USER-DEFINED OPTIMIZER STATISTICS *' FROM DATA_STATS UNION ALL
  SELECT TOP 1 22520, '*************************************' FROM DATA_STATS UNION ALL
  SELECT TOP 1 22530, ''                                      FROM DATA_STATS UNION ALL
  SELECT TOP 1 22580, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('OBJECT_NAME', OBJECT_LEN) || CHAR(32) || RPAD('COLUMN_NAMES', COLUMN_LEN) || CHAR(32) ||
    RPAD('TYPE', TYPE_LEN) || CHAR(32) || LPAD('COUNT', 12) || CHAR(32) || LPAD('NUM_DISTINCT', 12) || CHAR(32) || LPAD('NUM_NULLS', 10) || CHAR(32) ||
    RPAD('MIN_VALUE', MIN_VALUE_LEN) || CHAR(32) || RPAD('MAX_VALUE', MAX_VALUE_LEN) FROM DATA_STATS UNION ALL
  SELECT TOP 1 22590, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', OBJECT_LEN, '=') || CHAR(32) || RPAD('=', COLUMN_LEN, '=') || CHAR(32) ||
    RPAD('=', TYPE_LEN, '=') || CHAR(32) || LPAD('=', 12, '=') || CHAR(32) || LPAD('=', 12, '=') || CHAR(32) || LPAD('=', 10, '=') || CHAR(32) ||
    RPAD('=', MIN_VALUE_LEN, '=') || CHAR(32) || RPAD('=', MAX_VALUE_LEN, '=') FROM DATA_STATS UNION ALL
  SELECT 22600 + ROW_NUMBER() OVER (ORDER BY DATA_SOURCE_SCHEMA_NAME, OBJECT_NAME, DATA_SOURCE_COLUMN_NAMES),
    RPAD(DATA_SOURCE_SCHEMA_NAME, SCHEMA_LEN) || CHAR(32) || RPAD(OBJECT_NAME, OBJECT_LEN) || CHAR(32) || RPAD(DATA_SOURCE_COLUMN_NAMES, COLUMN_LEN) || CHAR(32) ||
    RPAD(DATA_STATISTICS_TYPE, TYPE_LEN) || CHAR(32) || LPAD(COUNT, 12) || CHAR(32) || LPAD(DISTINCT_COUNT, 12) || CHAR(32) || LPAD(NULL_COUNT, 10) || CHAR(32) ||
    RPAD(IFNULL(MINVALUE_STRING, ''), MIN_VALUE_LEN) || CHAR(32) || RPAD(IFNULL(MAXVALUE_STRING, ''), MAX_VALUE_LEN) FROM DATA_STATS
  WHERE
  ( MAX_RESULT_LINES = -1 OR LINE_NO <= MAX_RESULT_LINES )
  UNION ALL
  SELECT TOP 1 22790, ''                FROM ANNOTS UNION ALL
  SELECT TOP 1 22800, '***************' FROM ANNOTS UNION ALL
  SELECT TOP 1 22810, '* ANNOTATIONS *' FROM ANNOTS UNION ALL
  SELECT TOP 1 22820, '***************' FROM ANNOTS UNION ALL
  SELECT TOP 1 22830, ''                FROM ANNOTS UNION ALL
  SELECT TOP 1 22880, RPAD('SCHEMA_NAME', SCHEMA_LEN) || CHAR(32) || RPAD('OBJECT_NAME', OBJECT_LEN) || CHAR(32) || RPAD('OBJECT_TYPE', 20) || CHAR(32) || RPAD('KEY', 20) || CHAR(32) || 'VALUE' FROM ANNOTS UNION ALL
  SELECT TOP 1 22890, RPAD('=', SCHEMA_LEN, '=') || CHAR(32) || RPAD('=', OBJECT_LEN, '=') || CHAR(32) || RPAD('=', 20, '=') || CHAR(32) || RPAD('=', 20, '=') || CHAR(32) || RPAD('=', 20, '=') FROM ANNOTS UNION ALL
  SELECT 22900 + ROW_NUMBER() OVER (ORDER BY SCHEMA_NAME, OBJECT_NAME) / 100, RPAD(SCHEMA_NAME, SCHEMA_LEN) || CHAR(32) || RPAD(OBJECT_NAME, OBJECT_LEN) || CHAR(32) || RPAD(OBJECT_TYPE, 20) || CHAR(32) ||
    RPAD(KEY, 20) || CHAR(32) || VALUE FROM
    ANNOTS
  UNION ALL
  SELECT TOP 1 22990, ''                  FROM TRACE_ENTRIES UNION ALL
  SELECT TOP 1 23000, '*****************' FROM TRACE_ENTRIES UNION ALL
  SELECT TOP 1 23010, '* TRACE ENTRIES *' FROM TRACE_ENTRIES UNION ALL
  SELECT TOP 1 23020, '*****************' FROM TRACE_ENTRIES UNION ALL
  SELECT TOP 1 23030, ''                  FROM TRACE_ENTRIES UNION ALL
  SELECT TOP 1 23080, RPAD('TIMESTAMP', 19) || CHAR(32) || RPAD('COMPONENT', 16) || CHAR(32) || RPAD('TRACE_ENTRIES', 50) FROM TRACE_ENTRIES UNION ALL
  SELECT TOP 1 23090, RPAD('=', 19, '=') || CHAR(32) || RPAD('=', 16, '=') || CHAR(32) || RPAD('=', 50, '=') FROM TRACE_ENTRIES UNION ALL
  SELECT 23100 + ROW_NUMBER() OVER (ORDER BY TIMESTAMP DESC), RPAD(TO_VARCHAR(TIMESTAMP, 'YYYY/MM/DD HH24:MI:SS'), 19) || CHAR(32) || RPAD(COMPONENT, 16) || CHAR(32) || TRACE_TEXT
  FROM
    TRACE_ENTRIES
  WHERE
  ( MAX_RESULT_LINES = -1 OR LINE_NO <= MAX_RESULT_LINES )
  UNION ALL
  SELECT TOP 1 23990, ''                  FROM FEATURE_USAGE UNION ALL
  SELECT TOP 1 24000, '*****************' FROM FEATURE_USAGE UNION ALL
  SELECT TOP 1 24010, '* USED FEATURES *' FROM FEATURE_USAGE UNION ALL
  SELECT TOP 1 24020, '*****************' FROM FEATURE_USAGE UNION ALL
  SELECT TOP 1 24030, ''                  FROM FEATURE_USAGE UNION ALL
  SELECT TOP 1 24080, RPAD('COMPONENT_NAME', COMPONENT_LEN) || CHAR(32) || RPAD('FEATURE_NAME', FEATURE_LEN) || CHAR(32) || RPAD('DEPRECATED', 10) || CHAR(32) || RPAD('LAST_EXECUTION_TIME', 19) FROM FEATURE_USAGE UNION ALL
  SELECT TOP 1 24090, RPAD('=', COMPONENT_LEN, '=') || CHAR(32) || RPAD('=', FEATURE_LEN, '=') || CHAR(32) || RPAD('=', 10, '=') || CHAR(32) || RPAD('=', 19, '=') FROM FEATURE_USAGE UNION ALL
  SELECT TOP 1 24100 + ROW_NUMBER () OVER (ORDER BY COMPONENT_NAME, FEATURE_NAME), RPAD(COMPONENT_NAME, COMPONENT_LEN) || CHAR(32) || RPAD(FEATURE_NAME, FEATURE_LEN) || CHAR(32) || RPAD(IS_DEPRECATED, 10) || CHAR(32) || RPAD(LAST_TIMESTAMP, 19) FROM FEATURE_USAGE
  UNION ALL
  SELECT TOP 1 91990, ''                       FROM M_DATABASE_HISTORY UNION ALL
  SELECT TOP 1 92000, '****************************' FROM M_DATABASE_HISTORY UNION ALL
  SELECT TOP 1 92010, '* DATABASE VERSION HISTORY *' FROM M_DATABASE_HISTORY UNION ALL
  SELECT TOP 1 92020, '****************************' FROM M_DATABASE_HISTORY UNION ALL
  SELECT TOP 1 92030, ''                       FROM M_DATABASE_HISTORY UNION ALL
  SELECT TOP 1 92080, RPAD('INSTALL_TIME', 19) || CHAR(32) || RPAD('VERSION', 22) FROM M_DATABASE_HISTORY UNION ALL
  SELECT TOP 1 92090, RPAD('=', 19, '=') || CHAR(32) || RPAD('=', 22, '=') FROM M_DATABASE_HISTORY UNION ALL
  SELECT 92100 + ROW_NUMBER () OVER (ORDER BY INSTALL_TIME DESC), RPAD(TO_VARCHAR(INSTALL_TIME, 'YYYY/MM/DD HH24:MI:SS'), 19) || CHAR(32) || VERSION FROM M_DATABASE_HISTORY
  UNION ALL
  SELECT TOP 1 93990, ''                       FROM PARAMETERS UNION ALL
  SELECT TOP 1 94000, '**********************' FROM PARAMETERS UNION ALL
  SELECT TOP 1 94010, '* PARAMETER SETTINGS *' FROM PARAMETERS UNION ALL
  SELECT TOP 1 94020, '**********************' FROM PARAMETERS UNION ALL
  SELECT TOP 1 94030, ''                       FROM PARAMETERS UNION ALL
  SELECT TOP 1 94080, RPAD('FILE_NAME', FILE_LEN) || CHAR(32) || RPAD('SECTION', SECTION_LEN) || CHAR(32) || RPAD('PARAMETER_NAME' , KEY_LEN) || CHAR(32) || RPAD('LAYER_NAME', 10) || CHAR(32) || 'VALUE' FROM PARAMETERS UNION ALL
  SELECT TOP 1 94090, RPAD('=', FILE_LEN, '=') || CHAR(32) || RPAD('=', SECTION_LEN, '=') || CHAR(32) || RPAD('=' , KEY_LEN, '=') || CHAR(32) || RPAD('=', 10, '=') || CHAR(32) || RPAD('=', GREATEST(5, VALUE_LEN), '=') FROM PARAMETERS UNION ALL
  SELECT 94100 + ROW_NUMBER () OVER (ORDER BY FILE_NAME, SECTION, KEY), RPAD(FILE_NAME, FILE_LEN) || CHAR(32) || RPAD(SECTION, SECTION_LEN) || CHAR(32) || RPAD(KEY, KEY_LEN) || CHAR(32) || RPAD(LAYER_NAME, 10) || CHAR(32) || VALUE FROM
    PARAMETERS
  UNION ALL
  SELECT TOP 1 94990, ''                      FROM PARAMETER_CHANGES UNION ALL
  SELECT TOP 1 95000, '*********************' FROM PARAMETER_CHANGES UNION ALL
  SELECT TOP 1 95010, '* PARAMETER CHANGES *' FROM PARAMETER_CHANGES UNION ALL
  SELECT TOP 1 95020, '*********************' FROM PARAMETER_CHANGES UNION ALL
  SELECT TOP 1 95030, ''                      FROM PARAMETER_CHANGES UNION ALL
  SELECT TOP 1 95080, RPAD('TIMESTAMP', 19) || CHAR(32) || RPAD('FILE_NAME', FILE_LEN) || CHAR(32) || RPAD('SECTION', SECTION_LEN) || CHAR(32) || RPAD('PARAMETER_NAME', KEY_LEN) || CHAR(32) ||
    RPAD('VALUE', VALUE_LEN) || CHAR(32) || 'PREV_VALUE' FROM PARAMETER_CHANGES UNION ALL
  SELECT TOP 1 95090, RPAD('=', 19, '=') || CHAR(32) || RPAD('=', FILE_LEN, '=') || CHAR(32) || RPAD('=', SECTION_LEN, '=') || CHAR(32) || RPAD('=', KEY_LEN, '=') || CHAR(32) ||
    RPAD('=', VALUE_LEN, '=') || CHAR(32) || RPAD('=', GREATEST(10, PREV_VALUE_LEN), '=') FROM PARAMETER_CHANGES UNION ALL
  SELECT
    95100 + ROW_NUMBER () OVER (ORDER BY TIME DESC, FILE_NAME, SECTION, KEY),
    RPAD(TO_VARCHAR(TIME, 'YYYY/MM/DD HH24:MI:SS'), 20) ||
    RPAD(IFNULL(FILE_NAME, ''), FILE_LEN) || CHAR(32) ||
    RPAD(IFNULL(SECTION, ''), SECTION_LEN) || CHAR(32) ||
    RPAD(IFNULL(KEY, ''), KEY_LEN) || CHAR(32) ||
    RPAD(IFNULL(VALUE, ''), VALUE_LEN) || CHAR(32) ||
    RPAD(IFNULL(PREV_VALUE, ''), PREV_VALUE_LEN)
  FROM
    PARAMETER_CHANGES
) L
ORDER BY
  LINE_NO
WITH HINT (IGNORE_PLAN_CACHE)
SQL_EOF

ts="$(date +%Y%m%d_%H%M%S)"
TMP_SQL="${script_dir}/hana_statement_hash_${ts}.sql"
OUTPUT_FILE="${script_dir}/hana_statement_hash_${ts}.out"
ERR_FILE="${script_dir}/hana_statement_hash_${ts}.err"

# --- optional: use an external SQL template instead of the embedded one, e.g.
#     the revision-specific variant downloaded from SAP Note 1969700.
#     If the file still contains the __BEGIN_TIME__ / __END_TIME__ /
#     __STATEMENT_HASH__ placeholders they are substituted as usual; if it is
#     an unmodified SAP file, edit its modification section yourself. ---
if [[ -n "${SQL_FILE:-}" ]]; then
  [[ -r "${SQL_FILE}" ]] || die "SQL_FILE '${SQL_FILE}' does not exist or is not readable"
  SQL_TEMPLATE_CONTENT="$(cat "${SQL_FILE}")"
  echo "Using external SQL template: ${SQL_FILE}" >&2
  if ! grep -q '__BEGIN_TIME__' "${SQL_FILE}"; then
    echo "NOTE: '${SQL_FILE}' has no __BEGIN_TIME__ placeholder - it will be sent unchanged," >&2
    echo "      so BEGIN_TIME / END_TIME / STATEMENT_HASH must already be set inside the file." >&2
  fi
fi

esc_begin="$(printf '%s' "${begin_time}" | sed -e 's/[&/\]/\\&/g')"
esc_end="$(printf '%s' "${end_time}" | sed -e 's/[&/\]/\\&/g')"
esc_hash="$(printf '%s' "${statement_hash}" | sed -e 's/[&/\]/\\&/g')"

printf '%s\n' "${SQL_TEMPLATE_CONTENT}" | sed \
  -e "s/__BEGIN_TIME__/${esc_begin}/" \
  -e "s/__END_TIME__/${esc_end}/" \
  -e "s/__STATEMENT_HASH__/${esc_hash}/" \
  > "${TMP_SQL}" || die "Failed to generate SQL at ${TMP_SQL}"

# --- optional: quote CONSTRAINT, which is a reserved word in newer HANA
#     revisions but is used as a plain identifier by the SAP collector SQL.
#     Set SQL_FIXUPS=1 if the server rejects the statement around the
#     ACCESSED_INDEX_COLUMNS CTE. On by default; set SQL_FIXUPS=0 to send the
#     SAP text completely unchanged. ---
if [[ "${SQL_FIXUPS:-1}" == "1" ]]; then
  sed -i \
    -e 's/^\([[:space:]]*\)CONSTRAINT\([,]*\)[[:space:]]*$/\1"CONSTRAINT"\2/' \
    -e 's/\([A-Za-z0-9_]\)\.CONSTRAINT\([^_A-Za-z0-9]\)/\1."CONSTRAINT"\2/g' \
    -e 's/\([A-Za-z0-9_]\)\.CONSTRAINT$/\1."CONSTRAINT"/' \
    -e "s/'' CONSTRAINT[[:space:]]*$/'' \"CONSTRAINT\"/" \
    -e 's/IFNULL(CONSTRAINT,/IFNULL("CONSTRAINT",/g' \
    "${TMP_SQL}" || die "SQL fixup pass failed"
  echo "Applied SQL_FIXUPS: reserved word CONSTRAINT quoted in ${TMP_SQL}" >&2
fi

echo "sid=${db_sid} inst=${db_inst_no} db=${db_name}" >&2
echo "Generated SQL with BEGIN_TIME='${begin_time}' END_TIME='${end_time}' STATEMENT_HASH='${statement_hash}' -> ${TMP_SQL}" >&2

# --- authentication arguments, shared by the version probe and the main run ---
HDBSQL_AUTH=(-i "${db_inst_no}" -d "${db_name}")
if [[ "${db_password}" == "none" || "${db_password}" == "NONE" ]]; then
  HDBSQL_AUTH+=(-U "${schemaName}")
else
  HDBSQL_AUTH+=(-u "${schemaName}" -p "${db_password}")
fi

# --- pre-flight: report the revision, warn if the embedded SQL needs a newer one ---
if [[ "${SKIP_VERSION_CHECK:-0}" != "1" && -z "${SQL_FILE:-}" ]]; then
  db_version="$("${HDBSQL_BIN}" "${HDBSQL_AUTH[@]}" "SELECT VERSION FROM M_DATABASE" 2>/dev/null \
                 | grep -Eo '[0-9]+\.[0-9]{2}\.[0-9]{3}[0-9.]*' | head -1)"
  if [[ -n "${db_version}" ]]; then
    echo "Database revision: ${db_version}" >&2
    v_major="${db_version%%.*}"
    v_rest="${db_version#*.}"
    v_patch="${v_rest#*.}"; v_patch="${v_patch%%.*}"
    if [[ "${v_major}" =~ ^[0-9]+$ && "${v_patch}" =~ ^[0-9]+$ ]]; then
      if (( v_major < 2 || ( v_major == 2 && 10#${v_patch} < 70 ) )); then
        echo "WARNING: the embedded SQL is the HANA_SQL_StatementHash_DataCollector_2.00.070+ variant," >&2
        echo "         but this database is ${db_version}. Download the matching variant from SAP Note" >&2
        echo "         1969700 and pass it with SQL_FILE=/path/to/that/file.sql" >&2
      fi
    fi
  fi
fi

HDBSQL_ARGS=("${HDBSQL_AUTH[@]}" -I "${TMP_SQL}" -o "${OUTPUT_FILE}")

"${HDBSQL_BIN}" "${HDBSQL_ARGS[@]}" > "${ERR_FILE}" 2>&1
hdbsql_rc=$?
[[ -s "${ERR_FILE}" ]] && cat "${ERR_FILE}" >&2

if [[ ${hdbsql_rc} -ne 0 ]]; then
  # If HANA reported a parse position, show that part of the generated SQL so
  # the offending construct is visible without hunting through 3000 lines.
  err_line="$(sed -n 's/.*line \([0-9][0-9]*\) col [0-9][0-9]*.*/\1/p' "${ERR_FILE}" | head -1)"
  if [[ -n "${err_line}" ]]; then
    echo "" >&2
    echo "--- ${TMP_SQL} around line ${err_line} ---" >&2
    awk -v bad="${err_line}" 'NR >= bad-6 && NR <= bad+6 {
           printf "%s %5d | %s\n", (NR == bad ? ">>" : "  "), NR, $0 }' "${TMP_SQL}" >&2
  fi

  # --- isolate which SQL construct this server rejects -----------------------
  if grep -qi "syntax error" "${ERR_FILE}"; then
    probe() {
      if "${HDBSQL_BIN}" "${HDBSQL_AUTH[@]}" "$2" >/dev/null 2>&1; then
        echo "  [ OK   ]  $1" >&2
      else
        echo "  [ FAIL ]  $1" >&2
      fi
    }
    echo "" >&2
    echo "--- probing which construct this database rejects ---" >&2
    probe "server reachable                    " "SELECT 1 FROM DUMMY"
    probe "empty window spec  MAX(..) OVER ()  " "SELECT MAX(LENGTH(A)) OVER () L FROM ( SELECT 'x' A FROM DUMMY )"
    probe "OVER () above a UNION ALL subquery  " "SELECT MAX(LENGTH(A)) OVER () L FROM ( SELECT 'x' A FROM DUMMY UNION ALL SELECT 'y' A FROM DUMMY )"
    probe "bare reserved word CONSTRAINT       " "SELECT CONSTRAINT FROM INDEX_COLUMNS WHERE 1 = 0"
    probe "quoted \"CONSTRAINT\"                 " "SELECT \"CONSTRAINT\" FROM INDEX_COLUMNS WHERE 1 = 0"
    probe "GREATEST(n, MAX(..) OVER ())        " "SELECT GREATEST(10, MAX(LENGTH(A)) OVER ()) L FROM ( SELECT 'x' A FROM DUMMY )"
    echo "" >&2
    echo "A FAIL above names the construct to work around. If only the CONSTRAINT probe fails," >&2
    echo "make sure SQL_FIXUPS is not set to 0. If a window-function probe fails, this revision" >&2
    echo "needs a different collector variant from SAP Note 1969700 (pass it via SQL_FILE=...)." >&2
  fi
  die "hdbsql execution failed (rc=${hdbsql_rc}, log: ${ERR_FILE})"
fi

rm -f "${ERR_FILE}"
echo "Output written to ${OUTPUT_FILE}"

# ===========================================================================
# Post-processing: render the raw hdbsql output as a readable report.
#
#   REPORT_FORMAT : html | pdf | both (default) | none
#   PDF_ENGINE    : auto (default) | reportlab | wkhtmltopdf | chrome |
#                   weasyprint | libreoffice | awk | none
#
# Nothing below can affect the SQL or the .out file. Every step is optional,
# failures are warnings only, and the awk-based HTML/PDF renderers need no
# python, no reportlab and no other package at all.
# ===========================================================================
REPORT_FORMAT="${REPORT_FORMAT:-both}"
PDF_ENGINE="${PDF_ENGINE:-auto}"
AWK_BIN="${AWK_BIN:-awk}"

BASE="${OUTPUT_FILE%.out}"
CLEAN_TXT="${BASE}.txt"
HTML_OUTPUT="${BASE}.html"
PDF_OUTPUT="${BASE}.pdf"
PDF_SCRIPT="${script_dir}/hana_report_to_pdf.py"
AWK_CLEAN="${script_dir}/hana_report_clean.awk"
AWK_HTML="${script_dir}/hana_report_to_html.awk"
AWK_PDF="${script_dir}/hana_report_to_pdf.awk"
FOOTER_TEXT="SAP HANA Statement Hash Analysis  |  ${db_sid} / ${db_name}  |  hash ${statement_hash}"

have() { command -v "$1" >/dev/null 2>&1; }

# --- awk renderer 1/3: unquote the hdbsql -o output into plain report text ---
cat > "${AWK_CLEAN}" <<'AWKCLEANEOF'
{
  line = $0
  sub(/\r$/, "", line)
  if (line == "LINE") next
  if (line ~ /^".*"$/ && length(line) >= 2)
    line = substr(line, 2, length(line) - 2)
  gsub(/\\"/, "\"", line)
  print line
}
AWKCLEANEOF

# --- awk renderer 2/3: fixed-width report text -> self-contained HTML ---
cat > "${AWK_HTML}" <<'AWKHTMLEOF'
# ---------------------------------------------------------------------------
# hana_report_to_html.awk
# Renders the plain-text output of HANA_SQL_StatementHash_DataCollector
# (SAP Note 1969700) as a self-contained HTML report.
# Requires nothing but awk (mawk/gawk/nawk). Input = cleaned report text.
# Vars: -v RSID= -v RHASH= -v RGEN=
# ---------------------------------------------------------------------------
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

function is_banner(s,   t) { t = trim(s); return (t ~ /^\*\*\*\*\*+$/) }

function is_startitle(s,   t) {
  t = trim(s)
  return (length(t) >= 2 && substr(t, 1, 1) == "*" && substr(t, length(t), 1) == "*")
}

function is_ruler(s,   t) {
  t = trim(s)
  if (t == "") return 0
  gsub(/ /, "", t)
  if (t !~ /^=+$/) return 0
  return (length(t) >= 2)
}

function strip_stars(s,   t) {
  t = trim(s)
  sub(/^\*+/, "", t); sub(/\*+$/, "", t)
  return trim(t)
}

function esc(s) {
  gsub(/&/, "\\&amp;", s)
  gsub(/</, "\\&lt;", s)
  gsub(/>/, "\\&gt;", s)
  return s
}

# fill BS[]/BE[] (1-based, inclusive) from an "=== === ===" ruler line
function col_bounds(ruler,   i, ch, inrun) {
  NB = 0; inrun = 0
  for (i = 1; i <= length(ruler); i++) {
    ch = substr(ruler, i, 1)
    if (ch == "=") {
      if (!inrun) { NB++; BS[NB] = i; inrun = 1 }
      BE[NB] = i
    } else inrun = 0
  }
  return NB
}

function cell(line, idx) {
  if (idx == NB) return trim(substr(line, BS[idx]))
  return trim(substr(line, BS[idx], BE[idx] - BS[idx] + 1))
}

function slug(s,   t) {
  t = tolower(trim(s))
  gsub(/[^a-z0-9]+/, "-", t)
  sub(/^-+/, "", t); sub(/-+$/, "", t)
  return t
}

{ line = $0; sub(/\r$/, "", line); L[++N] = line }

END {
  # ---------- split into preamble + sections ----------
  i = 1; nsec = 0; ncur = 0; npre = 0; havetitle = 0
  while (i <= N) {
    if (is_banner(L[i]) && (i + 2) <= N && is_banner(L[i+2]) && is_startitle(L[i+1])) {
      if (havetitle) {
        nsec++; STITLE[nsec] = curtitle; SN[nsec] = ncur
        for (k = 1; k <= ncur; k++) SL[nsec, k] = CUR[k]
      } else {
        for (k = 1; k <= ncur; k++) PRE[++npre] = CUR[k]
      }
      curtitle = strip_stars(L[i+1]); havetitle = 1; ncur = 0
      i += 3
      continue
    }
    CUR[++ncur] = L[i]; i++
  }
  if (havetitle) {
    nsec++; STITLE[nsec] = curtitle; SN[nsec] = ncur
    for (k = 1; k <= ncur; k++) SL[nsec, k] = CUR[k]
  }

  # first section is the document header -> treat as preamble
  if (nsec >= 1 && toupper(STITLE[1]) ~ /^SAP HANA STATEMENT HASH DATA COLLECTION/) {
    npre = 0
    for (k = 1; k <= SN[1]; k++) PRE[++npre] = SL[1, k]
    for (s = 1; s < nsec; s++) {
      STITLE[s] = STITLE[s+1]; SN[s] = SN[s+1]
      for (k = 1; k <= SN[s+1]; k++) SL[s, k] = SL[s+1, k]
    }
    nsec--
  }

  # ---------- metadata from preamble ----------
  for (k = 1; k <= npre; k++) {
    p = index(PRE[k], ":")
    if (p > 1 && substr(trim(PRE[k]), 1, 1) != "*") {
      key = trim(substr(PRE[k], 1, p - 1))
      val = trim(substr(PRE[k], p + 1))
      if (key != "" && val != "" && !(key in META)) META[key] = val
    }
  }
  hash  = (META["Statement hash"] != "" ? META["Statement hash"] : RHASH)
  sysid = (META["System ID / database name"] != "" ? META["System ID / database name"] : RSID)

  # ---------- HTML head ----------
  print "<!DOCTYPE html>"
  print "<html lang=\"en\"><head><meta charset=\"utf-8\">"
  print "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  print "<title>SAP HANA Statement Hash Analysis - " esc(hash) "</title>"
  print "<style>"
  print ":root{--navy:#1a2f4b;--accent:#2f6fa8;--light:#eef3f8;--grey:#5a6773;--line:#c7d0da}"
  print "*{box-sizing:border-box}"
  print "body{margin:0;background:#f4f6f9;color:#20242b;font:14px/1.45 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif}"
  print ".bar{position:sticky;top:0;z-index:50;background:var(--navy);color:#fff;padding:10px 18px;display:flex;gap:14px;align-items:center;flex-wrap:wrap;box-shadow:0 1px 6px rgba(0,0,0,.25)}"
  print ".bar b{font-size:15px;letter-spacing:.3px}"
  print ".bar .sp{flex:1}"
  print ".bar input{padding:6px 10px;border:0;border-radius:4px;min-width:230px;font-size:13px}"
  print ".bar button{padding:6px 14px;border:0;border-radius:4px;background:var(--accent);color:#fff;font-size:13px;cursor:pointer}"
  print ".bar button:hover{background:#3d84c4}"
  print ".wrap{max-width:1900px;margin:0 auto;padding:18px}"
  print ".cover{background:#fff;border:1px solid var(--line);border-radius:6px;padding:22px 24px;margin-bottom:18px}"
  print ".cover h1{margin:0 0 4px;color:var(--navy);font-size:26px}"
  print ".cover p.sub{margin:0 0 16px;color:var(--grey);font-size:13px}"
  print ".meta{width:100%;border-collapse:collapse}"
  print ".meta td{border:1px solid var(--line);padding:7px 10px;font-size:13px;vertical-align:top}"
  print ".meta td:first-child{background:var(--light);font-weight:600;width:230px;color:var(--navy)}"
  print ".toc{background:#fff;border:1px solid var(--line);border-radius:6px;padding:18px 24px;margin-bottom:18px}"
  print ".toc h2{margin:0 0 12px;color:var(--navy);font-size:18px}"
  print ".toc ol{margin:0;padding-left:20px;columns:3;column-gap:34px;font-size:13px}"
  print ".toc li{margin:3px 0;break-inside:avoid}"
  print ".toc a{color:var(--accent);text-decoration:none}.toc a:hover{text-decoration:underline}"
  print "section{background:#fff;border:1px solid var(--line);border-radius:6px;margin-bottom:16px;overflow:hidden}"
  print "section>h2{margin:0;background:var(--navy);color:#fff;font-size:14px;letter-spacing:.4px;padding:9px 14px;display:flex;align-items:center}"
  print "section>h2 a{margin-left:auto;color:#b9d3ec;font-size:11px;text-decoration:none;font-weight:400}"
  print ".body{padding:12px 14px;overflow-x:auto}"
  print "table.d{border-collapse:collapse;font-size:12px;margin-bottom:10px;width:auto;min-width:60%}"
  print "table.d thead th{background:var(--navy);color:#fff;text-align:left;padding:5px 8px;border:1px solid #2c4767;white-space:nowrap;position:static}"
  print "table.d thead{background:var(--navy)}"
  print "table.d td{border:1px solid var(--line);padding:4px 8px;vertical-align:top;font-family:Menlo,Consolas,monospace;font-size:11.5px;white-space:pre-wrap}"
  print "table.d tbody tr:nth-child(even){background:var(--light)}"
  print "table.d tbody tr:hover{background:#dfeaf5}"
  print "pre{margin:0 0 10px;font:11.5px/1.4 Menlo,Consolas,monospace;background:#fbfcfd;border:1px solid var(--line);border-left:3px solid var(--accent);padding:9px 11px;white-space:pre-wrap;word-break:break-word}"
  print ".none{color:var(--grey);font-style:italic;font-size:12.5px}"
  print ".hide{display:none}"
  print "footer{color:var(--grey);font-size:11.5px;text-align:center;padding:14px 0 26px}"
  print "@media print{"
  print " @page{size:A4 landscape;margin:9mm}"
  print " body{background:#fff}.bar{display:none}.wrap{max-width:none;padding:0}"
  print " section{break-inside:auto;page-break-inside:auto;border:0;margin-bottom:10px}"
  print " section>h2{background:var(--navy)!important;-webkit-print-color-adjust:exact;print-color-adjust:exact}"
  print " table.d thead th{-webkit-print-color-adjust:exact;print-color-adjust:exact}"
  print " table.d thead{display:table-header-group}"
  print " table.d tr{break-inside:avoid;page-break-inside:avoid}"
  print " .toc{page-break-after:always}"
  print "}"
  print "</style></head><body>"

  print "<div class=\"bar\"><b>HANA Statement Hash Analysis</b><span style=\"font:12px Menlo,Consolas,monospace;opacity:.85\">" esc(hash) "</span>"
  print "<span class=\"sp\"></span>"
  print "<input id=\"f\" type=\"search\" placeholder=\"Filter rows (type to search)\" oninput=\"flt(this.value)\">"
  print "<button onclick=\"window.print()\">Print / Save as PDF</button></div>"

  print "<div class=\"wrap\">"

  # ---------- cover ----------
  print "<div class=\"cover\">"
  print "<h1>SAP HANA Statement Hash Analysis</h1>"
  print "<p class=\"sub\">Deep-dive diagnostic collected via HANA_SQL_StatementHash_DataCollector (SAP Note 1969700)</p>"
  print "<table class=\"meta\">"
  print "<tr><td>Statement Hash</td><td>" esc(hash) "</td></tr>"
  print "<tr><td>System / Database</td><td>" esc(sysid) "</td></tr>"
  print "<tr><td>Revision Level</td><td>" esc(META["Revision level"]) "</td></tr>"
  print "<tr><td>Analysis Window</td><td>" esc(META["Start time"]) " &rarr; " esc(META["End time"]) "</td></tr>"
  print "<tr><td>Analysis Time</td><td>" esc(META["Analysis time"]) "</td></tr>"
  print "<tr><td>Report Source</td><td>" esc(META["Generated with"]) "</td></tr>"
  if (RGEN != "") print "<tr><td>Collected On Host</td><td>" esc(RGEN) "</td></tr>"
  print "</table></div>"

  # ---------- toc ----------
  print "<div class=\"toc\"><h2>Contents</h2><ol>"
  for (s = 1; s <= nsec; s++)
    print "<li><a href=\"#s" s "\">" esc(STITLE[s]) "</a></li>"
  print "</ol></div>"

  # ---------- sections ----------
  for (s = 1; s <= nsec; s++) {
    print "<section id=\"s" s "\"><h2>" esc(STITLE[s]) "<a href=\"#\">top &uarr;</a></h2><div class=\"body\">"
    if (toupper(trim(STITLE[s])) == "KEY FIGURES") render_key_figures(s)
    else render_section(s)
    print "</div></section>"
  }

  print "</div>"
  print "<footer>Generated by hana_report_to_html.awk &middot; source: " esc(FILENAME) "</footer>"
  print "<script>"
  print "function flt(q){q=q.toLowerCase();document.querySelectorAll('section').forEach(function(sec){var any=!q;"
  print "sec.querySelectorAll('tbody tr').forEach(function(tr){var m=!q||tr.textContent.toLowerCase().indexOf(q)>-1;tr.classList.toggle('hide',!m);if(m)any=true;});"
  print "sec.querySelectorAll('pre').forEach(function(p){var m=!q||p.textContent.toLowerCase().indexOf(q)>-1;p.classList.toggle('hide',!m);if(m)any=true;});"
  print "sec.classList.toggle('hide',!any);});}"
  print "</script></body></html>"
}

# render one section: blank-line separated blocks, ruler => table, else <pre>
function render_section(s,   k, nb, blk, j, out, empty) {
  nb = 0; empty = 1
  for (k = 1; k <= SN[s]; k++) {
    if (trim(SL[s, k]) == "") {
      if (nb > 0) { flush_block(nb); empty = 0; nb = 0 }
    } else BLK[++nb] = SL[s, k]
  }
  if (nb > 0) { flush_block(nb); empty = 0 }
  if (empty) print "<p class=\"none\">No data returned for this section.</p>"
}

function flush_block(nb,   j, c, txt) {
  if (nb >= 2 && is_ruler(BLK[2])) {
    col_bounds(BLK[2])
    printf "%s", "<table class=\"d\"><thead><tr>"
    for (c = 1; c <= NB; c++) printf "<th>%s</th>", esc(cell(BLK[1], c))
    print "</tr></thead><tbody>"
    for (j = 3; j <= nb; j++) {
      printf "%s", "<tr>"
      for (c = 1; c <= NB; c++) printf "<td>%s</td>", esc(cell(BLK[j], c))
      print "</tr>"
    }
    print "</tbody></table>"
  } else {
    txt = ""
    for (j = 1; j <= nb; j++) txt = txt (j > 1 ? "\n" : "") BLK[j]
    print "<pre>" esc(txt) "</pre>"
  }
}

# KEY FIGURES is one logical table split over several blank-line groups
function render_key_figures(s,   k, nb, j, c, started, rows, nrows) {
  nb = 0; nrows = 0; started = 0
  for (k = 1; k <= SN[s]; k++) {
    if (trim(SL[s, k]) == "") continue
    nb++
    if (nb == 1) { HDR = SL[s, k]; continue }
    if (nb == 2 && is_ruler(SL[s, k])) { col_bounds(SL[s, k]); started = 1; continue }
    ROWS[++nrows] = SL[s, k]
  }
  if (!started) { render_section(s); return }
  printf "%s", "<table class=\"d\"><thead><tr>"
  for (c = 1; c <= NB; c++) printf "<th>%s</th>", esc(cell(HDR, c))
  print "</tr></thead><tbody>"
  for (j = 1; j <= nrows; j++) {
    printf "%s", "<tr>"
    for (c = 1; c <= NB; c++) printf "<td>%s</td>", esc(cell(ROWS[j], c))
    print "</tr>"
  }
  print "</tbody></table>"
}
AWKHTMLEOF

# --- awk renderer 3/3: report text -> formatted landscape A4 PDF (zero dependencies) ---
cat > "${AWK_PDF}" <<'AWKPDFEOF'
# ---------------------------------------------------------------------------
# hana_report_to_pdf.awk
# Renders the cleaned HANA_SQL_StatementHash_DataCollector text as a formatted
# landscape-A4 PDF: cover page, real bordered tables with repeating headers and
# zebra rows, section banners, bookmark outline, page furniture.
# Pure awk - no python, no reportlab, no ghostscript.
# Usage: LC_ALL=C awk -v FOOT="..." -f hana_report_to_pdf.awk report.txt > report.pdf
# ---------------------------------------------------------------------------
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function is_banner(s,   t) { t = trim(s); return (t ~ /^\*\*\*\*\*+$/) }
function is_startitle(s,   t) {
  t = trim(s)
  return (length(t) >= 2 && substr(t, 1, 1) == "*" && substr(t, length(t), 1) == "*")
}
function is_ruler(s,   t) {
  t = trim(s)
  if (t == "") return 0
  gsub(/ /, "", t)
  if (t !~ /^=+$/) return 0
  return (length(t) >= 2)
}
function strip_stars(s,   t) { t = trim(s); sub(/^\*+/, "", t); sub(/\*+$/, "", t); return trim(t) }
function pesc(s) { gsub(/\\/, "\\\\", s); gsub(/\(/, "\\(", s); gsub(/\)/, "\\)", s); return s }
function o(s) { printf "%s\n", s; OFF += length(s) + 1 }

# ---------- page / drawing primitives ----------
function newpage() { NP++; C[NP] = ""; Y = H - MT }
function emit(s)   { C[NP] = C[NP] s "\n" }
function rect(x, y, w, h, r, g, b) {
  emit(sprintf("%.3f %.3f %.3f rg %.2f %.2f %.2f %.2f re f", r, g, b, x, y, w, h))
}
function vline(x, y1, y2, lw, r, g, b) {
  emit(sprintf("%.3f %.3f %.3f RG %.2f w %.2f %.2f m %.2f %.2f l S", r, g, b, lw, x, y1, x, y2))
}
function hline(x1, x2, y, lw, r, g, b) {
  emit(sprintf("%.3f %.3f %.3f RG %.2f w %.2f %.2f m %.2f %.2f l S", r, g, b, lw, x1, y, x2, y))
}
function txt(fnt, sz, x, y, r, g, b, s) {
  emit(sprintf("%.3f %.3f %.3f rg BT /%s %.2f Tf 1 0 0 1 %.2f %.2f Tm (%s) Tj ET",
               r, g, b, fnt, sz, x, y, pesc(s)))
}
function room(h) { return (Y - h >= BOT) }

# ---------- ruler-driven column bounds ----------
function col_bounds(ruler,   i, ch, inrun) {
  NB = 0; inrun = 0
  for (i = 1; i <= length(ruler); i++) {
    ch = substr(ruler, i, 1)
    if (ch == "=") { if (!inrun) { NB++; BS[NB] = i; inrun = 1 } ; BE[NB] = i }
    else inrun = 0
  }
  return NB
}
function cell(line, idx) {
  if (idx == NB) return trim(substr(line, BS[idx]))
  return trim(substr(line, BS[idx], BE[idx] - BS[idx] + 1))
}

# ---------- word-aware wrapping ----------
function wrap_cell(s, cpc,   i, cut, lim) {
  WN = 0
  if (cpc < 1) cpc = 1
  if (s == "") { WN = 1; WL[1] = ""; return 1 }
  while (length(s) > cpc) {
    if (WN >= 14) { WL[++WN] = substr(s, 1, cpc - 3) "..."; return WN }
    cut = 0
    lim = int(cpc * 0.55); if (lim < 2) lim = 2
    for (i = cpc + 1; i >= lim; i--) if (substr(s, i, 1) == " ") { cut = i; break }
    if (cut > 0) { WL[++WN] = trim(substr(s, 1, cut - 1)); s = substr(s, cut + 1) }
    else         { WL[++WN] = substr(s, 1, cpc);           s = substr(s, cpc + 1) }
    sub(/^ +/, "", s)
  }
  WL[++WN] = s
  return WN
}

{ line = $0; sub(/\r$/, "", line); gsub(/\t/, "    ", line); L[++N] = line }

END {
  W = 842; H = 595; ML = 24; MT = 26; BOT = 34; PAD = 2.2
  USE = W - 2 * ML
  NP = 0; NO = 0

  # ================= parse into preamble + sections =================
  i = 1; nsec = 0; ncur = 0; npre = 0; havetitle = 0
  while (i <= N) {
    if (is_banner(L[i]) && (i + 2) <= N && is_banner(L[i+2]) && is_startitle(L[i+1])) {
      if (havetitle) {
        nsec++; STITLE[nsec] = curtitle; SN[nsec] = ncur
        for (k = 1; k <= ncur; k++) SL[nsec, k] = CUR[k]
      } else for (k = 1; k <= ncur; k++) PRE[++npre] = CUR[k]
      curtitle = strip_stars(L[i+1]); havetitle = 1; ncur = 0; i += 3
      continue
    }
    CUR[++ncur] = L[i]; i++
  }
  if (havetitle) {
    nsec++; STITLE[nsec] = curtitle; SN[nsec] = ncur
    for (k = 1; k <= ncur; k++) SL[nsec, k] = CUR[k]
  }
  if (nsec >= 1 && toupper(STITLE[1]) ~ /^SAP HANA STATEMENT HASH DATA COLLECTION/) {
    npre = 0
    for (k = 1; k <= SN[1]; k++) PRE[++npre] = SL[1, k]
    for (s = 1; s < nsec; s++) {
      STITLE[s] = STITLE[s+1]; SN[s] = SN[s+1]
      for (k = 1; k <= SN[s+1]; k++) SL[s, k] = SL[s+1, k]
    }
    nsec--
  }
  for (k = 1; k <= npre; k++) {
    p = index(PRE[k], ":")
    if (p > 1 && substr(trim(PRE[k]), 1, 1) != "*") {
      key = trim(substr(PRE[k], 1, p - 1)); val = trim(substr(PRE[k], p + 1))
      if (key != "" && val != "" && !(key in META)) { META[key] = val; MORD[++NMETA] = key }
    }
  }

  # ================= cover page =================
  newpage()
  txt("F2", 20, ML, Y - 16, 0.102, 0.184, 0.294, "SAP HANA Statement Hash Analysis")
  Y -= 24
  txt("F3", 9.5, ML, Y - 9, 0.353, 0.404, 0.451,
      "Deep-dive diagnostic collected via HANA_SQL_StatementHash_DataCollector (SAP Note 1969700)")
  Y -= 20
  hline(ML, W - ML, Y, 1.2, 0.184, 0.435, 0.659)
  Y -= 18
  lw = 150
  for (k = 1; k <= NMETA; k++) {
    key = MORD[k]
    rh = 15
    rect(ML, Y - rh, lw, rh, 0.933, 0.953, 0.973)
    hline(ML, W - ML, Y, 0.4, 0.78, 0.816, 0.855)
    hline(ML, W - ML, Y - rh, 0.4, 0.78, 0.816, 0.855)
    vline(ML, Y, Y - rh, 0.4, 0.78, 0.816, 0.855)
    vline(ML + lw, Y, Y - rh, 0.4, 0.78, 0.816, 0.855)
    vline(W - ML, Y, Y - rh, 0.4, 0.78, 0.816, 0.855)
    txt("F2", 8, ML + 5, Y - 10.5, 0.102, 0.184, 0.294, key)
    v = META[key]
    if (length(v) > 150) v = substr(v, 1, 147) "..."
    txt("F1", 8, ML + lw + 5, Y - 10.5, 0.126, 0.141, 0.169, v)
    Y -= rh
    if (!room(20)) break
  }

  # ================= sections =================
  for (s = 1; s <= nsec; s++) {
    if (!room(90)) newpage()
    NO++; OTITLE[NO] = STITLE[s]; OPAGE[NO] = NP
    section_header(STITLE[s])
    if (toupper(trim(STITLE[s])) == "KEY FIGURES") render_keyfig(s)
    else render_section(s)
    Y -= 6
  }

  emit_pdf()
}

function section_header(t) {
  CURSEC = t
  if (!room(34)) newpage()
  Y -= 4
  rect(ML, Y - 16, USE, 16, 0.102, 0.184, 0.294)
  txt("F2", 9.5, ML + 7, Y - 11.5, 1, 1, 1, toupper(t))
  Y -= 22
}

# ---- one section: blank-line separated blocks ----
function render_section(s,   k, nb, any) {
  nb = 0; any = 0
  for (k = 1; k <= SN[s]; k++) {
    if (trim(SL[s, k]) == "") { if (nb > 0) { flush_block(nb); any = 1; nb = 0 } }
    else BLK[++nb] = SL[s, k]
  }
  if (nb > 0) { flush_block(nb); any = 1 }
  if (!any) {
    if (!room(16)) newpage()
    txt("F3", 8, ML + 4, Y - 9, 0.353, 0.404, 0.451, "No data returned for this section.")
    Y -= 16
  }
}

function flush_block(nb,   j, c) {
  if (nb >= 2 && is_ruler(BLK[2])) {
    col_bounds(BLK[2])
    NCOL = NB
    for (c = 1; c <= NCOL; c++) THDR[c] = cell(BLK[1], c)
    NROW = 0
    for (j = 3; j <= nb; j++) { NROW++; for (c = 1; c <= NCOL; c++) TROW[NROW, c] = cell(BLK[j], c) }
    draw_table()
  } else {
    draw_pre(nb)
  }
}

# ---- monospace paragraph block ----
function draw_pre(nb,   j, fs, lead, cpl, n, x, i) {
  fs = 6.6; lead = fs * 1.28; cpl = int((USE - 14) / (0.6 * fs))
  for (j = 1; j <= nb; j++) {
    n = wrap_cell(BLK[j], cpl)
    for (i = 1; i <= n; i++) {
      if (!room(lead + 2)) newpage()
      vline(ML + 1.5, Y, Y - lead, 1.6, 0.184, 0.435, 0.659)
      txt("F1", fs, ML + 8, Y - lead + 1.6, 0.126, 0.141, 0.169, WL[i])
      Y -= lead
    }
  }
  Y -= 5
}

# ---- real bordered table with repeating header + zebra rows ----
function draw_table(   c, j, i, maxl, tot, fs, cw, sum, scale, nlines, rh, ytop, k, zebra) {
  tot = 0
  for (c = 1; c <= NCOL; c++) {
    maxl = length(THDR[c])
    for (j = 1; j <= NROW; j++) if (length(TROW[j, c]) > maxl) maxl = length(TROW[j, c])
    if (maxl < 3) maxl = 3
    if (maxl > 55) maxl = 55
    CW[c] = maxl
    tot += maxl
  }
  fs = USE / (0.6 * (tot + 2.6 * NCOL))
  if (fs > 7.0) fs = 7.0
  if (fs < 4.3) fs = 4.3
  CHW = 0.6 * fs
  TLEAD = fs * 1.22

  sum = 0
  for (c = 1; c <= NCOL; c++) { RW[c] = (CW[c] + 2.4) * CHW; sum += RW[c] }
  scale = USE / sum
  CX[1] = ML
  for (c = 1; c <= NCOL; c++) {
    COLW[c] = RW[c] * scale
    CPC[c] = int((COLW[c] - 2 * PAD) / CHW)
    if (CPC[c] < 1) CPC[c] = 1
    CX[c + 1] = CX[c] + COLW[c]
  }
  CX[NCOL + 1] = ML + USE

  HMAX = 1
  for (c = 1; c <= NCOL; c++) {
    HNL[c] = wrap_cell(THDR[c], CPC[c])
    for (i = 1; i <= HNL[c]; i++) HLINE[c, i] = WL[i]
    if (HNL[c] > HMAX) HMAX = HNL[c]
  }
  HDRH = HMAX * TLEAD + 4
  if (!room(HDRH + TLEAD + 6)) newpage()
  ytop = Y
  draw_thead(fs)

  zebra = 0
  for (j = 1; j <= NROW; j++) {
    nlines = 1
    for (c = 1; c <= NCOL; c++) {
      k = wrap_cell(TROW[j, c], CPC[c])
      NLC[c] = k
      for (i = 1; i <= k; i++) CLINE[c, i] = WL[i]
      if (k > nlines) nlines = k
    }
    rh = nlines * TLEAD + 3
    if (!room(rh)) {
      table_verticals(ytop)
      newpage()
      if (CURSEC != "") {
        txt("F3", 7.5, ML, Y - 8, 0.353, 0.404, 0.451, toupper(CURSEC) " (continued)")
        Y -= 13
      }
      ytop = Y
      draw_thead(fs)
    }
    if (zebra) rect(CX[1], Y - rh, USE, rh, 0.933, 0.953, 0.973)
    for (c = 1; c <= NCOL; c++)
      for (i = 1; i <= NLC[c]; i++)
        txt("F1", fs, CX[c] + PAD, Y - i * TLEAD + 1.4, 0.126, 0.141, 0.169, CLINE[c, i])
    Y -= rh
    hline(CX[1], CX[NCOL + 1], Y, 0.35, 0.78, 0.816, 0.855)
    zebra = 1 - zebra
  }
  table_verticals(ytop)
  Y -= 7
}

function draw_thead(fs,   c, i) {
  rect(CX[1], Y - HDRH, USE, HDRH, 0.102, 0.184, 0.294)
  for (c = 1; c <= NCOL; c++)
    for (i = 1; i <= HNL[c]; i++)
      txt("F4", fs, CX[c] + PAD, Y - i * TLEAD + 1.6, 1, 1, 1, HLINE[c, i])
  Y -= HDRH
  hline(CX[1], CX[NCOL + 1], Y, 0.35, 0.78, 0.816, 0.855)
}

function table_verticals(ytop,   c) {
  for (c = 1; c <= NCOL + 1; c++) vline(CX[c], ytop, Y, 0.35, 0.78, 0.816, 0.855)
  hline(CX[1], CX[NCOL + 1], ytop, 0.35, 0.78, 0.816, 0.855)
}

# ================= PDF assembly =================
function emit_pdf(   p, cnum, pnum, kids, c, j, onum, pgobj, e, startxref, foot) {
  OROOT = 7 + 2 * NP
  NOBJ = OROOT + NO
  OFF = 0
  o("%PDF-1.4")
  printf "%%\xE2\xE3\xCF\xD3\n"; OFF += 6

  XREF[1] = OFF
  o("1 0 obj")
  if (NO > 0) o("<< /Type /Catalog /Pages 2 0 R /Outlines " OROOT " 0 R /PageMode /UseOutlines >>")
  else        o("<< /Type /Catalog /Pages 2 0 R >>")
  o("endobj")

  kids = ""
  for (p = 1; p <= NP; p++) kids = kids (p > 1 ? " " : "") (8 + 2 * (p - 1)) " 0 R"
  XREF[2] = OFF
  o("2 0 obj"); o("<< /Type /Pages /Count " NP " /Kids [" kids "] >>"); o("endobj")

  XREF[3] = OFF
  o("3 0 obj"); o("<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>"); o("endobj")
  XREF[4] = OFF
  o("4 0 obj"); o("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>"); o("endobj")
  XREF[5] = OFF
  o("5 0 obj"); o("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"); o("endobj")
  XREF[6] = OFF
  o("6 0 obj"); o("<< /Type /Font /Subtype /Type1 /BaseFont /Courier-Bold /Encoding /WinAnsiEncoding >>"); o("endobj")

  for (p = 1; p <= NP; p++) {
    cnum = 7 + 2 * (p - 1); pnum = cnum + 1
    foot = C[p]
    foot = foot sprintf("0.184 0.435 0.659 RG 0.7 w %.2f 22 m %.2f 22 l S\n", ML, W - ML)
    foot = foot sprintf("0.353 0.404 0.451 rg BT /F3 7 Tf 1 0 0 1 %.2f 12 Tm (%s) Tj ET\n", ML, pesc(FOOT))
    foot = foot sprintf("0.353 0.404 0.451 rg BT /F3 7 Tf 1 0 0 1 %.2f 12 Tm (Page %d of %d) Tj ET",
                        W - ML - 58, p, NP)
    XREF[cnum] = OFF
    o(cnum " 0 obj"); o("<< /Length " length(foot) " >>"); o("stream"); o(foot); o("endstream"); o("endobj")
    XREF[pnum] = OFF
    o(pnum " 0 obj")
    o("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " W " " H "] /Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R /F4 6 0 R >> >> /Contents " cnum " 0 R >>")
    o("endobj")
  }

  if (NO > 0) {
    XREF[OROOT] = OFF
    o(OROOT " 0 obj")
    o("<< /Type /Outlines /First " (OROOT + 1) " 0 R /Last " (OROOT + NO) " 0 R /Count " NO " >>")
    o("endobj")
    for (j = 1; j <= NO; j++) {
      onum = OROOT + j; pgobj = 8 + 2 * (OPAGE[j] - 1)
      e = "<< /Title (" pesc(OTITLE[j]) ") /Parent " OROOT " 0 R"
      if (j > 1)  e = e " /Prev " (onum - 1) " 0 R"
      if (j < NO) e = e " /Next " (onum + 1) " 0 R"
      e = e " /Dest [" pgobj " 0 R /Fit] >>"
      XREF[onum] = OFF
      o(onum " 0 obj"); o(e); o("endobj")
    }
  }

  startxref = OFF
  o("xref"); o("0 " (NOBJ + 1))
  printf "0000000000 65535 f \n"; OFF += 20
  for (j = 1; j <= NOBJ; j++) { printf "%010d 00000 n \n", XREF[j]; OFF += 20 }
  o("trailer"); o("<< /Size " (NOBJ + 1) " /Root 1 0 R >>")
  o("startxref"); o(startxref "")
  printf "%%%%EOF\n"
}

# KEY FIGURES: one logical table spread over several blank-line groups
function render_keyfig(s,   k, nb, c, hdr, started) {
  nb = 0; NROW = 0; started = 0
  for (k = 1; k <= SN[s]; k++) {
    if (trim(SL[s, k]) == "") continue
    nb++
    if (nb == 1) { hdr = SL[s, k]; continue }
    if (nb == 2 && is_ruler(SL[s, k])) { col_bounds(SL[s, k]); NCOL = NB; started = 1; continue }
    NROW++
    for (c = 1; c <= NCOL; c++) TROW[NROW, c] = cell(SL[s, k], c)
  }
  if (!started) { render_section(s); return }
  for (c = 1; c <= NCOL; c++) THDR[c] = cell(hdr, c)
  draw_table()
}
AWKPDFEOF

# --- optional high-fidelity PDF renderer (used only if reportlab exists) ---
cat > "${PDF_SCRIPT}" <<'PYEOF'
#!/usr/bin/env python3
"""
hana_report_to_pdf.py

Converts the plain-text hdbsql output of HANA_SQL_StatementHash_DataCollector
(SAP Note 1969700) into a formatted, multi-page landscape PDF report with a
cover summary, a bookmarked/clickable table of contents, and every report
section rendered as a proper table.

Usage:
    python3 hana_report_to_pdf.py <input.out> <output.pdf>
"""
import re
import sys

from reportlab.lib.pagesizes import landscape, A4
from reportlab.lib import colors
from reportlab.lib.units import cm
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, HRFlowable, PageBreak
)
from reportlab.platypus.tableofcontents import TableOfContents

if len(sys.argv) != 3:
    print("Usage: python3 hana_report_to_pdf.py <input.out> <output.pdf>", file=sys.stderr)
    sys.exit(1)

SRC, OUT = sys.argv[1], sys.argv[2]

NAVY = colors.HexColor("#1a2f4b")
ACCENT = colors.HexColor("#2f6fa8")
LIGHT = colors.HexColor("#eef3f8")
GREY = colors.HexColor("#5a6773")

# ---------- Load & unescape raw lines ----------
raw_lines = []
with open(SRC, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.rstrip("\n")
        if line == "LINE":
            continue
        content = line[1:-1] if line.startswith('"') and line.endswith('"') else line
        content = content.replace('\\"', '"')
        raw_lines.append(content)

# ---------- Split into sections by "****...*" banner blocks ----------
def is_banner(l):
    return bool(re.fullmatch(r"\*{5,}", l.strip()))

sections = []
i, n = 0, len(raw_lines)
preamble = []
current_title, current_lines = None, []
while i < n:
    l = raw_lines[i]
    if (is_banner(l) and i + 2 < n and is_banner(raw_lines[i + 2])
            and raw_lines[i + 1].strip().startswith("*") and raw_lines[i + 1].strip().endswith("*")):
        if current_title is not None:
            sections.append((current_title, current_lines))
        elif current_lines:
            preamble.extend(current_lines)
        current_title = raw_lines[i + 1].strip().strip("*").strip()
        current_lines = []
        i += 3
        continue
    current_lines.append(l)
    i += 1
if current_title is not None:
    sections.append((current_title, current_lines))

if sections and sections[0][0].strip().upper().startswith("SAP HANA STATEMENT HASH DATA COLLECTION"):
    _, preamble = sections.pop(0)

# ---------- Helpers ----------
def is_ruler(l):
    s = l.strip()
    return len(s) > 0 and set(s.replace(" ", "")) <= {"="} and s.count("=") >= 2

def col_bounds(ruler):
    return [[m.start(), m.end()] for m in re.finditer(r"=+", ruler)]

def slice_row(line, bounds):
    cells = []
    for idx, (s, e) in enumerate(bounds):
        cell = (line[s:] if idx == len(bounds) - 1 else line[s:e]) if s < len(line) else ""
        cells.append(cell.strip())
    return cells

def split_blocks(lines):
    blocks, cur = [], []
    for l in lines:
        if l.strip() == "":
            if cur:
                blocks.append(cur)
                cur = []
        else:
            cur.append(l)
    if cur:
        blocks.append(cur)
    return blocks

styles = getSampleStyleSheet()
title_style = ParagraphStyle("TitleBig", parent=styles["Title"], textColor=NAVY, fontSize=24, spaceAfter=6)
subtitle_style = ParagraphStyle("Sub", parent=styles["Normal"], textColor=GREY, fontSize=11, spaceAfter=2)
section_style = ParagraphStyle("Sec", parent=styles["Heading1"], textColor=colors.white, fontSize=13,
                               backColor=NAVY, borderPadding=(6, 8, 6, 8), spaceBefore=14, spaceAfter=8)
toc_title_style = ParagraphStyle("TocTitle", parent=styles["Title"], textColor=NAVY, fontSize=18, spaceAfter=12)
mono_style = ParagraphStyle("Mono", parent=styles["Normal"], fontName="Courier", fontSize=7.5, leading=9.5,
                             textColor=colors.HexColor("#20242b"))
cell_style = ParagraphStyle("Cell", parent=styles["Normal"], fontName="Helvetica", fontSize=7.2, leading=8.6,
                             wordWrap="CJK")
hdr_cell_style = ParagraphStyle("HdrCell", parent=styles["Normal"], fontName="Helvetica-Bold", fontSize=7.4,
                                 leading=8.8, textColor=colors.white)
note_style = ParagraphStyle("Note", parent=styles["Normal"], fontName="Helvetica-Oblique", fontSize=8, textColor=GREY)

def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;") if t else "&nbsp;"

def compute_col_widths(header_cells, data_rows, avail_width, min_cm=1.55, max_cm=9.5, char_w=4.35):
    ncols = len(header_cells)
    maxlen = [len(h) for h in header_cells]
    for row in data_rows:
        for idx, c in enumerate(row):
            if idx < ncols:
                maxlen[idx] = max(maxlen[idx], len(c))
    raw = [max(min_cm * cm, min(max_cm * cm, m * char_w)) for m in maxlen]
    scale = avail_width / sum(raw)
    return [w * scale for w in raw]

def make_table(header_cells, data_rows, avail_width):
    widths = compute_col_widths(header_cells, data_rows, avail_width)
    tbl_data = [[Paragraph(esc(h), hdr_cell_style) for h in header_cells]]
    for row in data_rows:
        tbl_data.append([Paragraph(esc(c), cell_style) for c in row])
    t = Table(tbl_data, colWidths=widths, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), NAVY),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#c7d0da")),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, LIGHT]),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
        ("LEFTPADDING", (0, 0), (-1, -1), 4),
        ("RIGHTPADDING", (0, 0), (-1, -1), 4),
    ]))
    return t

def render_generic_section(lines, avail_width):
    flows = []
    blocks = split_blocks(lines)
    if not blocks:
        return [Paragraph("<i>No data returned for this section.</i>", note_style)]
    for block in blocks:
        if len(block) >= 2 and is_ruler(block[1]):
            bounds = col_bounds(block[1])
            header_cells = slice_row(block[0], bounds)
            data_rows = [slice_row(l, bounds) for l in block[2:]]
            flows.append(make_table(header_cells, data_rows, avail_width))
        else:
            text = "<br/>".join(l.replace("&", "&amp;").replace("<", "&lt;").replace("\\n", "<br/>") for l in block)
            flows.append(Paragraph(text, mono_style))
        flows.append(Spacer(1, 8))
    return flows

def render_key_figures(lines, avail_width):
    """KEY FIGURES is one logical table whose rows are split across several
    blank-line-separated groups in the raw output; merge them back into a
    single continuous table instead of one table per group."""
    blocks = split_blocks(lines)
    if not blocks:
        return [Paragraph("<i>No data returned for this section.</i>", note_style)]
    header_block = blocks[0]
    bounds = col_bounds(header_block[1])
    header_cells = slice_row(header_block[0], bounds)
    data_rows = [slice_row(l, bounds) for l in header_block[2:]]
    for block in blocks[1:]:
        for l in block:
            data_rows.append(slice_row(l, bounds))
    return [make_table(header_cells, data_rows, avail_width), Spacer(1, 8)]

# ---------- Document with TOC + outline bookmarks ----------
class ReportDoc(SimpleDocTemplate):
    def afterFlowable(self, flowable):
        if isinstance(flowable, Paragraph) and flowable.style.name == "Sec":
            text = flowable.getPlainText()
            key = "sec-%d" % id(flowable) if not hasattr(flowable, "_bmkey") else flowable._bmkey
            self.canv.bookmarkPage(key)
            self.canv.addOutlineEntry(text, key, level=0, closed=False)
            self.notify("TOCEntry", (0, text, self.page, key))

doc = ReportDoc(
    OUT, pagesize=landscape(A4),
    leftMargin=1.4 * cm, rightMargin=1.4 * cm, topMargin=1.3 * cm, bottomMargin=1.3 * cm,
    title="SAP HANA Statement Hash Analysis Report",
)
avail_w = landscape(A4)[0] - doc.leftMargin - doc.rightMargin

meta = {}
for l in preamble:
    if ":" in l and not l.strip().startswith("*"):
        parts = re.split(r":\s+", l, maxsplit=1)
        if len(parts) == 2:
            meta[parts[0].strip()] = parts[1].strip()

story = []

# ----- Cover -----
story.append(Paragraph("SAP HANA Statement Hash Analysis Report", title_style))
story.append(Paragraph("Deep-dive diagnostic collected via HANA_SQL_StatementHash_DataCollector (SAP Note 1969700)",
                        subtitle_style))
story.append(Spacer(1, 10))
story.append(HRFlowable(width="100%", thickness=1.4, color=ACCENT))
story.append(Spacer(1, 10))

info_rows = [
    ["Statement Hash", meta.get("Statement hash", "")],
    ["System / Database", meta.get("System ID / database name", "")],
    ["Revision Level", meta.get("Revision level", "")],
    ["Analysis Window", f'{meta.get("Start time", "")}  →  {meta.get("End time", "")}'],
    ["Report Source", meta.get("Generated with", "")],
]
info_tbl = Table(
    [[Paragraph(f"<b>{k}</b>", cell_style), Paragraph(esc(v), cell_style)] for k, v in info_rows],
    colWidths=[5.5 * cm, avail_w - 5.5 * cm],
)
info_tbl.setStyle(TableStyle([
    ("BACKGROUND", (0, 0), (0, -1), LIGHT),
    ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#c7d0da")),
    ("TOPPADDING", (0, 0), (-1, -1), 5),
    ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
    ("LEFTPADDING", (0, 0), (-1, -1), 6),
]))
story.append(info_tbl)
story.append(Spacer(1, 18))

# ----- Table of contents -----
story.append(Paragraph("Contents", toc_title_style))
toc = TableOfContents()
toc.levelStyles = [
    ParagraphStyle(name="TOCLevel0", fontName="Helvetica", fontSize=10.5, leading=16,
                    textColor=colors.HexColor("#1a2f4b")),
]
story.append(toc)
story.append(PageBreak())

# ----- Sections -----
for title, lines in sections:
    story.append(Paragraph(title, section_style))
    if title.strip().upper() == "KEY FIGURES":
        story.extend(render_key_figures(lines, avail_w))
    else:
        story.extend(render_generic_section(lines, avail_w))

def add_page_furniture(canvas, doc_):
    canvas.saveState()
    canvas.setStrokeColor(ACCENT)
    canvas.setLineWidth(1)
    canvas.line(doc_.leftMargin, 1.0 * cm, landscape(A4)[0] - doc_.rightMargin, 1.0 * cm)
    canvas.setFont("Helvetica", 8)
    canvas.setFillColor(GREY)
    canvas.drawString(doc_.leftMargin, 0.65 * cm,
                       "SAP HANA Statement Hash Analysis  |  Statement Hash: " + meta.get("Statement hash", ""))
    canvas.drawRightString(landscape(A4)[0] - doc_.rightMargin, 0.65 * cm, f"Page {doc_.page}")
    canvas.restoreState()

doc.multiBuild(story, onFirstPage=add_page_furniture, onLaterPages=add_page_furniture)
print("Wrote", OUT)
PYEOF

# --- 1) always produce the cleaned plain-text version (feeds HTML + PDF) ---
if ! "${AWK_BIN}" -f "${AWK_CLEAN}" "${OUTPUT_FILE}" > "${CLEAN_TXT}" 2>/dev/null; then
  echo "WARNING: could not build cleaned text from ${OUTPUT_FILE}; report rendering skipped." >&2
  REPORT_FORMAT="none"
fi

# --- 2) HTML report (awk only - works on every host, always succeeds) ---
if [[ "${REPORT_FORMAT}" == "html" || "${REPORT_FORMAT}" == "both" || "${REPORT_FORMAT}" == "pdf" ]]; then
  if "${AWK_BIN}" -v RSID="${db_sid} / ${db_name}" -v RHASH="${statement_hash}" \
                  -v RGEN="$(hostname 2>/dev/null) at $(date '+%Y-%m-%d %H:%M:%S')" \
                  -f "${AWK_HTML}" "${CLEAN_TXT}" > "${HTML_OUTPUT}" 2>/dev/null; then
    [[ "${REPORT_FORMAT}" != "pdf" ]] && echo "HTML report written to ${HTML_OUTPUT}"
  else
    echo "WARNING: HTML report generation failed; the raw output at ${OUTPUT_FILE} is unaffected." >&2
  fi
fi

# --- 3) PDF report: try every engine that might exist on this host ---
find_reportlab_python() {
  local c
  for c in python3 python \
           "/usr/sap/${db_sid}/HDB${db_inst_no}/exe/Python3/bin/python3" \
           "/usr/sap/${db_sid}/HDB${db_inst_no}/exe/python_support/python3"; do
    if have "$c" || [[ -x "$c" ]]; then
      if "$c" -c 'import reportlab' >/dev/null 2>&1; then echo "$c"; return 0; fi
    fi
  done
  return 1
}

generate_pdf() {
  local eng="$1" py br lo c
  case "${eng}" in
    reportlab)
      py="$(find_reportlab_python)" || return 1
      "${py}" "${PDF_SCRIPT}" "${OUTPUT_FILE}" "${PDF_OUTPUT}" >/dev/null 2>&1 || return 1
      ;;
    wkhtmltopdf)
      have wkhtmltopdf || return 1
      [[ -s "${HTML_OUTPUT}" ]] || return 1
      wkhtmltopdf --quiet --print-media-type --orientation Landscape --page-size A4 \
        --margin-top 8mm --margin-bottom 8mm --margin-left 8mm --margin-right 8mm \
        "${HTML_OUTPUT}" "${PDF_OUTPUT}" >/dev/null 2>&1 || return 1
      ;;
    chrome)
      br=""
      for c in chromium chromium-browser google-chrome google-chrome-stable microsoft-edge; do
        have "$c" && { br="$c"; break; }
      done
      [[ -n "${br}" ]] || return 1
      [[ -s "${HTML_OUTPUT}" ]] || return 1
      "${br}" --headless --disable-gpu --no-sandbox --no-pdf-header-footer \
        --print-to-pdf="${PDF_OUTPUT}" "file://${HTML_OUTPUT}" >/dev/null 2>&1 || return 1
      ;;
    weasyprint)
      have weasyprint || return 1
      [[ -s "${HTML_OUTPUT}" ]] || return 1
      weasyprint "${HTML_OUTPUT}" "${PDF_OUTPUT}" >/dev/null 2>&1 || return 1
      ;;
    libreoffice)
      lo=""
      for c in soffice libreoffice; do have "$c" && { lo="$c"; break; }; done
      [[ -n "${lo}" ]] || return 1
      [[ -s "${HTML_OUTPUT}" ]] || return 1
      "${lo}" --headless --convert-to pdf --outdir "${script_dir}" "${HTML_OUTPUT}" >/dev/null 2>&1 || return 1
      ;;
    awk)
      LC_ALL=C "${AWK_BIN}" -v FOOT="${FOOTER_TEXT}" -f "${AWK_PDF}" "${CLEAN_TXT}" \
        > "${PDF_OUTPUT}" 2>/dev/null || return 1
      ;;
    *) return 1 ;;
  esac
  [[ -s "${PDF_OUTPUT}" ]]
}

if [[ "${REPORT_FORMAT}" == "pdf" || "${REPORT_FORMAT}" == "both" ]]; then
  if [[ "${PDF_ENGINE}" == "none" ]]; then
    :
  elif [[ "${PDF_ENGINE}" != "auto" ]]; then
    if generate_pdf "${PDF_ENGINE}"; then
      echo "PDF report written to ${PDF_OUTPUT} (engine: ${PDF_ENGINE})"
    else
      echo "WARNING: PDF engine '${PDF_ENGINE}' not available or failed on this host." >&2
      echo "         Use the HTML report at ${HTML_OUTPUT}, or set PDF_ENGINE=awk." >&2
    fi
  else
    pdf_done=0
    for eng in reportlab wkhtmltopdf chrome weasyprint libreoffice awk; do
      if generate_pdf "${eng}"; then
        echo "PDF report written to ${PDF_OUTPUT} (engine: ${eng})"
        pdf_done=1
        break
      fi
    done
    if [[ ${pdf_done} -eq 0 ]]; then
      echo "WARNING: no PDF engine succeeded; use the HTML report at ${HTML_OUTPUT}" >&2
      echo "         (open it in a browser and Print -> Save as PDF)." >&2
    fi
  fi
fi
