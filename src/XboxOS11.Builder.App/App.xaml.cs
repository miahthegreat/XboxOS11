using Microsoft.UI.Xaml;
using XboxOS11.Builder.App.ViewModels;

namespace XboxOS11.Builder.App;

public partial class App : Application
{
    private MainWindow? _window;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            ViewModel.ErrorMessage = e.Exception.Message;
            e.Handled = true;
        };
    }

    public static MainViewModel ViewModel { get; } = new();

    public static MainWindow? MainWindow => (Current as App)?._window;

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
        _ = ViewModel.InitializeAsync();
    }
}
