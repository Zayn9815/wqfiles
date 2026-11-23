using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace WQGlassTransfer;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        AppLogger.Initialize();

        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnDomainUnhandledException;
        TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;

        base.OnStartup(e);
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        AppLogger.Crash("UI-Thread", $"Unhandled UI Exception: {e.Exception.Message}", e.Exception);
        MessageBox.Show(
            $"An unexpected error occurred and was saved to the Crash Log:\n\n{e.Exception.Message}\n\nOpen the '🐞 Logs & Crash Reports' tab to copy or export the full log.",
            "WQGlass Transfer — Error Logged",
            MessageBoxButton.OK,
            MessageBoxImage.Warning);
        e.Handled = true;
    }

    private void OnDomainUnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        var ex = e.ExceptionObject as Exception;
        AppLogger.Crash("AppDomain", $"Fatal AppDomain Exception (Terminating={e.IsTerminating}): {ex?.Message ?? e.ExceptionObject?.ToString()}", ex);
    }

    private void OnUnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        AppLogger.Error("BackgroundTask", $"Unobserved Task Exception: {e.Exception.GetBaseException().Message}", e.Exception);
        e.SetObserved();
    }
}
