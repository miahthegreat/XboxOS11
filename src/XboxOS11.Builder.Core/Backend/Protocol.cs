using System.Text.Json;
using XboxOS11.Builder.Core.Models;

namespace XboxOS11.Builder.Core.Backend;

/// <summary>Parses the line-oriented backend protocol (<c>XBOXOS-RESULT</c> / <c>XBOXOS-EVENT</c>).</summary>
public static class Protocol
{
    public const string ResultPrefix = "XBOXOS-RESULT ";
    public const string EventPrefix = "XBOXOS-EVENT ";
    public const string ApiVersion = "xboxos-builder-api-v1";

    public static bool TryParseEvent(string? line, out BuildEvent? buildEvent)
    {
        buildEvent = null;
        if (line is null || !line.StartsWith(EventPrefix, StringComparison.Ordinal))
        {
            return false;
        }

        try
        {
            using var doc = JsonDocument.Parse(line.AsMemory(EventPrefix.Length));
            var root = doc.RootElement.Clone();
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("type", out var type) || type.ValueKind != JsonValueKind.String)
            {
                return false;
            }

            DateTimeOffset? utc = null;
            if (root.TryGetProperty("utc", out var u) && u.ValueKind == JsonValueKind.String && DateTimeOffset.TryParse(u.GetString(), out var parsed))
            {
                utc = parsed;
            }

            buildEvent = new BuildEvent { Type = type.GetString()!, Utc = utc, Raw = root };
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    /// <summary>Finds the single result line in API output and deserializes its <c>data</c> payload.</summary>
    public static T ParseResult<T>(string command, IEnumerable<string> outputLines)
    {
        var resultLines = outputLines.Where(l => l.StartsWith(ResultPrefix, StringComparison.Ordinal)).ToList();
        if (resultLines.Count == 0)
        {
            throw new BackendException($"The backend returned no result for '{command}'.");
        }

        if (resultLines.Count > 1)
        {
            throw new BackendException($"The backend returned {resultLines.Count} results for '{command}'; expected exactly one.");
        }

        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(resultLines[0].AsMemory(ResultPrefix.Length));
        }
        catch (JsonException ex)
        {
            throw new BackendException($"The backend result for '{command}' is not valid JSON.", ex);
        }

        using (doc)
        {
            var root = doc.RootElement;
            if (root.TryGetProperty("apiVersion", out var api) && api.GetString() != ApiVersion)
            {
                throw new BackendException($"Unsupported backend API version '{api.GetString()}'; expected '{ApiVersion}'.");
            }

            var ok = root.TryGetProperty("ok", out var okEl) && okEl.ValueKind == JsonValueKind.True;
            if (!ok)
            {
                var message = root.TryGetProperty("error", out var err) ? err.GetString() : null;
                throw new BackendException(string.IsNullOrWhiteSpace(message) ? $"'{command}' failed." : message!);
            }

            if (!root.TryGetProperty("data", out var data) || data.ValueKind == JsonValueKind.Null)
            {
                throw new BackendException($"The backend result for '{command}' has no data.");
            }

            return data.Deserialize<T>(BuilderJson.Options)
                ?? throw new BackendException($"The backend data for '{command}' could not be read.");
        }
    }
}

public sealed class BackendException : Exception
{
    public BackendException(string message) : base(message) { }
    public BackendException(string message, Exception inner) : base(message, inner) { }
}
