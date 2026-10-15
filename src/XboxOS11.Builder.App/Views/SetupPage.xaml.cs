using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using XboxOS11.Builder.App.ViewModels;

namespace XboxOS11.Builder.App.Views;

public sealed partial class SetupPage : UserControl
{
    public SetupPage() => InitializeComponent();

    public MainViewModel ViewModel => App.ViewModel;

    private async void BrowseDrivers_Click(object sender, RoutedEventArgs e)
    {
        var path = await App.MainWindow!.PickFolderAsync();
        if (path is not null)
        {
            ViewModel.DriversDirectory = path;
        }
    }

    private async void BrowseUpdates_Click(object sender, RoutedEventArgs e)
    {
        var path = await App.MainWindow!.PickFolderAsync();
        if (path is not null)
        {
            ViewModel.UpdatesDirectory = path;
        }
    }

    private void Preview_Expanding(Expander sender, ExpanderExpandingEventArgs args) => ViewModel.PreviewUnattendCommand.Execute(null);

    private void Back_Click(object sender, RoutedEventArgs e) => App.MainWindow!.Navigate("components");

    private void Next_Click(object sender, RoutedEventArgs e) => App.MainWindow!.Navigate("build");
}
