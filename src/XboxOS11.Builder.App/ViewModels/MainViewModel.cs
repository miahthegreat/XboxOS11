using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;
using System.Security.Principal;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using XboxOS11.Builder.Core.Backend;
using XboxOS11.Builder.Core.Models;
using XboxOS11.Builder.Core.Profiles;

namespace XboxOS11.Builder.App.ViewModels;

public sealed partial class MainViewModel : ObservableObject
{
    private const int MaxLogLines = 3000;

    private static readonly string[] PhaseOrder =
    [
        "ImportSource", "MountImage", "InventoryBefore", "RemoveApps", "DisableFeatures", "AddDrivers",
        "AddUpdates", "InventoryAfter", "DismountCommit", "Validate", "ExportIso",
    ];

    private readonly AppSettingsStore _settings = new();
    private readonly ProfileEditor _editor = new(new BuildProfile());
    private BuilderBackend? _backend;
    private CancellationTokenSource? _buildCts;
    private string? _profilePath;

    public MainViewModel()
    {
        IsElevated = new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
        Languages = CultureInfo.GetCultures(CultureTypes.SpecificCultures)
            .Where(c => !string.IsNullOrEmpty(c.Name))
            .OrderBy(c => c.DisplayName, StringComparer.CurrentCulture)
            .Select(c => new Choice(c.Name, $"{c.DisplayName} ({c.Name})"))
            .ToList();
        TimeZones = TimeZoneInfo.GetSystemTimeZones().Select(t => new Choice(t.Id, t.DisplayName)).ToList();
    }

    public IReadOnlyList<Choice> Languages { get; }
    public IReadOnlyList<Choice> TimeZones { get; }
    public ObservableCollection<PresetItem> Presets { get; } = [];
    public ObservableCollection<ComponentItem> Apps { get; } = [];
    public ObservableCollection<ComponentItem> Features { get; } = [];
    public ObservableCollection<LauncherItem> Launchers { get; } = [];
    public ObservableCollection<string> AlwaysPreserved { get; } = [];
    public ObservableCollection<ImageEdition> Editions { get; } = [];
    public ObservableCollection<string> ValidationErrors { get; } = [];
    public ObservableCollection<string> ValidationWarnings { get; } = [];
    public ObservableCollection<PhaseItem> Phases { get; } = [];
    public ObservableCollection<string> RecentProfiles { get; } = [];
    public ObservableCollection<string> LogLines { get; } = [];

    // ---- Status ---------------------------------------------------------------------------

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsNotBusy))]
    [NotifyCanExecuteChangedFor(nameof(ValidateCommand), nameof(StartBuildCommand), nameof(ReadEditionsCommand), nameof(PreviewUnattendCommand))]
    public partial bool IsBusy { get; set; }

    public bool IsNotBusy => !IsBusy;

    [ObservableProperty]
    public partial bool IsReady { get; set; }

    [ObservableProperty]
    public partial bool IsElevated { get; set; }

    [ObservableProperty]
    public partial string StatusMessage { get; set; } = "Starting…";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasError))]
    public partial string? ErrorMessage { get; set; }

    public bool HasError => !string.IsNullOrEmpty(ErrorMessage);

    [ObservableProperty]
    public partial string BackendDescription { get; set; } = string.Empty;

    [ObservableProperty]
    public partial string ProfileFileName { get; set; } = "Unsaved profile";

    [ObservableProperty]
    public partial bool HasUnsavedChanges { get; set; }

    // ---- Validation / build ----------------------------------------------------------------

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ValidationSummary))]
    public partial bool? IsValid { get; set; }

    public string ValidationSummary => IsValid switch
    {
        true => ValidationWarnings.Count == 0 ? "Ready to build." : $"Ready to build with {ValidationWarnings.Count} warning(s).",
        false => $"{ValidationErrors.Count} problem(s) must be fixed before building.",
        _ => "Not validated yet.",
    };

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsNotBuilding))]
    [NotifyCanExecuteChangedFor(nameof(CancelBuildCommand), nameof(StartBuildCommand))]
    public partial bool IsBuilding { get; set; }

    public bool IsNotBuilding => !IsBuilding;

    [ObservableProperty]
    public partial bool DryRun { get; set; } = true;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(BuildProgressText))]
    public partial double BuildProgress { get; set; }

    public string BuildProgressText => $"{BuildProgress:0}%";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasBuildResult))]
    public partial string? BuildResult { get; set; }

    public bool HasBuildResult => !string.IsNullOrEmpty(BuildResult);

    [ObservableProperty]
    public partial bool BuildSucceeded { get; set; }

    [ObservableProperty]
    public partial string? ResultIsoPath { get; set; }

    [ObservableProperty]
    public partial string UnattendXml { get; set; } = string.Empty;

    [ObservableProperty]
    public partial PresetItem? SelectedPreset { get; set; }

    [ObservableProperty]
    public partial ImageEdition? SelectedEdition { get; set; }

    // ---- Profile-backed properties ---------------------------------------------------------

    private BuildProfile P => _editor.Profile;

    private void Edit(Action<BuildProfile> change, bool marksCustom = true, [System.Runtime.CompilerServices.CallerMemberName] string? name = null)
    {
        _editor.Edit(change, marksCustom);
        OnPropertyChanged(name);
        ProfileEdited();
    }

    public string ProfileName
    {
        get => P.Name;
        set { if (P.Name != value) { Edit(p => p.Name = value, marksCustom: false); OnPropertyChanged(nameof(ProfileNameError)); } }
    }

    public string ProfileNameError => ProfileEditor.IsValidProfileName(P.Name) ? string.Empty : "Use 1-64 letters, digits, spaces, '.', '_' or '-'.";

    public string IsoPath
    {
        get => P.Source.IsoPath;
        set
        {
            if (P.Source.IsoPath == value) { return; }
            Edit(p => { p.Source.IsoPath = value; p.Source.ImageIndex = null; }, marksCustom: false);
            Editions.Clear();
            RefreshIsoDependentCommands();
        }
    }

    public string EditionPattern
    {
        get => P.Source.EditionPattern;
        set { if (P.Source.EditionPattern != value) { Edit(p => p.Source.EditionPattern = value, marksCustom: false); } }
    }

    public string OutputDirectory
    {
        get => P.Output.Directory;
        set { if (P.Output.Directory != value) { Edit(p => p.Output.Directory = value, marksCustom: false); } }
    }

    public string IsoLabel
    {
        get => P.Output.IsoLabel;
        set { if (P.Output.IsoLabel != value) { Edit(p => p.Output.IsoLabel = value, marksCustom: false); OnPropertyChanged(nameof(IsoLabelError)); } }
    }

    public string IsoLabelError => ProfileEditor.IsValidIsoLabel(P.Output.IsoLabel) ? string.Empty : "Use 1-32 letters, digits, or underscores.";

    public bool DriversEnabled
    {
        get => P.Drivers.Enabled;
        set { if (P.Drivers.Enabled != value) { Edit(p => p.Drivers.Enabled = value); } }
    }

    public string DriversDirectory
    {
        get => P.Drivers.Directory;
        set { if (P.Drivers.Directory != value) { Edit(p => p.Drivers.Directory = value); } }
    }

    public bool UpdatesEnabled
    {
        get => P.Updates.Enabled;
        set { if (P.Updates.Enabled != value) { Edit(p => p.Updates.Enabled = value); } }
    }

    public string UpdatesDirectory
    {
        get => P.Updates.Directory;
        set { if (P.Updates.Directory != value) { Edit(p => p.Updates.Directory = value); } }
    }

    public bool Unattend
    {
        get => P.Setup.Unattend;
        set
        {
            if (P.Setup.Unattend == value) { return; }
            _editor.SetUnattend(value);
            RaiseSetupChanged();
        }
    }

    public bool HideEula
    {
        get => P.Setup.HideEula;
        set { if (P.Setup.HideEula != value) { Edit(p => p.Setup.HideEula = value); } }
    }

    public int PrivacyIndex
    {
        get => P.Setup.Privacy == "Recommended" ? 1 : 0;
        set
        {
            var v = value == 1 ? "Recommended" : "Minimal";
            if (P.Setup.Privacy != v) { Edit(p => p.Setup.Privacy = v); }
        }
    }

    public bool StartupToGamingHome
    {
        get => P.Setup.StartupToGamingHome;
        set
        {
            if (P.Setup.StartupToGamingHome == value) { return; }
            _editor.SetStartupToGamingHome(value);
            RaiseSetupChanged();
        }
    }

    public bool PostInstallEnabled
    {
        get => P.Setup.PostInstall.Enabled;
        set
        {
            if (P.Setup.PostInstall.Enabled == value) { return; }
            _editor.SetPostInstall(value);
            RaiseSetupChanged();
        }
    }

    public bool GameMode
    {
        get => P.Setup.PostInstall.GameMode;
        set { if (P.Setup.PostInstall.GameMode != value) { Edit(p => p.Setup.PostInstall.GameMode = value); } }
    }

    public bool HardwareAcceleratedGpuScheduling
    {
        get => P.Setup.PostInstall.HardwareAcceleratedGpuScheduling;
        set { if (P.Setup.PostInstall.HardwareAcceleratedGpuScheduling != value) { Edit(p => p.Setup.PostInstall.HardwareAcceleratedGpuScheduling = value); } }
    }

    public Choice? SelectedLanguage
    {
        get => Languages.FirstOrDefault(c => c.Value == P.Setup.UiLanguage);
        set { if (value is not null && value.Value != P.Setup.UiLanguage) { Edit(p => p.Setup.UiLanguage = value.Value); } }
    }

    public Choice? SelectedLocale
    {
        get => Languages.FirstOrDefault(c => c.Value == P.Setup.UserLocale);
        set
        {
            if (value is null || value.Value == P.Setup.UserLocale) { return; }
            Edit(p => { p.Setup.UserLocale = value.Value; p.Setup.SystemLocale = value.Value; p.Setup.InputLocale = value.Value; });
        }
    }

    public Choice? SelectedTimeZone
    {
        get => TimeZones.FirstOrDefault(c => c.Value == P.Setup.TimeZone);
        set { if (value is not null && value.Value != P.Setup.TimeZone) { Edit(p => p.Setup.TimeZone = value.Value); } }
    }

    public string SummaryText =>
        $"{P.Apps.Remove.Count} app(s) removed · {P.Features.Disable.Count} feature(s) disabled · " +
        $"drivers {(P.Drivers.Enabled ? "on" : "off")} · updates {(P.Updates.Enabled ? "on" : "off")} · " +
        $"unattend {(P.Setup.Unattend ? "on" : "off")} · post-install {(P.Setup.PostInstall.Enabled ? "on" : "off")}";

    public string PresetLabel => Presets.FirstOrDefault(p => p.Id == P.PresetId)?.DisplayName ?? "Custom";

    private void RaiseSetupChanged()
    {
        foreach (var n in new[] { nameof(Unattend), nameof(HideEula), nameof(StartupToGamingHome), nameof(PostInstallEnabled) })
        {
            OnPropertyChanged(n);
        }

        ProfileEdited();
    }

    private void ProfileEdited()
    {
        HasUnsavedChanges = _editor.IsDirty;
        IsValid = null;
        ValidationErrors.Clear();
        ValidationWarnings.Clear();
        OnPropertyChanged(nameof(SummaryText));
        OnPropertyChanged(nameof(PresetLabel));
        if (P.PresetId == ProfileEditor.CustomPresetId && SelectedPreset is not null)
        {
            _suppressPresetApply = true;
            SelectedPreset = null;
            _suppressPresetApply = false;
        }
    }

    // ---- Initialization ------------------------------------------------------------------

    [RelayCommand]
    public async Task InitializeAsync()
    {
        IsBusy = true;
        try
        {
            var settings = _settings.Load();
            var toolkit = ToolkitLocator.Locate(AppContext.BaseDirectory, settings.ToolkitOverride);
            _backend = new BuilderBackend(toolkit);
            BackendDescription = $"Toolkit: {toolkit.Root}  ·  {(toolkit.IsWindowsPowerShell ? "Windows PowerShell 5.1" : "PowerShell 7")}";
            StatusMessage = "Loading presets…";

            var catalog = await _backend.GetCatalogAsync();
            Presets.Clear();
            foreach (var p in catalog.Presets.OrderBy(p => p.Order))
            {
                Presets.Add(new PresetItem { Id = p.Id, DisplayName = p.DisplayName, Description = p.Description, Recommended = p.Recommended });
            }

            Launchers.Clear();
            foreach (var l in catalog.Launchers)
            {
                Launchers.Add(new LauncherItem(l, false, (name, sel) => { _editor.SetLauncher(name, sel); ProfileEdited(); }));
            }

            RecentProfiles.Clear();
            foreach (var r in settings.RecentProfiles.Where(File.Exists))
            {
                RecentProfiles.Add(r);
            }

            var recommended = Presets.FirstOrDefault(p => p.Recommended) ?? Presets.First();
            var profile = await _backend.NewProfileAsync(recommended.Id, "My XboxOS11 build");
            await LoadProfileIntoEditorAsync(profile, path: null);
            IsReady = true;
            StatusMessage = IsElevated ? "Ready." : "Ready. Building an ISO requires running as administrator.";
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            StatusMessage = "The XboxOS11 toolkit could not be loaded.";
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task LoadProfileIntoEditorAsync(BuildProfile profile, string? path)
    {
        _editor.Load(profile);
        var review = await _backend!.ReviewAsync(profile);
        _editor.ApplyReview(review);

        Apps.Clear();
        foreach (var a in review.Apps)
        {
            Apps.Add(new ComponentItem(a.Id, a.DisplayName, a.Reason, a.Protected || !a.Selectable, a.Selected, (id, sel) =>
            {
                var ok = _editor.SetAppRemoved(id, sel);
                ProfileEdited();
                return ok;
            }));
        }

        Features.Clear();
        foreach (var f in review.Features)
        {
            var title = string.Join(", ", f.FeatureNames);
            Features.Add(new ComponentItem(f.Id, f.Id, $"{f.Reason} ({title})", f.Protected || !f.Selectable, f.Selected, (id, sel) =>
            {
                var ok = _editor.SetFeatureDisabled(id, sel);
                ProfileEdited();
                return ok;
            }));
        }

        AlwaysPreserved.Clear();
        foreach (var s in review.AlwaysPreserved)
        {
            AlwaysPreserved.Add(s);
        }

        _profilePath = path;
        ProfileFileName = path is null ? "Unsaved profile" : Path.GetFileName(path);
        SyncFromProfile();
        _editor.MarkSaved();
        HasUnsavedChanges = false;
    }

    /// <summary>Pushes the editor's profile into every bound control and collection.</summary>
    private void SyncFromProfile()
    {
        foreach (var a in Apps)
        {
            a.Sync(P.Apps.Remove.Contains(a.Id, StringComparer.OrdinalIgnoreCase));
        }

        foreach (var f in Features)
        {
            f.Sync(P.Features.Disable.Contains(f.Id, StringComparer.OrdinalIgnoreCase));
        }

        foreach (var l in Launchers)
        {
            l.Sync(P.Setup.PostInstall.Launchers.Contains(l.Name, StringComparer.OrdinalIgnoreCase));
        }

        _suppressPresetApply = true;
        SelectedPreset = Presets.FirstOrDefault(p => p.Id == P.PresetId);
        _suppressPresetApply = false;
        OnPropertyChanged(string.Empty);
        ProfileEdited();
    }

    // ---- Presets -------------------------------------------------------------------------

    private bool _suppressPresetApply;

    partial void OnSelectedPresetChanged(PresetItem? value)
    {
        if (_suppressPresetApply || value is null || _backend is null || value.Id == P.PresetId)
        {
            return;
        }

        _ = ApplyPresetAsync(value);
    }

    private async Task ApplyPresetAsync(PresetItem preset)
    {
        IsBusy = true;
        try
        {
            var template = await _backend!.NewProfileAsync(preset.Id, string.IsNullOrWhiteSpace(P.Name) ? "My XboxOS11 build" : P.Name);
            _editor.ApplyPreset(template);
            SyncFromProfile();
            HasUnsavedChanges = true;
            StatusMessage = $"Applied preset: {preset.DisplayName}";
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    // ---- Source --------------------------------------------------------------------------

    private bool CanReadEditions() => !IsBusy && IsElevated && File.Exists(P.Source.IsoPath);

    [RelayCommand(CanExecute = nameof(CanReadEditions))]
    private async Task ReadEditionsAsync()
    {
        IsBusy = true;
        ErrorMessage = null;
        try
        {
            StatusMessage = "Reading editions from the ISO (read-only)…";
            var info = await _backend!.GetImageInfoAsync(P.Source.IsoPath);
            Editions.Clear();
            foreach (var e in info.Images)
            {
                Editions.Add(e);
            }

            SelectedEdition = Editions.FirstOrDefault(e => e.Name.Equals(P.Source.EditionPattern, StringComparison.OrdinalIgnoreCase))
                ?? Editions.FirstOrDefault(e => e.Name.Equals("Windows 11 Pro", StringComparison.OrdinalIgnoreCase));
            StatusMessage = $"Found {Editions.Count} edition(s) in {info.ImageFile}.";
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    partial void OnSelectedEditionChanged(ImageEdition? value)
    {
        if (value is null)
        {
            return;
        }

        Edit(p => { p.Source.EditionPattern = value.Name; p.Source.ImageIndex = value.Index; }, marksCustom: false, nameof(EditionPattern));
    }

    public void RefreshIsoDependentCommands() => ReadEditionsCommand.NotifyCanExecuteChanged();

    // ---- Validation ----------------------------------------------------------------------

    [RelayCommand(CanExecute = nameof(IsNotBusy))]
    public async Task ValidateAsync()
    {
        IsBusy = true;
        ErrorMessage = null;
        try
        {
            StatusMessage = "Validating…";
            var result = await _backend!.ValidateAsync(P, forBuild: !DryRun);
            ValidationErrors.Clear();
            ValidationWarnings.Clear();
            foreach (var e in result.Errors) { ValidationErrors.Add(e); }
            foreach (var w in result.Warnings) { ValidationWarnings.Add(w); }
            if (string.IsNullOrWhiteSpace(P.Source.IsoPath))
            {
                ValidationErrors.Add("Select a Windows 11 ISO on the Source page.");
            }

            IsValid = ValidationErrors.Count == 0;
            StatusMessage = ValidationSummary;
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    [RelayCommand(CanExecute = nameof(IsNotBusy))]
    private async Task PreviewUnattendAsync()
    {
        try
        {
            UnattendXml = P.Setup.Unattend ? (await _backend!.PreviewUnattendAsync(P)).Xml : "Unattended setup is turned off; Windows Setup will ask every question.";
        }
        catch (Exception ex)
        {
            UnattendXml = ex.Message;
        }
    }

    // ---- Profiles ------------------------------------------------------------------------

    public async Task<bool> SaveProfileAsync(string path)
    {
        ErrorMessage = null;
        try
        {
            var saved = await _backend!.SaveProfileAsync(P, path);
            _profilePath = saved.Path;
            ProfileFileName = Path.GetFileName(saved.Path);
            _editor.MarkSaved();
            HasUnsavedChanges = false;
            AddRecent(saved.Path);
            StatusMessage = $"Saved {ProfileFileName}.";
            return true;
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            return false;
        }
    }

    public string? CurrentProfilePath => _profilePath;

    public async Task OpenProfileAsync(string path)
    {
        IsBusy = true;
        ErrorMessage = null;
        try
        {
            var profile = BuildProfile.FromJson(await File.ReadAllTextAsync(path));
            if (profile.SchemaVersion != BuildProfile.SchemaVersionV1)
            {
                throw new InvalidDataException($"Unsupported profile schema '{profile.SchemaVersion}'.");
            }

            await LoadProfileIntoEditorAsync(profile, path);
            AddRecent(path);
            StatusMessage = $"Opened {Path.GetFileName(path)}.";
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Could not open profile: {ex.Message}";
        }
        finally
        {
            IsBusy = false;
        }
    }

    private void AddRecent(string path)
    {
        var s = _settings.AddRecentProfile(path);
        RecentProfiles.Clear();
        foreach (var r in s.RecentProfiles.Where(File.Exists))
        {
            RecentProfiles.Add(r);
        }
    }

    // ---- Build ---------------------------------------------------------------------------

    private bool CanStartBuild() => !IsBusy && !IsBuilding && _backend is not null && (DryRun || IsElevated);

    partial void OnDryRunChanged(bool value)
    {
        StartBuildCommand.NotifyCanExecuteChanged();
        IsValid = null;
    }

    [RelayCommand(CanExecute = nameof(CanStartBuild))]
    private async Task StartBuildAsync()
    {
        await ValidateAsync();
        if (IsValid != true)
        {
            return;
        }

        ErrorMessage = null;
        BuildResult = null;
        BuildSucceeded = false;
        ResultIsoPath = null;
        LogLines.Clear();
        Phases.Clear();
        foreach (var name in ExpectedPhases())
        {
            Phases.Add(new PhaseItem(name));
        }

        BuildProgress = 0;
        IsBuilding = true;
        _buildCts = new CancellationTokenSource();
        var events = new Progress<BuildEvent>(OnBuildEvent);
        var log = new Progress<string>(AppendLog);
        try
        {
            StatusMessage = DryRun ? "Dry run in progress…" : "Building ISO… this can take 20-60 minutes.";
            var outcome = await _backend!.RunBuildAsync(P, DryRun, events, log, _buildCts.Token);
            BuildSucceeded = outcome.Succeeded;
            ResultIsoPath = outcome.IsoPath;
            BuildResult = outcome.Succeeded
                ? (DryRun ? "Dry run completed. No image was modified." : $"ISO created: {outcome.IsoPath ?? P.Output.Directory}")
                : outcome.InvalidProfile ? "The profile was rejected. See validation errors." : $"Build failed (exit code {outcome.ExitCode}). See the log for details.";
            if (outcome.Succeeded)
            {
                BuildProgress = 100;
            }
        }
        catch (OperationCanceledException)
        {
            BuildResult = "Build cancelled. Mounted images are discarded; nothing was committed.";
        }
        catch (Exception ex)
        {
            BuildResult = $"Build failed: {ex.Message}";
        }
        finally
        {
            IsBuilding = false;
            _buildCts.Dispose();
            _buildCts = null;
            StatusMessage = BuildResult ?? "Build finished.";
        }
    }

    private IEnumerable<string> ExpectedPhases() => PhaseOrder.Where(n => n switch
    {
        "RemoveApps" => P.Apps.Remove.Count > 0,
        "DisableFeatures" => P.Features.Disable.Count > 0,
        "AddDrivers" => P.Drivers.Enabled,
        "AddUpdates" => P.Updates.Enabled,
        "DismountCommit" => !DryRun,
        _ => true,
    });

    private bool CanCancelBuild() => IsBuilding;

    [RelayCommand(CanExecute = nameof(CanCancelBuild))]
    private void CancelBuild() => _buildCts?.Cancel();

    private void OnBuildEvent(BuildEvent e)
    {
        switch (e.Type)
        {
            case "phase":
                var name = e.GetString("name") ?? "?";
                var phase = Phases.FirstOrDefault(p => p.Name == name);
                if (phase is null)
                {
                    phase = new PhaseItem(name);
                    Phases.Add(phase);
                }

                phase.State = e.GetString("status") switch
                {
                    "started" => PhaseState.Running,
                    "succeeded" => PhaseState.Succeeded,
                    "failed" => PhaseState.Failed,
                    _ => phase.State,
                };
                phase.Detail = e.GetString("message") ?? string.Empty;
                BuildProgress = Phases.Count == 0 ? 0 : 100.0 * Phases.Count(p => p.State == PhaseState.Succeeded) / Phases.Count;
                StatusMessage = $"{phase.DisplayName}…";
                break;
            case "validation":
                foreach (var w in e.GetStrings("warnings").Where(w => !ValidationWarnings.Contains(w)))
                {
                    ValidationWarnings.Add(w);
                }

                break;
            case "failed":
                AppendLog("FAILED: " + (e.GetString("message") ?? "unknown error"));
                break;
            case "log":
                AppendLog(e.GetString("message") ?? string.Empty);
                break;
        }
    }

    private void AppendLog(string line)
    {
        LogLines.Add(line);
        while (LogLines.Count > MaxLogLines)
        {
            LogLines.RemoveAt(0);
        }
    }

    [RelayCommand]
    private void OpenOutputFolder()
    {
        var dir = P.Output.Directory;
        if (Directory.Exists(dir))
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{dir}\"") { UseShellExecute = true });
        }
    }

    [RelayCommand]
    private void OpenLogsFolder()
    {
        const string logs = @"C:\XboxOS\Logs";
        if (Directory.Exists(logs))
        {
            Process.Start(new ProcessStartInfo("explorer.exe", logs) { UseShellExecute = true });
        }
    }

    /// <summary>Relaunches elevated. Returns false if the user declined the UAC prompt.</summary>
    public bool RestartElevated()
    {
        try
        {
            Process.Start(new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = true, Verb = "runas" });
            return true;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    [RelayCommand]
    private void DismissError() => ErrorMessage = null;
}
