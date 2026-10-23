/* ===========================================================================
   002_reference_data.sql

   Resolves UI-stage open question #1: the sensor channel taxonomy for
   industrial dosing devices. This file IS the taxonomy definition; the OpenAPI
   contract documents it and GET /channels serves it.

   Idempotent (MERGE), so re-running a deployment never duplicates or silently
   drops operator-edited thresholds.

   Unicode symbols are built with NCHAR() instead of literals so the file
   survives any code page the deployment agent happens to use.
   =========================================================================== */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* --------------------------------------------------------------------------- */
/* Severity                                                                    */
/* --------------------------------------------------------------------------- */
MERGE dbo.Severity AS target
USING (VALUES
    ('info',     1, N'Info'),
    ('warning',  2, N'Warning'),
    ('critical', 3, N'Critical')
) AS source (Code, Rank, Label)
    ON target.Code = source.Code
WHEN MATCHED AND (target.Rank <> source.Rank OR target.Label <> source.Label)
    THEN UPDATE SET target.Rank = source.Rank, target.Label = source.Label
WHEN NOT MATCHED BY TARGET
    THEN INSERT (Code, Rank, Label) VALUES (source.Code, source.Rank, source.Label);
GO

/* --------------------------------------------------------------------------- */
/* Sensor channels                                                             */
/*                                                                             */
/* Scope decision: nine channels covering the dosing-skid signals an operator   */
/* needs to answer "is it dosing, is it dosing correctly, and will it keep      */
/* dosing". Deliberately excluded: firmware/diagnostic counters (non-goal in    */
/* the product spec) and derived KPIs (computable client-side from these).      */
/*                                                                             */
/* MinValid/MaxValid are physical-plausibility bounds, NOT alert thresholds.    */
/* Out-of-bounds values are rejected at ingest as sensor faults so a wild       */
/* reading cannot rescale the chart or trip a false critical alert.             */
/* --------------------------------------------------------------------------- */
DECLARE @deg NVARCHAR(2) = NCHAR(176);  -- degree sign
DECLARE @mu  NVARCHAR(2) = NCHAR(181);  -- micro sign

MERGE dbo.SensorChannel AS target
USING (VALUES
    -- ChannelId,            Label,                    Unit,                  UnitUcum,  ValueKind,     Min,   Max,      Order
    ('flow_rate',            N'Flow Rate',             N'L/min',              'L/min',   'instant',        0.0,    500.0,  10),
    ('dose_volume_total',    N'Dose Volume (Total)',   N'L',                  'L',       'cumulative',     0.0, 1.0E9,     20),
    ('pump_pressure',        N'Pump Pressure',         N'bar',                'bar',     'instant',        0.0,     25.0,  30),
    ('tank_level',           N'Tank Level',            N'%',                  '%',       'instant',        0.0,    100.0,  40),
    ('ph',                   N'pH',                    N'pH',                 '[pH]',    'instant',        0.0,     14.0,  50),
    ('conductivity',         N'Conductivity',          @mu + N'S/cm',         'uS/cm',   'instant',        0.0, 200000.0,  60),
    ('fluid_temperature',    N'Fluid Temperature',     @deg + N'C',           'Cel',     'instant',      -20.0,    150.0,  70),
    ('motor_current',        N'Motor Current',         N'A',                  'A',       'instant',        0.0,     50.0,  80),
    ('battery_level',        N'Battery Level',         N'%',                  '%',       'instant',        0.0,    100.0,  90)
) AS source (ChannelId, Label, Unit, UnitUcum, ValueKind, MinValid, MaxValid, DisplayOrder)
    ON target.ChannelId = source.ChannelId
WHEN MATCHED THEN UPDATE SET
    target.Label        = source.Label,
    target.Unit         = source.Unit,
    target.UnitUcum     = source.UnitUcum,
    target.ValueKind    = source.ValueKind,
    target.MinValid     = source.MinValid,
    target.MaxValid     = source.MaxValid,
    target.DisplayOrder = source.DisplayOrder,
    target.IsActive     = 1
WHEN NOT MATCHED BY TARGET THEN
    INSERT (ChannelId, Label, Unit, UnitUcum, ValueKind, MinValid, MaxValid, DisplayOrder, IsActive)
    VALUES (source.ChannelId, source.Label, source.Unit, source.UnitUcum, source.ValueKind,
            source.MinValid, source.MaxValid, source.DisplayOrder, 1);
GO

/* --------------------------------------------------------------------------- */
/* Fleet-default alert rules (DeviceId IS NULL).                               */
/*                                                                             */
/* These are engineering defaults, not process-validated setpoints. They exist  */
/* so acceptance criterion 3 is demonstrable end to end on day one; the plant   */
/* process owner is expected to tune them per device afterwards (per-device     */
/* rows override the fleet default for the same channel + severity).            */
/*                                                                             */
/* {value} and {unit} in MessageTemplate are substituted by the ingest          */
/* Function so Alert.message is fully backend-composed, as the UI contract      */
/* requires.                                                                   */
/* --------------------------------------------------------------------------- */
MERGE dbo.AlertRule AS target
USING (VALUES
    -- ChannelId,          Comparison,      Low,   High,  Severity,    DebounceSec, MessageTemplate
    ('tank_level',         'lt',            15.0,  NULL,  'warning',   900,  N'Tank level low ({value}{unit})'),
    ('tank_level',         'lt',             5.0,  NULL,  'critical',  300,  N'Tank nearly empty ({value}{unit}) - dosing will stop'),
    ('pump_pressure',      'gt',            NULL,  18.0,  'warning',   300,  N'Pump pressure high ({value} {unit})'),
    ('pump_pressure',      'gt',            NULL,  22.0,  'critical',  120,  N'Pump pressure critical ({value} {unit}) - possible blockage'),
    ('flow_rate',          'lt',             0.5,  NULL,  'warning',   300,  N'No flow detected ({value} {unit})'),
    ('ph',                 'outside_range',  6.5,   8.5,  'warning',   600,  N'pH out of target band ({value})'),
    ('ph',                 'outside_range',  5.5,   9.5,  'critical',  300,  N'pH critically out of range ({value})'),
    ('fluid_temperature',  'gt',            NULL,  60.0,  'warning',   600,  N'Fluid temperature high ({value}{unit})'),
    ('motor_current',      'gt',            NULL,  40.0,  'critical',  120,  N'Motor current critical ({value} {unit}) - risk of pump damage'),
    ('battery_level',      'lt',            20.0,  NULL,  'warning',  3600,  N'Battery low ({value}{unit})'),
    ('battery_level',      'lt',            10.0,  NULL,  'critical', 1800,  N'Battery critical ({value}{unit}) - device may go offline')
) AS source (ChannelId, Comparison, ThresholdLow, ThresholdHigh, Severity, DebounceSeconds, MessageTemplate)
    ON  target.DeviceId IS NULL
    AND target.ChannelId = source.ChannelId
    AND target.Severity  = source.Severity
WHEN MATCHED THEN UPDATE SET
    target.Comparison      = source.Comparison,
    target.ThresholdLow    = source.ThresholdLow,
    target.ThresholdHigh   = source.ThresholdHigh,
    target.DebounceSeconds = source.DebounceSeconds,
    target.MessageTemplate = source.MessageTemplate
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DeviceId, ChannelId, Comparison, ThresholdLow, ThresholdHigh, Severity, MessageTemplate, DebounceSeconds, IsEnabled)
    VALUES (NULL, source.ChannelId, source.Comparison, source.ThresholdLow, source.ThresholdHigh,
            source.Severity, source.MessageTemplate, source.DebounceSeconds, 1);
GO
