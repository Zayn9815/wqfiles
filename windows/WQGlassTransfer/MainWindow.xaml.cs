using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using QRCoder;

namespace WQGlassTransfer;

public partial class MainWindow : Window
{
    private readonly DiscoveryService _discovery = new();
    private readonly TransferServer _server = new();
    private readonly ObservableCollection<DiscoveredPhone> _phones = new();
    private readonly List<RemoteFileItem> _allItems = new();
    private readonly ObservableCollection<RemoteFileItem> _visibleItems = new();
    private readonly ObservableCollection<string> _hostLogs = new();

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
        HostLogList.ItemsSource = _hostLogs;

        LoadSettings();

        HostFolderBox.Text = _server.RootPath;
        _discovery.LocalServerPortProvider = () => _server.IsRunning ? _server.Port : null;
        _discovery.PhoneDiscovered += OnPhoneDiscovered;
        _discovery.Start();

        _server.ActivityLogged += line =>
        {
            Dispatcher.Invoke(() =>
            {
                _hostLogs.Insert(0, line);
                while (_hostLogs.Count > 100) _hostLogs.RemoveAt(_hostLogs.Count - 1);
            });
        };

        RefreshHostUI();

        Closed += (_, _) =>
        {
            _discovery.Dispose();
            _server.Dispose();
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
                    if (!string.IsNullOrWhiteSpace(s.HostSharedDirectory) && Directory.Exists(s.HostSharedDirectory))
                    {
                        _server.RootPath = s.HostSharedDirectory;
                        _server.RootLabel = Path.GetFileName(s.HostSharedDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
                        if (string.IsNullOrWhiteSpace(_server.RootLabel)) _server.RootLabel = "PC";
                    }
                    if (!string.IsNullOrWhiteSpace(s.HostFixedPin) && s.HostFixedPin.Length >= 4)
                    {
                        _server.Pin = s.HostFixedPin.Trim();
                        HostFixedPinBox.Text = _server.Pin;
                    }
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
                DownloadDirectory = _pcDownloadDir,
                HostSharedDirectory = _server.RootPath,
                HostFixedPin = HostFixedPinBox.Text.Trim()
            };
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(s));
        }
        catch { }
    }

    #region Mode Switching

    private void ClientTabBtn_Click(object sender, RoutedEventArgs e)
    {
        ClientPanel.Visibility = Visibility.Visible;
        HostPanel.Visibility = Visibility.Collapsed;
        ClientTabBtn.Style = (Style)FindResource("PrimaryBtn");
        HostTabBtn.Style = (Style)FindResource("GlassBtn");
    }

    private void HostTabBtn_Click(object sender, RoutedEventArgs e)
    {
        ClientPanel.Visibility = Visibility.Collapsed;
        HostPanel.Visibility = Visibility.Visible;
        ClientTabBtn.Style = (Style)FindResource("GlassBtn");
        HostTabBtn.Style = (Style)FindResource("PrimaryBtn");
        RefreshHostUI();
    }

    #endregion

    #region Host Mode ("Share This PC")

    private void HostToggleBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_server.IsRunning)
        {
            _server.Stop();
            _hostLogs.Insert(0, $"[{DateTime.Now:HH:mm:ss}] PC Host stopped.");
            RefreshHostUI();
            return;
        }

        string fixedPin = HostFixedPinBox.Text.Trim();
        if (fixedPin.Length >= 4 && fixedPin.Length <= 8)
        {
            _server.Pin = fixedPin;
        }
        else if (string.IsNullOrWhiteSpace(_server.Pin))
        {
            _server.Pin = TransferServer.GenerateRandomPin();
        }

        if (!_server.Start(out string? err))
        {
            MessageBox.Show(this, err ?? "Unable to start PC Host Server.", "Share This PC", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        SaveSettings();
        RefreshHostUI();
    }

    private void HostChooseFolderBtn_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFolderDialog { Title = "Choose Folder to Share with iPhone / Android / PC" };
        if (dlg.ShowDialog(this) == true && !string.IsNullOrWhiteSpace(dlg.FolderName))
        {
            _server.RootPath = dlg.FolderName;
            string lbl = Path.GetFileName(dlg.FolderName.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            _server.RootLabel = string.IsNullOrWhiteSpace(lbl) ? "PC" : lbl;
            HostFolderBox.Text = _server.RootPath;
            SaveSettings();
            if (_server.IsRunning)
            {
                _hostLogs.Insert(0, $"[{DateTime.Now:HH:mm:ss}] Switched shared folder to: {_server.RootPath}");
            }
            RefreshHostUI();
        }
    }

    private void HostApplyPinBtn_Click(object sender, RoutedEventArgs e)
    {
        string val = HostFixedPinBox.Text.Trim();
        if (string.IsNullOrEmpty(val))
        {
            _server.Pin = TransferServer.GenerateRandomPin();
        }
        else if (val.Length >= 4 && val.Length <= 8)
        {
            _server.Pin = val;
        }
        else
        {
            MessageBox.Show(this, "PIN must be 4 to 8 characters.", "Invalid PIN", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        SaveSettings();
        RefreshHostUI();
    }

    private void HostRandomPinBtn_Click(object sender, RoutedEventArgs e)
    {
        HostFixedPinBox.Text = "";
        _server.Pin = TransferServer.GenerateRandomPin();
        SaveSettings();
        RefreshHostUI();
    }

    private void HostCopyBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!_server.IsRunning) return;
        Clipboard.SetText($"http://{_server.IpAddress}:{_server.Port} (PIN: {_server.Pin})");
        _hostLogs.Insert(0, $"[{DateTime.Now:HH:mm:ss}] Copied Wi-Fi address & PIN to clipboard.");
    }

    private void HostOpenFolderBtn_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Directory.CreateDirectory(_server.RootPath);
            Process.Start(new ProcessStartInfo { FileName = _server.RootPath, UseShellExecute = true });
        }
        catch { }
    }

    private void HostClearLogBtn_Click(object sender, RoutedEventArgs e) => _hostLogs.Clear();

    private void RefreshHostUI()
    {
        HostFolderBox.Text = _server.RootPath;
        if (_server.IsRunning && !string.IsNullOrWhiteSpace(_server.IpAddress))
        {
            string url = $"http://{_server.IpAddress}:{_server.Port}";
            string qrUrl = $"{url}/?pin={Uri.EscapeDataString(_server.Pin)}";
            HostStatusText.Text = $"● Live — Visible on Wi-Fi as \"{Environment.MachineName}\" ({_server.RootLabel})";
            HostStatusText.Foreground = new SolidColorBrush(Color.FromRgb(74, 222, 128));
            HostPinBigText.Text = _server.Pin;
            HostUrlText.Text = $"{url}   (Auto-discovered by iPhone & Android on Wi-Fi)";
            HostToggleBtn.Content = "■ Stop Sharing PC";
            HostToggleBtn.Style = (Style)FindResource("DangerBtn");
            HostCopyBtn.IsEnabled = true;
            HostQrImage.Source = RenderQrBitmap(qrUrl);

            HostLivePill.Visibility = Visibility.Visible;
            HostLivePillText.Text = $"● PC Live :{ _server.Port } · PIN {_server.Pin}";
        }
        else
        {
            HostStatusText.Text = "PC Host Server Stopped";
            HostStatusText.Foreground = new SolidColorBrush(Color.FromRgb(251, 191, 36));
            HostPinBigText.Text = "----";
            HostUrlText.Text = "Click Start Sharing PC below to share this folder with iPhone, Android, or any browser";
            HostToggleBtn.Content = "▶ Start Sharing PC";
            HostToggleBtn.Style = (Style)FindResource("PrimaryBtn");
            HostCopyBtn.IsEnabled = false;
            HostQrImage.Source = null;

            HostLivePill.Visibility = Visibility.Collapsed;
        }
    }

    private static BitmapImage? RenderQrBitmap(string content)
    {
        try
        {
            using var gen = new QRCodeGenerator();
            using QRCodeData data = gen.CreateQrCode(content, QRCodeGenerator.ECCLevel.M);
            var png = new PngByteQRCode(data);
            byte[] bytes = png.GetGraphic(8);
            var bmp = new BitmapImage();
            using var ms = new MemoryStream(bytes);
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.StreamSource = ms;
            bmp.EndInit();
            bmp.Freeze();
            return bmp;
        }
        catch
        {
            return null;
        }
    }

    #endregion

    #region Client Mode (Connect to iPhone / Android / PC)

    private void OnPhoneDiscovered(DiscoveredPhone phone)
    {
        Dispatcher.Invoke(() =>
        {
            var existing = _phones.FirstOrDefault(p => string.Equals(p.Endpoint, phone.Endpoint, StringComparison.OrdinalIgnoreCase));
            if (existing is not null)
            {
                bool changed = existing.Device != phone.Device || existing.Root != phone.Root || existing.Platform != phone.Platform;
                existing.Device = phone.Device;
                existing.Platform = phone.Platform;
                existing.OsVersion = phone.OsVersion;
                existing.Root = phone.Root;
                existing.LastSeenUtc = phone.LastSeenUtc;
                if (changed)
                {
                    int idx = _phones.IndexOf(existing);
                    if (idx >= 0) _phones[idx] = phone;
                }
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
                StatusBadgeText.Text = $"Found {_phones.Count} device(s) on Wi-Fi";
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
            StatusBadgeText.Text = "Scanning Wi-Fi for iPhone, Android & PC…";
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
            MessageBox.Show(this, "Enter a device IP:Port or select an auto-discovered iPhone, Android, or PC.", "WQGlass Transfer", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        if (pin.Length < 4)
        {
            MessageBox.Show(this, "Enter the pairing PIN shown on the target device.", "WQGlass Transfer", MessageBoxButton.OK, MessageBoxImage.Information);
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
            StatusBadgeText.Text = $"● Connected: {info.PlatformIcon} {info.Device} [{info.OsSummary}] · {info.Root}";
            StatusBadgeText.Foreground = new SolidColorBrush(Color.FromRgb(74, 222, 128));
            StorageLabel.Text = $"{info.OsSummary} · {RemoteFileItem.FormatBytes(info.FreeBytes)} free of {RemoteFileItem.FormatBytes(info.TotalBytes)}";
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
        StatusBadgeText.Text = _phones.Count > 0 ? $"Found {_phones.Count} device(s) on Wi-Fi" : "Disconnected";
        StatusBadgeText.Foreground = (Brush)FindResource("AccentCyan");
        StorageLabel.Text = "";
        PathLabel.Text = "Not connected — Open WQGlass Transfer on iPhone, Android, or another PC";
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
        var dlg = new OpenFileDialog { Multiselect = true, Title = "Select Files to Send" };
        if (dlg.ShowDialog(this) == true && dlg.FileNames.Length > 0)
        {
            await UploadLocalPathsAsync(dlg.FileNames);
        }
    }

    private async void SendFolderBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null) return;
        var dlg = new OpenFolderDialog { Title = "Select Folder to Send" };
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

        string targetName = _phoneInfo?.Device ?? "device";
        BeginTransferUI($"Sending {jobs.Count} file(s) to {targetName}…");
        try
        {
            var progress = CreateProgressHandler("Sending");
            for (int i = 0; i < jobs.Count; i++)
            {
                _transferCts!.Token.ThrowIfCancellationRequested();
                await _client.UploadFileAsync(jobs[i].remoteDir, jobs[i].localFile, i + 1, jobs.Count, progress, _transferCts.Token);
            }
            EndTransferUI($"Sent {jobs.Count} file(s) to {targetName} successfully!");
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
        string targetName = _phoneInfo?.Device ?? "device";
        string? name = PromptInput("New Folder", $"Enter folder name to create on {targetName}:", "");
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
        string targetName = _phoneInfo?.Device ?? "device";
        var confirm = MessageBox.Show(this, $"Delete {items.Count} selected item(s) from {targetName}?", "Confirm Delete", MessageBoxButton.YesNo, MessageBoxImage.Warning);
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
        if (ClientPanel.Visibility == Visibility.Visible && _client is not null && e.Data.GetDataPresent(DataFormats.FileDrop))
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
        if (ClientPanel.Visibility != Visibility.Visible || _client is null || !e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        if (e.Data.GetData(DataFormats.FileDrop) is string[] dropped && dropped.Length > 0)
        {
            await UploadLocalPathsAsync(dropped);
        }
    }

    #endregion

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
