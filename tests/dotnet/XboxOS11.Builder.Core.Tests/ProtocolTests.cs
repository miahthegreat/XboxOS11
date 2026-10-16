using XboxOS11.Builder.Core.Backend;
using XboxOS11.Builder.Core.Models;

namespace XboxOS11.Builder.Core.Tests;

public class ProtocolTests
{
    [Fact]
    public void ParsesPhaseEvents()
    {
        Assert.True(Protocol.TryParseEvent("XBOXOS-EVENT {\"type\":\"phase\",\"utc\":\"2026-10-15T17:42:43Z\",\"name\":\"ExportIso\",\"status\":\"succeeded\",\"seconds\":3}", out var evt));
        Assert.Equal("phase", evt!.Type);
        Assert.Equal("ExportIso", evt.GetString("name"));
        Assert.Equal("succeeded", evt.GetString("status"));
        Assert.NotNull(evt.Utc);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("[Information] Phase succeeded: ExportIso")]
    [InlineData("XBOXOS-EVENT not-json")]
    [InlineData("XBOXOS-EVENT {\"name\":\"no type\"}")]
    [InlineData("xboxos-event {\"type\":\"phase\"}")]
    public void IgnoresNonEventLines(string? line)
    {
        Assert.False(Protocol.TryParseEvent(line, out var evt));
        Assert.Null(evt);
    }

    [Fact]
    public void ReadsStringArraysFromEvents()
    {
        Protocol.TryParseEvent("XBOXOS-EVENT {\"type\":\"validation\",\"valid\":false,\"errors\":[\"a\",\"b\"],\"warnings\":\"single\"}", out var evt);
        Assert.Equal(["a", "b"], evt!.GetStrings("errors"));
        Assert.Equal(["single"], evt.GetStrings("warnings"));
        Assert.False(evt.GetBool("valid"));
        Assert.Empty(evt.GetStrings("missing"));
    }

    [Fact]
    public void ParsesResultDataIgnoringNoise()
    {
        var lines = new[]
        {
            "WARNING: something noisy",
            "XBOXOS-RESULT {\"ok\":true,\"command\":\"validate\",\"apiVersion\":\"xboxos-builder-api-v1\",\"data\":{\"valid\":false,\"errors\":[\"bad\"],\"warnings\":[]}}",
            "trailing",
        };
        var result = Protocol.ParseResult<ValidationResult>("validate", lines);
        Assert.False(result.Valid);
        Assert.Equal(["bad"], result.Errors);
    }

    [Fact]
    public void SurfacesBackendErrors()
    {
        var ex = Assert.Throws<BackendException>(() => Protocol.ParseResult<ValidationResult>("validate",
            ["XBOXOS-RESULT {\"ok\":false,\"command\":\"validate\",\"apiVersion\":\"xboxos-builder-api-v1\",\"error\":\"-ProfilePath is required.\"}"]));
        Assert.Equal("-ProfilePath is required.", ex.Message);
    }

    [Fact]
    public void RejectsMissingDuplicateAndIncompatibleResults()
    {
        Assert.Throws<BackendException>(() => Protocol.ParseResult<ValidationResult>("validate", ["no result here"]));
        var line = "XBOXOS-RESULT {\"ok\":true,\"command\":\"x\",\"apiVersion\":\"xboxos-builder-api-v1\",\"data\":{}}";
        Assert.Throws<BackendException>(() => Protocol.ParseResult<ValidationResult>("validate", [line, line]));
        Assert.Throws<BackendException>(() => Protocol.ParseResult<ValidationResult>("validate",
            ["XBOXOS-RESULT {\"ok\":true,\"command\":\"x\",\"apiVersion\":\"xboxos-builder-api-v9\",\"data\":{}}"]));
        Assert.Throws<BackendException>(() => Protocol.ParseResult<ValidationResult>("validate", ["XBOXOS-RESULT {broken"]));
    }
}
