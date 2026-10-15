using CommunityToolkit.Mvvm.ComponentModel;

namespace XboxOS11.Builder.App.ViewModels;

/// <summary>A removable app or disable-able feature. Protected items render locked and cannot be selected.</summary>
public sealed partial class ComponentItem : ObservableObject
{
    private readonly Func<string, bool, bool> _apply;
    private bool _isSelected;

    public ComponentItem(string id, string title, string description, bool isProtected, bool isSelected, Func<string, bool, bool> apply)
    {
        Id = id;
        Title = title;
        Description = description;
        IsProtected = isProtected;
        _isSelected = isSelected && !isProtected;
        _apply = apply;
    }

    public string Id { get; }
    public string Title { get; }
    public string Description { get; }
    public bool IsProtected { get; }
    public bool IsEnabled => !IsProtected;
    public string ProtectionText => IsProtected ? "Protected: required by Store, Xbox, or gaming services" : string.Empty;

    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (_isSelected == value)
            {
                return;
            }

            if (_apply(Id, value))
            {
                _isSelected = value;
            }

            OnPropertyChanged();
        }
    }

    internal void Sync(bool selected)
    {
        if (_isSelected != selected)
        {
            _isSelected = selected;
            OnPropertyChanged(nameof(IsSelected));
        }
    }
}

public sealed partial class LauncherItem : ObservableObject
{
    private readonly Action<string, bool> _apply;
    private bool _isSelected;

    public LauncherItem(string name, bool selected, Action<string, bool> apply)
    {
        Name = name;
        _isSelected = selected;
        _apply = apply;
    }

    public string Name { get; }

    public string DisplayName => Name switch
    {
        "BattleNet" => "Battle.net",
        "EA" => "EA app",
        "Ubisoft" => "Ubisoft Connect",
        "Epic" => "Epic Games Launcher",
        "Xbox" => "Xbox app",
        _ => Name,
    };

    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (SetProperty(ref _isSelected, value))
            {
                _apply(Name, value);
            }
        }
    }

    internal void Sync(bool selected) => SetProperty(ref _isSelected, selected, nameof(IsSelected));
}

public sealed partial class OptimizationItem : ObservableObject
{
    private readonly Action<string, bool> _apply;
    private bool _isSelected;

    public OptimizationItem(string id, string title, string description, string settingsPage, bool requiresRestart, bool selected, Action<string, bool> apply)
    {
        Id = id;
        Title = title;
        Description = description;
        Detail = requiresRestart ? $"{settingsPage} - restart required" : settingsPage;
        _isSelected = selected;
        _apply = apply;
    }

    public string Id { get; }
    public string Title { get; }
    public string Description { get; }
    public string Detail { get; }

    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (SetProperty(ref _isSelected, value))
            {
                _apply(Id, value);
            }
        }
    }

    internal void Sync(bool selected) => SetProperty(ref _isSelected, selected, nameof(IsSelected));
}

public sealed class PresetItem
{
    public required string Id { get; init; }
    public required string DisplayName { get; init; }
    public required string Description { get; init; }
    public bool Recommended { get; init; }
}

public enum PhaseState
{
    Pending,
    Running,
    Succeeded,
    Failed,
}

public sealed partial class PhaseItem : ObservableObject
{
    public PhaseItem(string name) => Name = name;

    public string Name { get; }

    public string DisplayName => Name switch
    {
        "ImportSource" => "Import source ISO",
        "MountImage" => "Mount Windows image",
        "InventoryBefore" => "Inventory (before)",
        "RemoveApps" => "Remove selected apps",
        "DisableFeatures" => "Disable selected features",
        "AddDrivers" => "Integrate drivers",
        "AddUpdates" => "Integrate updates",
        "InventoryAfter" => "Inventory (after)",
        "DismountCommit" => "Save image changes",
        "Validate" => "Validate image",
        "ExportIso" => "Create bootable ISO",
        _ => Name,
    };

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Glyph))]
    public partial PhaseState State { get; set; }

    [ObservableProperty]
    public partial string Detail { get; set; } = string.Empty;

    public string Glyph => State switch
    {
        PhaseState.Running => "",
        PhaseState.Succeeded => "",
        PhaseState.Failed => "",
        _ => "",
    };
}

public sealed record Choice(string Value, string Label)
{
    public override string ToString() => Label;
}
