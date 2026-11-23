using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;

namespace WQGlassTransfer;

public partial class MainWindow : Window
{
    private readonly DiscoveryService _discovery = new();
    private readonly ObservableCollection<DiscoveredPhone> _phones = new();
    private readonly List<RemoteFileItem> _allItems = new();
    private readonly ObservableCollection<RemoteFileItem> _visibleItems = new();

    private TransferClient? _client;
    private PhoneInfo? _phoneInfo;
    private string _currentPath = "";
    private string _pcDownloadDir;
    private CancellationTokenSource? _transferCts;

    private static string SettingsPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "WQGlassTransfer", "settings.json");

    public MainWindow()
    {
        InitializeComponent();
        _pcDownloadDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "WQGlass");
        DiscoveredBox.ItemsSource = _phones;
        FilesList.ItemsSource = _visibleItems;

        LoadSettings();

        _discovery.PhoneDiscovered += OnPhoneDiscovered;
        _discovery.Start();
        Closed += (_, _) =>
        {
            _discovery.Dispose();
            _client?.Dispose();
        };
    }

    private void LoadSettings()
    {
        try
        {
            if (File.Exists(SettingsPath))
            {
                var s = JsonSerializer.Deserialize<SavedConnectionSettings>(File.ReadAllText(SettingsPath));
                if (s is not null)
                {
                    if (!string.IsNullOrWhiteSpace(s.LastEndpoint)) EndpointBox.Text = s.LastEndpoint;
                    if (!string.IsNullOrWhiteSpace(s.LastPin)) PinBox.Text = s.LastPin;
                    if (!string.IsNullOrWhiteSpace(s.DownloadDirectory)) _pcDownloadDir = s.DownloadDirectory;
                }
            }
        }
        catch { }
    }

    private void SaveSettings()
    {
        try
        {
            string? dir = Path.GetDirectoryName(SettingsPath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            var s = new SavedConnectionSettings
            {
                LastEndpoint = EndpointBox.Text.Trim(),
                LastPin = PinBox.Text.Trim(),
                DownloadDirectory = _pcDownloadDir
            };
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(s));
        }
        catch { }
    }

    private void OnPhoneDiscovered(DiscoveredPhone phone)
    {
        Dispatcher.Invoke(() =>
        {
            var existing = _phones.FirstOrDefault(p => string.Equals(p.Endpoint, phone.Endpoint, StringComparison.OrdinalIgnoreCase));
            if (existing is not null)
            {
                existing.Device = phone.Device;
                existing.Root = phone.Root;
                existing.LastSeenUtc = phone.LastSeenUtc;
            }
            else
            {
                _phones.Add(phone);
                if (_phones.Count == 1 && string.IsNullOrWhiteSpace(EndpointBox.Text))
                {
                    DiscoveredBox.SelectedIndex = 0;
                    EndpointBox.Text = phone.Endpoint;
                }
            }
            if (_client is null)
            {
                StatusBadgeText.Text = $"Found {_phones.Count} iPhone(s) on Wi-Fi";
            }
        });
    }

    private void DiscoveredBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (DiscoveredBox.SelectedItem is DiscoveredPhone p)
        {
            EndpointBox.Text = p.Endpoint;
            PinBox.Focus();
        }
    }

    private void ScanBtn_Click(object sender, RoutedEventArgs e)
    {
        _discovery.SendProbeNow();
        if (_client is null)
        {
            StatusBadgeText.Text = "Scanning Wi-Fi for iPhone…";
        }
    }

    private void PinBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) ConnectBtn_Click(sender, e);
    }

    private async void ConnectBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_client is not null)
        {
            Disconnect();
            return;
        }

        string ep = EndpointBox.Text.Trim();
        string pin = PinBox.Text.Trim();
        if (string.IsNullOrWhiteSpace(ep))
        {
            MessageBox.Show(this, "Enter your iPhone IP:Port or select an auto-discovered iPhone.", "WQGlass Transfer", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        if (pin.Length < 4)
        {
            MessageBox.Show(this, "Enter the 4-digit PIN shown on your iPhone.", "WQGlass Transfer", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        ConnectBtn.IsEnabled = false;
        StatusBadgeText.Text = "Connecting…";
        try
        {
            var client = new TransferClient(ep, pin);
            PhoneInfo info = await client.GetInfoAsync();
            _client = client;
            _phoneInfo = info;
            _currentPath = "";
            SaveSettings();

            ConnectBtn.Content = "Disconnect";
            StatusBadgeText.Text = $"● Connected to {info.Device} ({info.Root})";
            StatusBadgeText.Foreground = new SolidColorBrush(Color.FromRgb(74, 222, 128));
            StorageLabel.Text = $"iOS {info.IosVersion} · {RemoteFileItem.FormatBytes(info.FreeBytes)} free of {RemoteFileItem.FormatBytes(info.TotalBytes)}";
            SetConnectedUI(true);
            await RefreshDirectoryAsync();
        }
        catch (Exception ex)
        {
            StatusBadgeText.Text = "Connection failed";
            MessageBox.Show(this, ex.Message, "Could Not Connect", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            ConnectBtn.IsEnabled = true;
        }
    }

    private void Disconnect()
    {
        _transferCts?.Cancel();
        _client?.Dispose();
        _client = null;
        _phoneInfo = null;
        _allItems.Clear();
        _visibleItems.Clear();
        _currentPath = "";
        ConnectBtn.Content = "Connect";
        StatusBadgeText.Text = _phones.Count > 0 ? $"Found {_phones.Count} iPhone(s) on Wi-Fi" : "Disconnected";
        StatusBadgeText.Foreground = (Brush)FindResource("AccentCyan");
        StorageLabel.Text = "";
        PathLabel.Text = "Not connected — Open WQ Glass → Utility Hub → iPhone ↔ Windows Transfer";
        SetConnectedUI(false);
    }

    private void SetConnectedUI(bool connected)
    {
        SendFilesBtn.IsEnabled = connected;
        SendFolderBtn.IsEnabled = connected;
        NewFolderBtn.IsEnabled = connected;
        UpBtn.IsEnabled = connected && !string.IsNullOrEmpty(_currentPath);
        RefreshBtn.IsEnabled = connected;
        UpdateSelectionButtons();
    }

    private void UpdateSelectionButtons()
    {
        bool hasSel = _client is not null && FilesList.SelectedItems.Count > 0;
        DownloadBtn.IsEnabled = hasSel;
        DeleteBtn.IsEnabled = hasSel;
        RenameBtn.IsEnabled = _client is not null && FilesList.SelectedItems.Count == 1;
    }

    private async Task RefreshDirectoryAsync()
    {
        if (_client is null) return;
        try
        {
            RemoteListResponse res = await _client.ListAsync(_currentPath);
            _allItems.Clear();
            _allItems.AddRange(res.Items);
            ApplySearchFilter();
            string rootName = _phoneInfo?.Root ?? "Downloads";
            PathLabel.Text = string.IsNullOrEmpty(_currentPath)
                ? $"/{rootName}  ({_allItems.Count} items)"
                : $"/{rootName}/{_currentPath}  ({_allItems.Count} items)";
            UpBtn.IsEnabled = !string.IsNullOrEmpty(_currentPath);
        }
        catch (Exception ex)
        {
            TransferStatusText.Text = $"Refresh failed: {ex.Message}";
        }
    }

    private void ApplySearchFilter()
    {
        string q = SearchBox.Text.Trim();
        _visibleItems.Clear();
        foreach (var item in _allItems)
        {
            if (string.IsNullOrEmpty(q) || item.Name.Contains(q, StringComparison.OrdinalIgnoreCase))
            {
                _visibleItems.Add(item);
            }
        }
        UpdateSelectionButtons();
    }

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e) => ApplySearchFilter();

    private void FilesList_SelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateSelectionButtons();

    private async void FilesList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (_client is null || FilesList.SelectedItem is not RemoteFileItem item) return;
        if (item.IsDir)
        {
            _currentPath = item.Path;
            await RefreshDirectoryAsync();
        }
        else
        {
            await DownloadItemsAsync(new[] { item });
        }
    }

    private async void UpBtn_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_currentPath)) return;
        int idx = _currentPath.LastIndexOf('/');
        _currentPath = idx > 0 ? _currentPath[..idx] : "";
        await RefreshDirectoryAsync();
    }

    private async void RefreshBtn_Click(object sender, RoutedEventArgs e) => await RefreshDirectoryAsync();

    private async void SendFilesBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null) return;
        var dlg = new OpenFileDialog { Multiselect = true, Title = "Select Files to Send to iPhone" };
        if (dlg.ShowDialog(this) == true && dlg.FileNames.Length > 0)
        {
            await UploadLocalPathsAsync(dlg.FileNames);
        }
    }

    private async void SendFolderBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null) return;
        var dlg = new OpenFolderDialog { Title = "Select Folder to Send to iPhone" };
        if (dlg.ShowDialog(this) == true && !string.IsNullOrWhiteSpace(dlg.FolderName))
        {
            await UploadLocalPathsAsync(new[] { dlg.FolderName });
        }
    }

    private async void DownloadBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null || FilesList.SelectedItems.Count == 0) return;
        var selected = FilesList.SelectedItems.Cast<RemoteFileItem>().ToList();
        await DownloadItemsAsync(selected);
    }

    private async Task DownloadItemsAsync(IReadOnlyList<RemoteFileItem> items)
    {
        if (_client is null || items.Count == 0) return;
        Directory.CreateDirectory(_pcDownloadDir);

        var fileJobs = new List<(string remotePath, string localPath)>();
        async Task CollectRemoteAsync(RemoteFileItem it, string localBase)
        {
            if (it.IsDir)
            {
                string subLocal = Path.Combine(localBase, it.Name);
                Directory.CreateDirectory(subLocal);
                var listing = await _client.ListAsync(it.Path);
                foreach (var child in listing.Items)
                {
                    await CollectRemoteAsync(child, subLocal);
                }
            }
            else
            {
                fileJobs.Add((it.Path, Path.Combine(localBase, it.Name)));
            }
        }

        BeginTransferUI("Preparing download list…");
        try
        {
            foreach (var it in items)
            {
                await CollectRemoteAsync(it, _pcDownloadDir);
            }
            var progress = CreateProgressHandler("Downloading");
            for (int i = 0; i < fileJobs.Count; i++)
            {
                _transferCts!.Token.ThrowIfCancellationRequested();
                await _client.DownloadFileAsync(fileJobs[i].remotePath, fileJobs[i].localPath, i + 1, fileJobs.Count, progress, _transferCts.Token);
            }
            EndTransferUI($"Downloaded {fileJobs.Count} file(s) to {_pcDownloadDir}");
        }
        catch (OperationCanceledException)
        {
            EndTransferUI("Download cancelled.");
        }
        catch (Exception ex)
        {
            EndTransferUI($"Download error: {ex.Message}");
            MessageBox.Show(this, ex.Message, "Download Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async Task UploadLocalPathsAsync(IReadOnlyList<string> localPaths)
    {
        if (_client is null || localPaths.Count == 0) return;
        var jobs = new List<(string localFile, string remoteDir)>();

        void CollectLocal(string path, string remoteBase)
        {
            if (Directory.Exists(path))
            {
                string folderName = Path.GetFileName(path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
                string nextRemote = string.IsNullOrEmpty(remoteBase) ? folderName : $"{remoteBase}/{folderName}";
                foreach (string file in Directory.GetFiles(path))
                {
                    jobs.Add((file, nextRemote));
                }
                foreach (string sub in Directory.GetDirectories(path))
                {
                    CollectLocal(sub, nextRemote);
                }
            }
            else if (File.Exists(path))
            {
                jobs.Add((path, remoteBase));
            }
        }

        foreach (string p in localPaths) CollectLocal(p, _currentPath);
        if (jobs.Count == 0) return;

        BeginTransferUI($"Sending {jobs.Count} file(s) to iPhone…");
        try
        {
            var progress = CreateProgressHandler("Sending");
            for (int i = 0; i < jobs.Count; i++)
            {
                _transferCts!.Token.ThrowIfCancellationRequested();
                await _client.UploadFileAsync(jobs[i].remoteDir, jobs[i].localFile, i + 1, jobs.Count, progress, _transferCts.Token);
            }
            EndTransferUI($"Sent {jobs.Count} file(s) to iPhone successfully!");
            await RefreshDirectoryAsync();
        }
        catch (OperationCanceledException)
        {
            EndTransferUI("Upload cancelled.");
        }
        catch (Exception ex)
        {
            EndTransferUI($"Upload error: {ex.Message}");
            MessageBox.Show(this, ex.Message, "Upload Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void BeginTransferUI(string message)
    {
        _transferCts?.Cancel();
        _transferCts = new CancellationTokenSource();
        CancelTransferBtn.Visibility = Visibility.Visible;
        TransferBar.Value = 0;
        TransferStatusText.Text = message;
        TransferSpeedText.Text = "";
    }

    private void EndTransferUI(string message)
    {
        CancelTransferBtn.Visibility = Visibility.Collapsed;
        TransferBar.Value = 100;
        TransferStatusText.Text = message;
        TransferSpeedText.Text = "";
        _transferCts?.Dispose();
        _transferCts = null;
    }

    private IProgress<TransferProgressInfo> CreateProgressHandler(string verb)
    {
        return new Progress<TransferProgressInfo>(p =>
        {
            double pct = p.TotalBytes > 0 ? Math.Clamp(100.0 * p.TransferredBytes / p.TotalBytes, 0, 100) : 0;
            TransferBar.Value = pct;
            TransferStatusText.Text = $"{verb} ({p.FileIndex}/{p.FileCount}): {p.FileName} — {RemoteFileItem.FormatBytes(p.TransferredBytes)} / {RemoteFileItem.FormatBytes(p.TotalBytes)}";
            TransferSpeedText.Text = $"{RemoteFileItem.FormatBytes((long)p.BytesPerSecond)}/s · {pct:0}%";
        });
    }

    private void CancelTransferBtn_Click(object sender, RoutedEventArgs e)
    {
        _transferCts?.Cancel();
    }

    private async void NewFolderBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null) return;
        string? name = PromptInput("New Folder", "Enter folder name to create on iPhone:", "");
        if (string.IsNullOrWhiteSpace(name)) return;
        string target = string.IsNullOrEmpty(_currentPath) ? name.Trim() : $"{_currentPath}/{name.Trim()}";
        try
        {
            await _client.CreateFolderAsync(target);
            await RefreshDirectoryAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "New Folder Failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async void RenameBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null || FilesList.SelectedItem is not RemoteFileItem item) return;
        string? newName = PromptInput("Rename", $"Rename '{item.Name}' to:", item.Name);
        if (string.IsNullOrWhiteSpace(newName) || newName.Trim() == item.Name) return;
        try
        {
            await _client.RenameAsync(item.Path, newName.Trim());
            await RefreshDirectoryAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Rename Failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async void DeleteBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null || FilesList.SelectedItems.Count == 0) return;
        var items = FilesList.SelectedItems.Cast<RemoteFileItem>().ToList();
        var confirm = MessageBox.Show(this, $"Delete {items.Count} selected item(s) from your iPhone?", "Confirm Delete", MessageBoxButton.YesNo, MessageBoxImage.Warning);
        if (confirm != MessageBoxResult.Yes) return;
        try
        {
            foreach (var it in items) await _client.DeleteAsync(it.Path);
            await RefreshDirectoryAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Delete Failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void OpenPcDirBtn_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(_pcDownloadDir);
        Process.Start(new ProcessStartInfo { FileName = _pcDownloadDir, UseShellExecute = true });
    }

    private void Window_DragOver(object sender, DragEventArgs e)
    {
        if (_client is not null && e.Data.GetDataPresent(DataFormats.FileDrop))
        {
            e.Effects = DragDropEffects.Copy;
            DropOverlay.Visibility = Visibility.Visible;
        }
        else
        {
            e.Effects = DragDropEffects.None;
        }
        e.Handled = true;
    }

    private void Window_DragLeave(object sender, DragEventArgs e)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
    }

    private async void Window_Drop(object sender, DragEventArgs e)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
        if (_client is null || !e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        if (e.Data.GetData(DataFormats.FileDrop) is string[] dropped && dropped.Length > 0)
        {
            await UploadLocalPathsAsync(dropped);
        }
    }

    private string? PromptInput(string title, string label, string initialValue)
    {
        var win = new Window
        {
            Title = title,
            Width = 400,
            Height = 175,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = this,
            ResizeMode = ResizeMode.NoResize,
            Background = (Brush)FindResource("BgCanvas"),
            Foreground = (Brush)FindResource("TextPrimary")
        };
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0, 0, 0, 8), Foreground = (Brush)FindResource("TextSecondary") });
        var tb = new TextBox { Text = initialValue, Style = (Style)FindResource("GlassTextBox"), Height = 34 };
        panel.Children.Add(tb);
        var btns = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        var cancel = new Button { Content = "Cancel", Style = (Style)FindResource("GlassBtn"), Margin = new Thickness(0, 0, 8, 0), IsCancel = true };
        var ok = new Button { Content = "OK", Style = (Style)FindResource("PrimaryBtn"), IsDefault = true };
        ok.Click += (_, _) => { win.DialogResult = true; win.Close(); };
        btns.Children.Add(cancel);
        btns.Children.Add(ok);
        panel.Children.Add(btns);
        win.Content = panel;
        tb.SelectAll();
        tb.Focus();
        return win.ShowDialog() == true ? tb.Text : null;
    }
}
