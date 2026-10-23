#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Applies the SQL migrations and grants each Function App's managed identity a
# least-privilege contained database user.
#
# Terraform cannot do this: creating an Entra-backed DB user requires a T-SQL
# connection as the SQL Entra admin. This script is the declarative substitute -
# it is idempotent, checked in, and run by the pipeline right after apply. It is
# not click-ops.
#
# Auth: uses the pipeline's Entra identity (az login / federated credential).
# No password is read, and none is needed - the break-glass password stays in
# Key Vault and is never used by automation.
#
# Usage:
#   ./bootstrap-sql.sh <sql-server-fqdn> <database> <api-app-name> <ingest-app-name>
# ---------------------------------------------------------------------------
set -euo pipefail

SERVER="${1:?sql server fqdn required}"
DATABASE="${2:?database name required}"
API_APP="${3:?api function app name required}"
INGEST_APP="${4:?ingest function app name required}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SQL_DIR="$(cd "${SCRIPT_DIR}/../sql" && pwd)"

# -I: QUOTED_IDENTIFIER ON. -f 65001: UTF-8, so the unit symbols survive.
SQLCMD_COMMON=(-S "${SERVER}" -d "${DATABASE}" -G -I -f 65001 -b)

echo "==> Applying migrations to ${SERVER}/${DATABASE}"
for migration in "${SQL_DIR}"/*.sql; do
  echo "    - $(basename "${migration}")"
  sqlcmd "${SQLCMD_COMMON[@]}" -i "${migration}"
done

echo "==> Granting managed-identity database users"
# EXECUTE on the schema (not db_datareader/db_datawriter): the apps only ever call
# stored procedures, so direct table access is not granted at all. That means a SQL
# injection bug in the API cannot read or write a table the procs do not expose.
GRANT_SQL=$(cat <<SQL
SET NOCOUNT ON;
DECLARE @principals TABLE (Name SYSNAME);
INSERT INTO @principals (Name) VALUES (N'${API_APP}'), (N'${INGEST_APP}');

DECLARE @name SYSNAME, @sql NVARCHAR(MAX);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Name FROM @principals;
OPEN cur;
FETCH NEXT FROM cur INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @name)
    BEGIN
        SET @sql = N'CREATE USER ' + QUOTENAME(@name) + N' FROM EXTERNAL PROVIDER;';
        EXEC sp_executesql @sql;
    END;

    SET @sql = N'GRANT EXECUTE ON SCHEMA::dbo TO ' + QUOTENAME(@name) + N';';
    EXEC sp_executesql @sql;

    -- Required so a table-valued parameter can be passed to the ingest proc.
    SET @sql = N'GRANT EXECUTE ON TYPE::dbo.ReadingTvp TO ' + QUOTENAME(@name) + N';';
    EXEC sp_executesql @sql;

    FETCH NEXT FROM cur INTO @name;
END;
CLOSE cur;
DEALLOCATE cur;
SQL
)

sqlcmd "${SQLCMD_COMMON[@]}" -Q "${GRANT_SQL}"

echo "==> Done. Function App identities can execute procedures and nothing else."
