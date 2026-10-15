using System.ComponentModel;
using Microsoft.UI.Xaml.Controls;
using XboxOS11.Builder.App.ViewModels;

namespace XboxOS11.Builder.App.Views;

public sealed partial class BuildPage : UserControl, INotifyPropertyChanged
{
    public BuildPage()
    {
        InitializeComponent();
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(MainViewModel.BuildSucceeded) or nameof(MainViewModel.BuildResult) or "")
            {
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(ResultSeverity)));
            }
        };
        ViewModel.LogLines.CollectionChanged += (_, _) =>
        {
            if (ViewModel.LogLines.Count > 0)
            {
                LogList.ScrollIntoView(ViewModel.LogLines[^1]);
            }
        };
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public MainViewModel ViewModel => App.ViewModel;

    public InfoBarSeverity ResultSeverity => ViewModel.BuildSucceeded ? InfoBarSeverity.Success : InfoBarSeverity.Error;
}
