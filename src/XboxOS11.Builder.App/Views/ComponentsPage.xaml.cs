using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using XboxOS11.Builder.App.ViewModels;

namespace XboxOS11.Builder.App.Views;

public sealed partial class ComponentsPage : UserControl
{
    public ComponentsPage() => InitializeComponent();

    public MainViewModel ViewModel => App.ViewModel;

    private void Back_Click(object sender, RoutedEventArgs e) => App.MainWindow!.Navigate("preset");

    private void Next_Click(object sender, RoutedEventArgs e) => App.MainWindow!.Navigate("setup");
}
