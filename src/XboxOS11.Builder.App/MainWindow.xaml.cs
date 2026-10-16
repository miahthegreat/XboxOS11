using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Windows.Storage.Pickers;
using XboxOS11.Builder.App.ViewModels;
using XboxOS11.Builder.App.Views;

namespace XboxOS11.Builder.App;

public sealed partial class MainWindow : Window
{
    private readonly Dictionary<string, UserControl> _pages = new();

    public MainWindow()
    {
        InitializeComponent();
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "XboxOS11.ico"));
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(1180 * scale), (int)(820 * scale)));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)(900 * scale);
            presenter.PreferredMinimumHeight = (int)(640 * scale);
        }

        ElevationBar.IsOpen = !ViewModel.IsElevated;
        Navigate("source");
        Closed += MainWindow_Closed;
    }

    public MainViewModel ViewModel => App.ViewModel;

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(nint hwnd);

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem { Tag: string tag })
        {
            Navigate(tag);
        }
    }

    public void Navigate(string tag)
    {
        if (!_pages.TryGetValue(tag, out var page))
        {
            page = tag switch
            {
                "source" => new SourcePage(),
                "preset" => new PresetPage(),
                "components" => new ComponentsPage(),
                "setup" => new SetupPage(),
                "build" => new BuildPage(),
                _ => throw new ArgumentOutOfRangeException(nameof(tag)),
            };
            _pages[tag] = page;
        }

        PageHost.Content = page;
        PageScroller.ChangeView(null, 0, null, disableAnimation: true);
        foreach (var item in Nav.MenuItems.OfType<NavigationViewItem>())
        {
            if ((string)item.Tag == tag && !item.IsSelected)
            {
                item.IsSelected = true;
            }
        }
    }

    // ---- Pickers (Windows App SDK pickers work in elevated, unpackaged apps) ----------------

    public async Task<string?> PickFileAsync(params string[] extensions)
    {
        var picker = new FileOpenPicker(AppWindow.Id) { SuggestedStartLocation = PickerLocationId.Downloads };
        foreach (var ext in extensions)
        {
            picker.FileTypeFilter.Add(ext);
        }

        var result = await picker.PickSingleFileAsync();
        return result?.Path;
    }

    public async Task<string?> PickFolderAsync()
    {
        var picker = new FolderPicker(AppWindow.Id) { SuggestedStartLocation = PickerLocationId.ComputerFolder };
        var result = await picker.PickSingleFolderAsync();
        return result?.Path;
    }

    public async Task<string?> PickSaveFileAsync(string suggestedName)
    {
        var picker = new FileSavePicker(AppWindow.Id)
        {
            SuggestedFileName = suggestedName,
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
        };
        picker.FileTypeChoices.Add("XboxOS11 build profile", new List<string> { ".json" });
        var result = await picker.PickSaveFileAsync();
        return result?.Path;
    }

    // ---- Footer actions ------------------------------------------------------------------

    private async void OpenProfile_Tapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e)
    {
        if (!await ConfirmDiscardAsync())
        {
            return;
        }

        var path = await PickFileAsync(".json");
        if (path is not null)
        {
            await ViewModel.OpenProfileAsync(path);
        }
    }

    private async void SaveProfile_Tapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e) => await SaveAsync();

    public async Task<bool> SaveAsync()
    {
        var suggested = ViewModel.CurrentProfilePath is { } current ? Path.GetFileNameWithoutExtension(current) : ViewModel.ProfileName;
        var path = await PickSaveFileAsync(suggested);
        return path is not null && await ViewModel.SaveProfileAsync(path);
    }

    public async Task<bool> ConfirmDiscardAsync()
    {
        if (!ViewModel.HasUnsavedChanges)
        {
            return true;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Save changes to this profile?",
            Content = "Your current build profile has unsaved changes.",
            PrimaryButtonText = "Save",
            SecondaryButtonText = "Don't save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        return await dialog.ShowAsync() switch
        {
            ContentDialogResult.Primary => await SaveAsync(),
            ContentDialogResult.Secondary => true,
            _ => false,
        };
    }

    private void RestartElevated_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel.RestartElevated())
        {
            Close();
        }
    }

    private void MainWindow_Closed(object sender, WindowEventArgs args)
    {
        if (ViewModel.IsBuilding)
        {
            ViewModel.CancelBuildCommand.Execute(null);
        }
    }
}
