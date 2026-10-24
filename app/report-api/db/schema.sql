-- Report API database: one table + sample rows.
-- Safe to run more than once: it does nothing if the table already exists.
-- (The app also creates this on first call to /reports, so this script is optional.)

IF OBJECT_ID('dbo.Reports') IS NULL
BEGIN
    CREATE TABLE dbo.Reports (
        Id        INT IDENTITY PRIMARY KEY,
        Title     NVARCHAR(100)  NOT NULL,
        Amount    DECIMAL(12,2)  NOT NULL,
        CreatedAt DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME()
    );

    INSERT dbo.Reports (Title, Amount) VALUES
        (N'Q3 revenue',       125000.00),
        (N'Q3 refunds',         4200.50),
        (N'Active patients',    1834.00),
        (N'Open invoices',     18750.25),
        (N'Avg claim value',     312.40);
END
GO

SELECT * FROM dbo.Reports;
