/* ===========================================================================
   001_schema.sql - Device Telemetry Dashboard relational schema
   Idempotent. Run with: infra/scripts/bootstrap-sql.sh (sqlcmd -I -f 65001)
   Owner: platform-architect (Agent B). Agent C must not hand-edit deployed
   objects; add a new numbered migration instead.
   =========================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---------------------------------------------------------------------------
   Reference: alert severity. A table rather than a CHECK constraint because the
   UI needs a stable *ordering* (highestActiveSeverity) and an enum cannot be
   ordered in SQL without duplicating a CASE expression in every query.
   --------------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.Severity', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Severity
    (
        Code      VARCHAR(16)  NOT NULL CONSTRAINT PK_Severity PRIMARY KEY,
        Rank      TINYINT      NOT NULL,
        Label     NVARCHAR(32) NOT NULL,
        CONSTRAINT UQ_Severity_Rank UNIQUE (Rank)
    );
END;
GO

/* ---------------------------------------------------------------------------
   Reference: sensor channel taxonomy.
   This table is the answer to the UI stage's open question #1. The UI stays
   generic (channelId/label/unit) and this table is the single source of truth,
   so adding a channel is a data change, not a code or contract change.
   --------------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.SensorChannel', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.SensorChannel
    (
        ChannelId   VARCHAR(64)   NOT NULL CONSTRAINT PK_SensorChannel PRIMARY KEY,
        Label       NVARCHAR(64)  NOT NULL,   -- display name, e.g. "Flow Rate"
        Unit        NVARCHAR(16)  NOT NULL,   -- display unit, e.g. "L/min"
        UnitUcum    VARCHAR(16)   NOT NULL,   -- machine-comparable unit code
        ValueKind   VARCHAR(16)   NOT NULL,   -- instant | cumulative
        MinValid    FLOAT         NULL,       -- physically implausible below this
        MaxValid    FLOAT         NULL,       -- physically implausible above this
        DisplayOrder SMALLINT     NOT NULL CONSTRAINT DF_SensorChannel_Order DEFAULT 100,
        IsActive    BIT           NOT NULL CONSTRAINT DF_SensorChannel_IsActive DEFAULT 1,
        CONSTRAINT CK_SensorChannel_ValueKind CHECK (ValueKind IN ('instant', 'cumulative'))
    );
END;
GO

IF OBJECT_ID(N'dbo.Device', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Device
    (
        DeviceId        NVARCHAR(128) NOT NULL CONSTRAINT PK_Device PRIMARY KEY,
        Name            NVARCHAR(128) NOT NULL,
        Location        NVARCHAR(200) NULL,
        -- X.509 subject/thumbprint of the per-device certificate (criterion 5).
        -- Recorded for audit only; IoT Hub is the authority on authentication.
        CertThumbprint  VARCHAR(128)  NULL,
        LastSeenAt      DATETIME2(3)  NULL,
        -- Set by the Event Grid connection-state handler. Advisory only: the
        -- LastSeenAt heartbeat is authoritative for online/offline because
        -- connection-state events are not ordering-guaranteed.
        LastConnectionEventAt    DATETIME2(3) NULL,
        LastConnectionEventState VARCHAR(16)  NULL,
        -- Last online/offline value we actually pushed to clients. Stored so the
        -- sweep job can publish only genuine transitions instead of re-announcing
        -- the same status every 30 seconds.
        LastReportedStatus VARCHAR(16) NULL,
        IsEnabled       BIT           NOT NULL CONSTRAINT DF_Device_IsEnabled DEFAULT 1,
        CreatedAt       DATETIME2(3)  NOT NULL CONSTRAINT DF_Device_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT CK_Device_ConnState CHECK (LastConnectionEventState IN ('connected', 'disconnected'))
    );

    -- Device list is sorted by name and filtered by status; covering the sort
    -- avoids a sort operator on the hottest page in the app.
    CREATE NONCLUSTERED INDEX IX_Device_Name ON dbo.Device (Name) INCLUDE (LastSeenAt, IsEnabled);
END;
GO

/* Which channels a given device actually reports. Lets DeviceDetail.channels[]
   be per-device instead of "every channel in the fleet". */
IF OBJECT_ID(N'dbo.DeviceChannel', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DeviceChannel
    (
        DeviceId  NVARCHAR(128) NOT NULL,
        ChannelId VARCHAR(64)   NOT NULL,
        CONSTRAINT PK_DeviceChannel PRIMARY KEY (DeviceId, ChannelId),
        CONSTRAINT FK_DeviceChannel_Device  FOREIGN KEY (DeviceId)  REFERENCES dbo.Device (DeviceId) ON DELETE CASCADE,
        CONSTRAINT FK_DeviceChannel_Channel FOREIGN KEY (ChannelId) REFERENCES dbo.SensorChannel (ChannelId)
    );
END;
GO

/* ---------------------------------------------------------------------------
   Readings. Highest-volume table in the system.

   Design notes (trade-offs in ADR-001):
   - Clustered PK (DeviceId, ChannelId, ObservedAt DESC) makes the only read
     pattern that matters - "last 24h for one device+channel" - a single
     ordered range seek, and makes newest-first paging free.
   - Rowstore, not clustered columnstore: writes arrive as many small batches
     and reads are narrow 24h ranges, which is the pattern columnstore is worst
     at. Revisit if we ever add fleet-wide analytical queries.
   - The PK doubles as the idempotency key: IoT Hub delivers at-least-once, so
     a redelivered event must not create a duplicate point on the chart.
   --------------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.Reading', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Reading
    (
        DeviceId   NVARCHAR(128) NOT NULL,
        ChannelId  VARCHAR(64)   NOT NULL,
        ObservedAt DATETIME2(3)  NOT NULL,   -- device clock, UTC
        Value      FLOAT         NOT NULL,
        IngestedAt DATETIME2(3)  NOT NULL CONSTRAINT DF_Reading_IngestedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_Reading PRIMARY KEY CLUSTERED (DeviceId, ChannelId, ObservedAt DESC)
    );
END;
GO

/* Threshold definitions. A NULL DeviceId means "fleet default", so onboarding a
   device gets sane alerting without per-device configuration. */
IF OBJECT_ID(N'dbo.AlertRule', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.AlertRule
    (
        RuleId          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AlertRule PRIMARY KEY,
        DeviceId        NVARCHAR(128) NULL,          -- NULL = applies to all devices
        ChannelId       VARCHAR(64)   NOT NULL,
        Comparison      VARCHAR(16)   NOT NULL,      -- gt | lt | outside_range
        ThresholdLow    FLOAT         NULL,
        ThresholdHigh   FLOAT         NULL,
        Severity        VARCHAR(16)   NOT NULL,
        MessageTemplate NVARCHAR(200) NOT NULL,
        -- Suppression window: prevents a sensor oscillating around a threshold
        -- from generating hundreds of alerts and drowning the operator.
        DebounceSeconds INT           NOT NULL CONSTRAINT DF_AlertRule_Debounce DEFAULT 300,
        IsEnabled       BIT           NOT NULL CONSTRAINT DF_AlertRule_IsEnabled DEFAULT 1,
        CONSTRAINT FK_AlertRule_Channel  FOREIGN KEY (ChannelId) REFERENCES dbo.SensorChannel (ChannelId),
        CONSTRAINT FK_AlertRule_Severity FOREIGN KEY (Severity)  REFERENCES dbo.Severity (Code),
        CONSTRAINT FK_AlertRule_Device   FOREIGN KEY (DeviceId)  REFERENCES dbo.Device (DeviceId) ON DELETE CASCADE,
        CONSTRAINT CK_AlertRule_Comparison CHECK (Comparison IN ('gt', 'lt', 'outside_range')),
        CONSTRAINT CK_AlertRule_Thresholds CHECK (
            (Comparison = 'gt'            AND ThresholdHigh IS NOT NULL)
         OR (Comparison = 'lt'            AND ThresholdLow  IS NOT NULL)
         OR (Comparison = 'outside_range' AND ThresholdLow IS NOT NULL AND ThresholdHigh IS NOT NULL)
        )
    );

    CREATE NONCLUSTERED INDEX IX_AlertRule_Lookup
        ON dbo.AlertRule (ChannelId, IsEnabled) INCLUDE (DeviceId, Comparison, ThresholdLow, ThresholdHigh, Severity);
END;
GO

IF OBJECT_ID(N'dbo.Alert', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Alert
    (
        AlertId        UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Alert_AlertId DEFAULT NEWID(),
        DeviceId       NVARCHAR(128) NOT NULL,
        ChannelId      VARCHAR(64)   NOT NULL,
        RuleId         INT           NULL,          -- NULL if the rule was later deleted
        Severity       VARCHAR(16)   NOT NULL,
        Message        NVARCHAR(400) NOT NULL,
        ObservedValue  FLOAT         NOT NULL,
        ThresholdValue FLOAT         NULL,
        BreachedAt     DATETIME2(3)  NOT NULL,      -- device observation time
        RaisedAt       DATETIME2(3)  NOT NULL CONSTRAINT DF_Alert_RaisedAt DEFAULT SYSUTCDATETIME(),
        AcknowledgedAt DATETIME2(3)  NULL,
        AcknowledgedBy NVARCHAR(128) NULL,          -- Entra object id
        AcknowledgedByName NVARCHAR(200) NULL,      -- display name, denormalised for the UI
        -- Clustered newest-first: the global alert feed and the bell dropdown
        -- both want "most recent N across all devices".
        CONSTRAINT PK_Alert PRIMARY KEY NONCLUSTERED (AlertId),
        CONSTRAINT FK_Alert_Device   FOREIGN KEY (DeviceId)  REFERENCES dbo.Device (DeviceId) ON DELETE CASCADE,
        CONSTRAINT FK_Alert_Channel  FOREIGN KEY (ChannelId) REFERENCES dbo.SensorChannel (ChannelId),
        CONSTRAINT FK_Alert_Severity FOREIGN KEY (Severity)  REFERENCES dbo.Severity (Code)
    );

    CREATE CLUSTERED INDEX IX_Alert_BreachedAt ON dbo.Alert (BreachedAt DESC, AlertId);

    CREATE NONCLUSTERED INDEX IX_Alert_Device_BreachedAt
        ON dbo.Alert (DeviceId, BreachedAt DESC) INCLUDE (Severity, AcknowledgedAt, ChannelId);

    -- Filtered index: "active alerts" (the device-list badge counts) is by far
    -- the most frequent alert query and is a tiny subset of the table.
    CREATE NONCLUSTERED INDEX IX_Alert_Active
        ON dbo.Alert (DeviceId, Severity) INCLUDE (BreachedAt) WHERE AcknowledgedAt IS NULL;
END;
GO

/* Per-operator "seen" watermark powering NotificationBell.unreadCriticalCount.
   Per-operator, not global: one operator acknowledging must not blank another
   operator's badge. */
IF OBJECT_ID(N'dbo.OperatorAlertWatermark', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.OperatorAlertWatermark
    (
        OperatorId  NVARCHAR(128) NOT NULL CONSTRAINT PK_OperatorAlertWatermark PRIMARY KEY,
        SeenUpToUtc DATETIME2(3)  NOT NULL,
        UpdatedAt   DATETIME2(3)  NOT NULL CONSTRAINT DF_OperatorWatermark_UpdatedAt DEFAULT SYSUTCDATETIME()
    );
END;
GO

/* Table-valued parameter for batched reading inserts. One round trip per event
   batch instead of one per reading - the difference between comfortably meeting
   the 30s alert budget and not. */
IF TYPE_ID(N'dbo.ReadingTvp') IS NULL
BEGIN
    CREATE TYPE dbo.ReadingTvp AS TABLE
    (
        DeviceId   NVARCHAR(128) NOT NULL,
        ChannelId  VARCHAR(64)   NOT NULL,
        ObservedAt DATETIME2(3)  NOT NULL,
        Value      FLOAT         NOT NULL,
        PRIMARY KEY (DeviceId, ChannelId, ObservedAt)
    );
END;
GO
