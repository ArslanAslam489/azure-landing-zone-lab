using System.Net;
using Microsoft.Data.SqlClient;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(o => { o.SingleLine = true; o.TimestampFormat = "HH:mm:ss "; });
builder.Services.AddHostedService<ReportProbe>();
var app = builder.Build();

// Liveness/readiness: the process is up. Deliberately does NOT touch the DB.
app.MapGet("/healthz", () => Results.Ok("ok"));

// What does the SQL hostname resolve to from inside this pod? (public vs 10.x private IP)
app.MapGet("/dns", async () =>
{
    var addrs = await Dns.GetHostAddressesAsync(Db.Server);
    return Results.Ok(new { host = Db.Server, addresses = addrs.Select(a => a.ToString()) });
});

app.MapGet("/reports", async () =>
{
    try
    {
        await using var conn = await Db.OpenAsync();
        await Db.EnsureSeededAsync(conn);
        await using var cmd = new SqlCommand("SELECT Id, Title, Amount, CreatedAt FROM dbo.Reports ORDER BY Id", conn);
        await using var r = await cmd.ExecuteReaderAsync();
        var rows = new List<object>();
        while (await r.ReadAsync())
            rows.Add(new { id = r.GetInt32(0), title = r.GetString(1), amount = r.GetDecimal(2), createdAt = r.GetDateTime(3) });
        return Results.Ok(rows);
    }
    catch (SqlException ex)
    {
        return Results.Problem(ex.Message, statusCode: 503);
    }
});

app.MapGet("/reports/{id:int}", async (int id) =>
{
    try
    {
        await using var conn = await Db.OpenAsync();
        await Db.EnsureSeededAsync(conn);
        await using var cmd = new SqlCommand("SELECT Id, Title, Amount, CreatedAt FROM dbo.Reports WHERE Id = @id", conn);
        cmd.Parameters.AddWithValue("@id", id);
        await using var r = await cmd.ExecuteReaderAsync();
        if (!await r.ReadAsync()) return Results.NotFound();
        return Results.Ok(new { id = r.GetInt32(0), title = r.GetString(1), amount = r.GetDecimal(2), createdAt = r.GetDateTime(3) });
    }
    catch (SqlException ex)
    {
        return Results.Problem(ex.Message, statusCode: 503);
    }
});

app.Run();

static class Db
{
    // Same env vars as the sql-conn Kubernetes Secret.
    public static string Server => Env("SQL_SERVER");

    static string ConnectionString => new SqlConnectionStringBuilder
    {
        DataSource = $"tcp:{Server},1433",
        InitialCatalog = Environment.GetEnvironmentVariable("SQL_DB") ?? "appdb",
        UserID = Env("SQL_USER"),
        Password = Env("SQL_PASSWORD"),
        Encrypt = true,
        TrustServerCertificate = false,
        ConnectTimeout = 30, // serverless DB may be resuming from auto-pause
    }.ConnectionString;

    static bool _seeded;

    public static async Task<SqlConnection> OpenAsync(CancellationToken ct = default)
    {
        var conn = new SqlConnection(ConnectionString);
        await conn.OpenAsync(ct);
        return conn;
    }

    public static async Task EnsureSeededAsync(SqlConnection conn)
    {
        if (_seeded) return;
        const string sql = """
            IF OBJECT_ID('dbo.Reports') IS NULL
            BEGIN
                CREATE TABLE dbo.Reports (
                    Id INT IDENTITY PRIMARY KEY,
                    Title NVARCHAR(100) NOT NULL,
                    Amount DECIMAL(12,2) NOT NULL,
                    CreatedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME());
                INSERT dbo.Reports (Title, Amount) VALUES
                    (N'Q3 revenue', 125000.00),
                    (N'Q3 refunds', 4200.50),
                    (N'Active patients', 1834);
            END
            """;
        await using var cmd = new SqlCommand(sql, conn);
        await cmd.ExecuteNonQueryAsync();
        _seeded = true;
    }

    static string Env(string name) =>
        Environment.GetEnvironmentVariable(name) ?? throw new InvalidOperationException($"Missing env var {name}");
}

// Logs "report OK" / "report FAILED: ..." every 20s, same as the lab's sqlcmd report-app,
// so `kubectl logs` shows the moment connectivity breaks or recovers.
class ReportProbe(ILogger<ReportProbe> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await using var conn = await Db.OpenAsync(ct);
                await using var cmd = new SqlCommand("SELECT 1", conn);
                await cmd.ExecuteScalarAsync(ct);
                log.LogInformation("report OK");
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                log.LogWarning("report FAILED: {Error}", ex.Message.ReplaceLineEndings(" "));
            }
            await Task.Delay(TimeSpan.FromSeconds(20), ct);
        }
    }
}
