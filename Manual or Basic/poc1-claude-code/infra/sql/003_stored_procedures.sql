/* ===========================================================================
   003_stored_procedures.sql - hot read/write paths

   Why stored procedures and not ad-hoc SQL / ORM queries:
   - The ingest path must do insert + threshold evaluation + alert raise in ONE
     round trip to protect the 30s alert budget.
   - The chart path must downsample server-side; sending 17k points per channel
     to a browser is not viable.
   - Both are set-based and plan-stable, which matters more than developer
     convenience on the two paths that carry all the load.
   Cost of this choice: query logic lives outside the C# solution, so it needs
   its own migration discipline and its own tests (see .claude/rules/testing.md;
   Agent C owns integration tests that exercise each proc).

   Column aliases below deliberately match the field names in Agent A's
   component contracts, so Agent C's DTO mapping is 1:1.
   =========================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ===========================================================================
   INGEST - single round trip: persist readings, refresh heartbeat, evaluate
   thresholds, raise alerts, return what was raised so the caller can push it
   over SignalR immediately.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_IngestReadingBatch
    @Readings dbo.ReadingTvp READONLY,
    @NowUtc   DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @NowUtc IS NULL SET @NowUtc = SYSUTCDATETIME();

    /* Drop physically implausible values (sensor faults) and unknown channels.
       A stuck sensor reporting -9999 must never reach the chart or an alert. */
    DECLARE @Valid TABLE
    (
        DeviceId   NVARCHAR(128) NOT NULL,
        ChannelId  VARCHAR(64)   NOT NULL,
        ObservedAt DATETIME2(3)  NOT NULL,
        Value      FLOAT         NOT NULL,
        PRIMARY KEY (DeviceId, ChannelId, ObservedAt)
    );

    INSERT INTO @Valid (DeviceId, ChannelId, ObservedAt, Value)
    SELECT r.DeviceId, r.ChannelId, r.ObservedAt, r.Value
    FROM   @Readings AS r
    JOIN   dbo.SensorChannel AS c ON c.ChannelId = r.ChannelId AND c.IsActive = 1
    WHERE  (c.MinValid IS NULL OR r.Value >= c.MinValid)
      AND  (c.MaxValid IS NULL OR r.Value <= c.MaxValid)
      /* Reject readings from a badly skewed device clock rather than letting them
         appear in the future on a 24h chart. */
      AND  r.ObservedAt <= DATEADD(MINUTE, 5, @NowUtc)
      AND  r.ObservedAt >= DATEADD(DAY, -2, @NowUtc);

    IF NOT EXISTS (SELECT 1 FROM @Valid)
    BEGIN
        SELECT CAST(0 AS INT) AS ReadingsInserted, CAST(0 AS INT) AS AlertsRaised;

        /* Emit an empty second result set with the SAME shape as the success path,
           so the caller never has to branch on "did I get one result set or two". */
        SELECT TOP (0)
               a.AlertId AS alertId, a.DeviceId AS deviceId, d.Name AS deviceName,
               a.ChannelId AS channelId, sc.Label AS channelLabel, a.Severity AS severity,
               a.Message AS message, a.BreachedAt AS breachedAt,
               a.AcknowledgedAt AS acknowledgedAt, a.AcknowledgedByName AS acknowledgedBy,
               a.ObservedValue AS observedValue, a.ThresholdValue AS thresholdValue
        FROM   dbo.Alert AS a
        JOIN   dbo.Device AS d ON d.DeviceId = a.DeviceId
        JOIN   dbo.SensorChannel AS sc ON sc.ChannelId = a.ChannelId;
        RETURN;
    END;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* Device provisioning is out of scope for this slice, so an unknown device
           is auto-registered as a stub instead of having its telemetry dropped.
           Trade-off: a typo'd device id becomes a row. Accepted because losing
           telemetry silently is strictly worse than an extra row an operator can
           see and delete. */
        INSERT INTO dbo.Device (DeviceId, Name)
        SELECT DISTINCT v.DeviceId, v.DeviceId
        FROM   @Valid AS v
        WHERE  NOT EXISTS (SELECT 1 FROM dbo.Device AS d WHERE d.DeviceId = v.DeviceId);

        INSERT INTO dbo.DeviceChannel (DeviceId, ChannelId)
        SELECT DISTINCT v.DeviceId, v.ChannelId
        FROM   @Valid AS v
        WHERE  NOT EXISTS (
                   SELECT 1 FROM dbo.DeviceChannel AS dc
                   WHERE dc.DeviceId = v.DeviceId AND dc.ChannelId = v.ChannelId);

        /* At-least-once delivery means redeliveries are normal, not exceptional:
           NOT EXISTS makes the insert idempotent without relying on
           IGNORE_DUP_KEY (which is expensive on a clustered index). */
        INSERT INTO dbo.Reading (DeviceId, ChannelId, ObservedAt, Value, IngestedAt)
        SELECT v.DeviceId, v.ChannelId, v.ObservedAt, v.Value, @NowUtc
        FROM   @Valid AS v
        WHERE  NOT EXISTS (
                   SELECT 1 FROM dbo.Reading AS r
                   WHERE r.DeviceId = v.DeviceId
                     AND r.ChannelId = v.ChannelId
                     AND r.ObservedAt = v.ObservedAt);

        DECLARE @ReadingsInserted INT = @@ROWCOUNT;

        /* Heartbeat: newest observation per device drives online/offline. */
        UPDATE d
        SET    d.LastSeenAt = x.MaxObservedAt
        FROM   dbo.Device AS d
        JOIN   (SELECT DeviceId, MAX(ObservedAt) AS MaxObservedAt FROM @Valid GROUP BY DeviceId) AS x
               ON x.DeviceId = d.DeviceId
        WHERE  d.LastSeenAt IS NULL OR d.LastSeenAt < x.MaxObservedAt;

        /* ---------------------------------------------------------------
           Threshold evaluation.
           Rule resolution: a per-device rule overrides the fleet default for
           the same channel + severity (ROW_NUMBER on DeviceId DESC picks the
           device-specific row when one exists).
           --------------------------------------------------------------- */
        DECLARE @Breach TABLE
        (
            DeviceId       NVARCHAR(128) NOT NULL,
            ChannelId      VARCHAR(64)   NOT NULL,
            RuleId         INT           NOT NULL,
            Severity       VARCHAR(16)   NOT NULL,
            ObservedAt     DATETIME2(3)  NOT NULL,
            Value          FLOAT         NOT NULL,
            ThresholdValue FLOAT         NULL,
            Message        NVARCHAR(400) NOT NULL,
            DebounceSeconds INT          NOT NULL
        );

        WITH resolved AS (
            SELECT v.DeviceId, v.ChannelId, v.ObservedAt, v.Value,
                   ar.RuleId, ar.Severity, ar.Comparison, ar.ThresholdLow, ar.ThresholdHigh,
                   ar.MessageTemplate, ar.DebounceSeconds,
                   sc.Unit,
                   ROW_NUMBER() OVER (
                       PARTITION BY v.DeviceId, v.ChannelId, v.ObservedAt, ar.Severity
                       ORDER BY CASE WHEN ar.DeviceId IS NULL THEN 1 ELSE 0 END
                   ) AS RulePriority
            FROM   @Valid AS v
            JOIN   dbo.SensorChannel AS sc ON sc.ChannelId = v.ChannelId
            JOIN   dbo.AlertRule AS ar
                   ON  ar.ChannelId = v.ChannelId
                   AND ar.IsEnabled = 1
                   AND (ar.DeviceId IS NULL OR ar.DeviceId = v.DeviceId)
            WHERE  (ar.Comparison = 'gt' AND v.Value > ar.ThresholdHigh)
               OR  (ar.Comparison = 'lt' AND v.Value < ar.ThresholdLow)
               OR  (ar.Comparison = 'outside_range'
                    AND (v.Value < ar.ThresholdLow OR v.Value > ar.ThresholdHigh))
        ),
        /* Only the worst breach per device+channel in this batch becomes an alert.
           A batch containing 20 points over the same threshold is one problem,
           not 20 alerts. */
        worst AS (
            SELECT r.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY r.DeviceId, r.ChannelId
                       ORDER BY sv.Rank DESC, r.ObservedAt DESC
                   ) AS Pick
            FROM   resolved AS r
            JOIN   dbo.Severity AS sv ON sv.Code = r.Severity
            WHERE  r.RulePriority = 1
        )
        INSERT INTO @Breach (DeviceId, ChannelId, RuleId, Severity, ObservedAt, Value,
                             ThresholdValue, Message, DebounceSeconds)
        SELECT w.DeviceId, w.ChannelId, w.RuleId, w.Severity, w.ObservedAt, w.Value,
               CASE w.Comparison WHEN 'gt' THEN w.ThresholdHigh
                                 WHEN 'lt' THEN w.ThresholdLow
                                 ELSE w.ThresholdHigh END,
               REPLACE(
                 REPLACE(w.MessageTemplate, N'{value}', FORMAT(w.Value, N'0.##')),
                 N'{unit}', w.Unit),
               w.DebounceSeconds
        FROM   worst AS w
        WHERE  w.Pick = 1;

        /* Debounce: suppress a repeat of the same rule inside its window. */
        DECLARE @Raised TABLE (AlertId UNIQUEIDENTIFIER NOT NULL PRIMARY KEY);

        INSERT INTO dbo.Alert (DeviceId, ChannelId, RuleId, Severity, Message,
                               ObservedValue, ThresholdValue, BreachedAt, RaisedAt)
        OUTPUT inserted.AlertId INTO @Raised (AlertId)
        SELECT b.DeviceId, b.ChannelId, b.RuleId, b.Severity, b.Message,
               b.Value, b.ThresholdValue, b.ObservedAt, @NowUtc
        FROM   @Breach AS b
        WHERE  NOT EXISTS (
                   SELECT 1
                   FROM   dbo.Alert AS a
                   WHERE  a.DeviceId = b.DeviceId
                     AND  a.ChannelId = b.ChannelId
                     AND  a.RuleId = b.RuleId
                     AND  a.BreachedAt > DATEADD(SECOND, -b.DebounceSeconds, b.ObservedAt));

        COMMIT TRANSACTION;

        SELECT @ReadingsInserted AS ReadingsInserted,
               (SELECT COUNT(*) FROM @Raised) AS AlertsRaised;

        /* Second result set: the alerts to fan out. Shaped exactly like the UI's
           Alert interface so the Function can publish it without reshaping. */
        SELECT a.AlertId          AS alertId,
               a.DeviceId         AS deviceId,
               d.Name             AS deviceName,
               a.ChannelId        AS channelId,
               sc.Label           AS channelLabel,
               a.Severity         AS severity,
               a.Message          AS message,
               a.BreachedAt       AS breachedAt,
               a.AcknowledgedAt   AS acknowledgedAt,
               a.AcknowledgedByName AS acknowledgedBy,
               a.ObservedValue    AS observedValue,
               a.ThresholdValue   AS thresholdValue
        FROM   dbo.Alert AS a
        JOIN   @Raised AS r ON r.AlertId = a.AlertId
        JOIN   dbo.Device AS d ON d.DeviceId = a.DeviceId
        JOIN   dbo.SensorChannel AS sc ON sc.ChannelId = a.ChannelId
        ORDER BY a.BreachedAt DESC;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* ===========================================================================
   DEVICE LIST - GET /devices
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_GetDeviceSummaries
    @Search              NVARCHAR(128) = NULL,
    @StatusFilter        VARCHAR(16)   = 'all',   -- all | online | offline
    @OfflineAfterSeconds INT           = 90,
    @Page                INT           = 1,
    @PageSize            INT           = 50
AS
BEGIN
    SET NOCOUNT ON;

    IF @Page < 1 SET @Page = 1;
    IF @PageSize < 1 OR @PageSize > 200 SET @PageSize = 50;

    DECLARE @NowUtc DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @Cutoff DATETIME2(3) = DATEADD(SECOND, -@OfflineAfterSeconds, @NowUtc);

    WITH filtered AS (
        SELECT d.DeviceId, d.Name, d.LastSeenAt,
               CASE WHEN d.LastSeenAt IS NOT NULL AND d.LastSeenAt >= @Cutoff
                    THEN 'online' ELSE 'offline' END AS Status
        FROM   dbo.Device AS d
        WHERE  d.IsEnabled = 1
          AND  (@Search IS NULL OR @Search = N'' OR d.Name LIKE N'%' + @Search + N'%' OR d.DeviceId LIKE N'%' + @Search + N'%')
    ),
    statused AS (
        SELECT * FROM filtered
        WHERE @StatusFilter IS NULL OR @StatusFilter = 'all' OR Status = @StatusFilter
    )
    SELECT s.DeviceId   AS deviceId,
           s.Name       AS name,
           s.Status     AS status,
           s.LastSeenAt AS lastSeenAt,
           ISNULL(act.ActiveCount, 0) AS activeAlertCount,
           act.HighestSeverity        AS highestActiveSeverity,
           COUNT(*) OVER ()           AS totalCount
    FROM   statused AS s
    OUTER APPLY (
        /* Filtered index IX_Alert_Active serves this; the correlated apply keeps
           it a seek per device rather than a full alert scan. */
        SELECT COUNT(*) AS ActiveCount,
               (SELECT TOP (1) sv2.Code
                FROM   dbo.Alert AS a2
                JOIN   dbo.Severity AS sv2 ON sv2.Code = a2.Severity
                WHERE  a2.DeviceId = s.DeviceId AND a2.AcknowledgedAt IS NULL
                ORDER BY sv2.Rank DESC) AS HighestSeverity
        FROM   dbo.Alert AS a
        WHERE  a.DeviceId = s.DeviceId AND a.AcknowledgedAt IS NULL
    ) AS act
    ORDER BY s.Name
    OFFSET (@Page - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END;
GO

/* ===========================================================================
   DEVICE DETAIL - GET /devices/{deviceId}
   Two result sets: the device, then its channels.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_GetDeviceDetail
    @DeviceId            NVARCHAR(128),
    @OfflineAfterSeconds INT = 90
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Cutoff DATETIME2(3) = DATEADD(SECOND, -@OfflineAfterSeconds, SYSUTCDATETIME());

    SELECT d.DeviceId AS deviceId,
           d.Name     AS name,
           CASE WHEN d.LastSeenAt IS NOT NULL AND d.LastSeenAt >= @Cutoff
                THEN 'online' ELSE 'offline' END AS status,
           d.LastSeenAt AS lastSeenAt,
           d.Location   AS location
    FROM   dbo.Device AS d
    WHERE  d.DeviceId = @DeviceId AND d.IsEnabled = 1;

    SELECT sc.ChannelId AS channelId,
           sc.Label     AS label,
           sc.Unit      AS unit,
           sc.ValueKind AS valueKind
    FROM   dbo.DeviceChannel AS dc
    JOIN   dbo.SensorChannel AS sc ON sc.ChannelId = dc.ChannelId
    WHERE  dc.DeviceId = @DeviceId AND sc.IsActive = 1
    ORDER BY sc.DisplayOrder, sc.ChannelId;
END;
GO

/* ===========================================================================
   READINGS - GET /devices/{id}/readings (chart data)

   Server-side downsampling. At 1 reading / 5s a 24h window is ~17k points per
   channel; a line chart at 1440px cannot show more than ~1400 of them. We
   return time-bucketed avg (plus min/max so spikes survive downsampling) and
   cap the payload. @MaxPoints = 0 means "no downsampling" - only for exports.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_GetReadings
    @DeviceId  NVARCHAR(128),
    @ChannelId VARCHAR(64) = NULL,      -- NULL = every channel the device reports
    @FromUtc   DATETIME2(3),
    @ToUtc     DATETIME2(3),
    @MaxPoints INT = 720
AS
BEGIN
    SET NOCOUNT ON;

    IF @ToUtc <= @FromUtc RETURN;

    DECLARE @WindowSeconds INT = DATEDIFF(SECOND, @FromUtc, @ToUtc);
    DECLARE @BucketSeconds INT =
        CASE WHEN @MaxPoints IS NULL OR @MaxPoints <= 0 THEN 0
             ELSE CASE WHEN CEILING(@WindowSeconds / CAST(@MaxPoints AS FLOAT)) < 1
                       THEN 1
                       ELSE CAST(CEILING(@WindowSeconds / CAST(@MaxPoints AS FLOAT)) AS INT) END
        END;

    IF @BucketSeconds = 0
    BEGIN
        SELECT r.ChannelId  AS channelId,
               r.ObservedAt AS timestamp,
               r.Value      AS value,
               r.Value      AS minValue,
               r.Value      AS maxValue,
               CAST(1 AS INT) AS sampleCount,
               CAST(0 AS INT) AS bucketSeconds
        FROM   dbo.Reading AS r
        WHERE  r.DeviceId = @DeviceId
          AND  (@ChannelId IS NULL OR r.ChannelId = @ChannelId)
          AND  r.ObservedAt >= @FromUtc AND r.ObservedAt < @ToUtc
        ORDER BY r.ChannelId, r.ObservedAt;
        RETURN;
    END;

    SELECT   r.ChannelId AS channelId,
             DATEADD(SECOND,
                     (DATEDIFF(SECOND, @FromUtc, r.ObservedAt) / @BucketSeconds) * @BucketSeconds,
                     @FromUtc) AS timestamp,
             AVG(r.Value)   AS value,
             MIN(r.Value)   AS minValue,
             MAX(r.Value)   AS maxValue,
             COUNT_BIG(*)   AS sampleCount,
             @BucketSeconds AS bucketSeconds
    FROM     dbo.Reading AS r
    WHERE    r.DeviceId = @DeviceId
      AND    (@ChannelId IS NULL OR r.ChannelId = @ChannelId)
      AND    r.ObservedAt >= @FromUtc AND r.ObservedAt < @ToUtc
    GROUP BY r.ChannelId,
             DATEADD(SECOND,
                     (DATEDIFF(SECOND, @FromUtc, r.ObservedAt) / @BucketSeconds) * @BucketSeconds,
                     @FromUtc)
    ORDER BY channelId, timestamp;
END;
GO

/* ===========================================================================
   ALERTS - GET /alerts (both global and device-scoped modes)
   Keyset pagination on (BreachedAt DESC, AlertId): OFFSET paging on a feed that
   grows at the head would skip or repeat rows as new alerts arrive.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_GetAlerts
    @DeviceId         NVARCHAR(128) = NULL,
    @Severity         VARCHAR(16)   = NULL,   -- minimum severity
    @ActiveOnly       BIT           = 0,
    @BeforeBreachedAt DATETIME2(3)  = NULL,
    @BeforeAlertId    UNIQUEIDENTIFIER = NULL,
    @Limit            INT           = 50
AS
BEGIN
    SET NOCOUNT ON;

    IF @Limit < 1 OR @Limit > 200 SET @Limit = 50;

    DECLARE @MinRank TINYINT =
        ISNULL((SELECT Rank FROM dbo.Severity WHERE Code = @Severity), 0);

    SELECT TOP (@Limit)
           a.AlertId            AS alertId,
           a.DeviceId           AS deviceId,
           d.Name               AS deviceName,
           a.ChannelId          AS channelId,
           sc.Label             AS channelLabel,
           a.Severity           AS severity,
           a.Message            AS message,
           a.BreachedAt         AS breachedAt,
           a.AcknowledgedAt     AS acknowledgedAt,
           a.AcknowledgedByName AS acknowledgedBy,
           a.ObservedValue      AS observedValue,
           a.ThresholdValue     AS thresholdValue
    FROM   dbo.Alert AS a
    JOIN   dbo.Device AS d ON d.DeviceId = a.DeviceId
    JOIN   dbo.SensorChannel AS sc ON sc.ChannelId = a.ChannelId
    JOIN   dbo.Severity AS sv ON sv.Code = a.Severity
    WHERE  (@DeviceId IS NULL OR a.DeviceId = @DeviceId)
      AND  (@ActiveOnly = 0 OR a.AcknowledgedAt IS NULL)
      AND  sv.Rank >= @MinRank
      AND  (@BeforeBreachedAt IS NULL
            OR a.BreachedAt < @BeforeBreachedAt
            OR (a.BreachedAt = @BeforeBreachedAt AND (@BeforeAlertId IS NULL OR a.AlertId > @BeforeAlertId)))
    ORDER BY a.BreachedAt DESC, a.AlertId;
END;
GO

/* ===========================================================================
   ACKNOWLEDGE - POST /alerts/{alertId}/acknowledge
   Idempotent: acknowledging twice is a no-op that still returns the alert, so a
   double-tap on a flaky mobile connection is not an error the operator sees.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_AcknowledgeAlert
    @AlertId      UNIQUEIDENTIFIER,
    @OperatorId   NVARCHAR(128),
    @OperatorName NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.Alert
    SET    AcknowledgedAt     = SYSUTCDATETIME(),
           AcknowledgedBy     = @OperatorId,
           AcknowledgedByName = @OperatorName
    WHERE  AlertId = @AlertId
      AND  AcknowledgedAt IS NULL;

    SELECT a.AlertId            AS alertId,
           a.DeviceId           AS deviceId,
           d.Name               AS deviceName,
           a.ChannelId          AS channelId,
           sc.Label             AS channelLabel,
           a.Severity           AS severity,
           a.Message            AS message,
           a.BreachedAt         AS breachedAt,
           a.AcknowledgedAt     AS acknowledgedAt,
           a.AcknowledgedByName AS acknowledgedBy,
           a.ObservedValue      AS observedValue,
           a.ThresholdValue     AS thresholdValue
    FROM   dbo.Alert AS a
    JOIN   dbo.Device AS d ON d.DeviceId = a.DeviceId
    JOIN   dbo.SensorChannel AS sc ON sc.ChannelId = a.ChannelId
    WHERE  a.AlertId = @AlertId;
END;
GO

/* ===========================================================================
   ALERT SUMMARY - GET /alerts/summary (notification bell badge)
   "Unread" is per operator via a seen-watermark, so one operator opening the
   bell does not clear everybody else's badge.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_GetAlertSummary
    @OperatorId NVARCHAR(128)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SeenUpTo DATETIME2(3) =
        ISNULL((SELECT SeenUpToUtc FROM dbo.OperatorAlertWatermark WHERE OperatorId = @OperatorId),
               '1900-01-01T00:00:00');

    SELECT COUNT(CASE WHEN a.Severity = 'critical' THEN 1 END) AS unreadCriticalCount,
           COUNT(CASE WHEN a.Severity = 'warning'  THEN 1 END) AS unreadWarningCount,
           COUNT(CASE WHEN a.Severity = 'info'     THEN 1 END) AS unreadInfoCount,
           MAX(a.BreachedAt)                                   AS latestAlertAt
    FROM   dbo.Alert AS a
    WHERE  a.BreachedAt > @SeenUpTo
      AND  a.AcknowledgedAt IS NULL;
END;
GO

/* POST /alerts/seen - bell "opened" output from the UI. */
CREATE OR ALTER PROCEDURE dbo.usp_MarkAlertsSeen
    @OperatorId  NVARCHAR(128),
    @SeenUpToUtc DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @SeenUpToUtc IS NULL SET @SeenUpToUtc = SYSUTCDATETIME();

    /* Never move the watermark backwards - a stale client must not resurrect
       already-seen alerts as unread. */
    MERGE dbo.OperatorAlertWatermark AS t
    USING (SELECT @OperatorId AS OperatorId, @SeenUpToUtc AS SeenUpToUtc) AS s
        ON t.OperatorId = s.OperatorId
    WHEN MATCHED AND t.SeenUpToUtc < s.SeenUpToUtc
        THEN UPDATE SET t.SeenUpToUtc = s.SeenUpToUtc, t.UpdatedAt = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (OperatorId, SeenUpToUtc) VALUES (s.OperatorId, s.SeenUpToUtc);
END;
GO

/* ===========================================================================
   DEVICE STATUS
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_ApplyDeviceConnectionEvent
    @DeviceId NVARCHAR(128),
    @State    VARCHAR(16),          -- connected | disconnected
    @EventAt  DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;

    /* Out-of-order Event Grid deliveries are expected, so an older event never
       overwrites a newer one. */
    UPDATE dbo.Device
    SET    LastConnectionEventState = @State,
           LastConnectionEventAt    = @EventAt,
           LastSeenAt = CASE WHEN @State = 'connected'
                                  AND (LastSeenAt IS NULL OR LastSeenAt < @EventAt)
                             THEN @EventAt ELSE LastSeenAt END
    WHERE  DeviceId = @DeviceId
      AND  (LastConnectionEventAt IS NULL OR LastConnectionEventAt < @EventAt);

    SELECT @@ROWCOUNT AS RowsAffected;
END;
GO

/* Timer-driven sweep. Returns only devices whose status actually flipped, so the
   30s tick does not republish the whole fleet to every connected browser. */
CREATE OR ALTER PROCEDURE dbo.usp_SweepDeviceStatus
    @OfflineAfterSeconds INT = 90
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Cutoff DATETIME2(3) = DATEADD(SECOND, -@OfflineAfterSeconds, SYSUTCDATETIME());
    DECLARE @Changed TABLE
    (
        DeviceId NVARCHAR(128) NOT NULL PRIMARY KEY,
        Status   VARCHAR(16)   NOT NULL
    );

    UPDATE d
    SET    d.LastReportedStatus = x.CurrentStatus
    OUTPUT inserted.DeviceId, inserted.LastReportedStatus INTO @Changed (DeviceId, Status)
    FROM   dbo.Device AS d
    CROSS APPLY (
        SELECT CASE WHEN d.LastSeenAt IS NOT NULL AND d.LastSeenAt >= @Cutoff
                    THEN 'online' ELSE 'offline' END AS CurrentStatus
    ) AS x
    WHERE  d.IsEnabled = 1
      AND  (d.LastReportedStatus IS NULL OR d.LastReportedStatus <> x.CurrentStatus);

    SELECT c.DeviceId   AS deviceId,
           c.Status     AS status,
           d.LastSeenAt AS lastSeenAt
    FROM   @Changed AS c
    JOIN   dbo.Device AS d ON d.DeviceId = c.DeviceId;
END;
GO

/* ===========================================================================
   RETENTION - timer-driven. Batched deletes so a purge never takes a long lock
   on the table the ingest path is writing to.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_PurgeReadings
    @RetentionDays INT = 30,
    @BatchSize     INT = 5000,
    @MaxBatches    INT = 50
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Cutoff DATETIME2(3) = DATEADD(DAY, -@RetentionDays, SYSUTCDATETIME());
    DECLARE @Batches INT = 0, @Deleted INT = 1, @Total BIGINT = 0;

    WHILE @Deleted > 0 AND @Batches < @MaxBatches
    BEGIN
        DELETE TOP (@BatchSize) FROM dbo.Reading WHERE ObservedAt < @Cutoff;
        SET @Deleted = @@ROWCOUNT;
        SET @Total += @Deleted;
        SET @Batches += 1;
    END;

    SELECT @Total AS RowsDeleted, @Batches AS BatchesRun;
END;
GO

/* Channel taxonomy reference - GET /channels */
CREATE OR ALTER PROCEDURE dbo.usp_GetSensorChannels
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ChannelId AS channelId,
           Label     AS label,
           Unit      AS unit,
           UnitUcum  AS unitUcum,
           ValueKind AS valueKind,
           MinValid  AS minValid,
           MaxValid  AS maxValid
    FROM   dbo.SensorChannel
    WHERE  IsActive = 1
    ORDER BY DisplayOrder, ChannelId;
END;
GO
