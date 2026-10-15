using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using XboxOS11.Builder.App.ViewModels;

namespace XboxOS11.Builder.App.Views;

public sealed partial class SourcePage : UserControl
{
    public SourcePage()
    {
        InitializeComponent();
        ViewModel.RecentProfiles.CollectionChanged += (_, _) => Bindings.Update();
    }

    public MainViewModel ViewModel => App.ViewModel;

    public bool HasRecent => ViewModel.RecentProfiles.Count > 0;

    private async void BrowseIso_Click(object sender, RoutedEventArgs e)
    {
        var path = await App.MainWindow!.PickFileAsync(".iso");
        if (path is not null)
        {
            ViewModel.IsoPath = path;
        }
    }

    private async void BrowseOutput_Click(object sender, RoutedEventArgs e)
    {
        var path = await App.MainWindow!.PickFolderAsync();
        if (path is not null)
        {
            ViewModel.OutputDirectory = path;
        }
    }

    private async void Recent_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string path } && await App.MainWindow!.ConfirmDiscardAsync())
        {
            await ViewModel.OpenProfileAsync(path);
        }
    }

    private void Next_Click(object sender, RoutedEventArgs e) => App.MainWindow!.Navigate("preset");
}
