using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using QRCoder;

namespace WQGlassTransfer;

public partial class MainWindow : Window
{
    private readonly DiscoveryService _discovery = new();
    private readonly TransferServer _server = new();
    private readonly UsbTransferService _usb = new();
    private readonly AppleUsbMuxBridge _appleMux = new();
    private readonly DispatcherTimer _usbPollTimer;

    private readonly ObservableCollection<DiscoveredPhone> _phones = new();
    private readonly List<RemoteFileItem> _allItems = new();
    private readonly ObservableCollection<RemoteFileItem> _visibleItems = new();

    private readonly ObservableCollection<UsbDeviceSummary> _usbDevices = new();
    private readonly List<UsbFileItem> _allUsbItems = new();
    private readonly ObservableCollection<UsbFileItem> _visibleUsbItems = new();

    private readonly ObservableCollection<string> _hostLogs = new();
    private readonly ObservableCollection<TransferHistoryEntry> _history = new();

    private TransferClient? _client;
    private PhoneInfo? _phoneInfo;
    private string _currentPath = "";
    private string _wifiCategory = "All";
    private string _usbCurrentPath = "\\";
    private string _usbCategory = "All";

    private string _pcDownloadDir;
    private int _parallelStreams = 3;
    private string _conflictPolicy = "Rename";
    private bool _loadingSettings = true;

    private long _sessionTotalBytes;
    private double _sessionPeakBps;
    private CancellationTokenSource? _transferCts;
    private int _activeNav; // 0=WiFi, 1=USB, 2=Host, 3=History, 4=Settings, 5=Logs
    private string _logFilterLevel = "ALL";
    private int _errorLogCount;

    private static string SettingsPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "WQGlassTransfer", "settings.json");

    public MainWindow()
    {
        InitializeComponent();
        _pcDownloadDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "WQGlass");

        DiscoveredBox.ItemsSource = _phones;
        FilesList.ItemsSource = _visibleItems;
        UsbDevicesBox.ItemsSource = _usbDevices;
        UsbFilesList.ItemsSource = _visibleUsbItems;
        HostLogList.ItemsSource = _hostLogs;
        HistoryList.ItemsSource = _history;

        LoadSettings();
        _loadingSettings = false;

        HostFolderBox.Text = _server.RootPath;
        SettingsDownloadDirBox.Text = _pcDownloadDir;
        LogsFileLocationText.Text = $"Saved to: {AppLogger.LogsDirectory} (wqglass-transfer.log & wqglass-crashes.log)";

        AppLogger.EntryAdded += OnLogEntryAdded;
        UpdateErrorBadgeCount();

        _discovery.LocalServerPortProvider = () => _server.IsRunning ? _server.Port : null;
        _discovery.PhoneDiscovered += OnPhoneDiscovered;
        _discovery.Start();

        _server.ActivityLogged += line =>
        {
            AppLogger.Info("HostServer", line);
            Dispatcher.Invoke(() =>
            {
                _hostLogs.Insert(0, line);
                while (_hostLogs.Count > 120) _hostLogs.RemoveAt(_hostLogs.Count - 1);
            });
        };
        _server.TextReceived += text =>
        {
            AppLogger.Info("HostServer", $"Received text/link ({text.Length} chars)");
            Dispatcher.Invoke(() =>
            {
                try { Clipboard.SetText(text); } catch { }
                TransferStatusText.Text = $"📋 Received text/link from phone (copied to PC clipboard): {(text.Length > 80 ? text[..80] + "…" : text)}";
            });
        };

        RefreshUsbDevicesList();
        _usbPollTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
        _usbPollTimer.Tick += (_, _) => RefreshUsbDevicesList();
        _usbPollTimer.Start();

        RefreshHostUI();

        Closed += (_, _) =>
        {
            AppLogger.EntryAdded -= OnLogEntryAdded;
            _usbPollTimer.Stop();
            _transferCts?.Cancel();
            _discovery.Dispose();
            _server.Dispose();
            _usb.Dispose();
            _appleMux.Dispose();
            _client?.Dispose();
        };
    }

    #region Settings & Persistence

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
                        string lbl = Path.GetFileName(s.HostSharedDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
                        _server.RootLabel = string.IsNullOrWhiteSpace(lbl) ? "PC" : lbl;
                    }
                    if (!string.IsNullOrWhiteSpace(s.HostFixedPin) && s.HostFixedPin.Length >= 4)
                    {
                        _server.Pin = s.HostFixedPin.Trim();
                        HostFixedPinBox.Text = _server.Pin;
                    }
                    _parallelStreams = Math.Clamp(s.ParallelStreams <= 0 ? 3 : s.ParallelStreams, 1, 4);
                    _conflictPolicy = string.IsNullOrWhiteSpace(s.ConflictPolicy) ? "Rename" : s.ConflictPolicy;
                }
            }
        }
        catch (Exception ex) { AppLogger.Warn("Settings", "Could not load settings.json", ex.Message); }

        ParallelStreamsBox.SelectedIndex = _parallelStreams - 1;
        ConflictPolicyBox.SelectedIndex = _conflictPolicy switch
        {
            "Overwrite" => 1,
            "Skip" => 2,
            _ => 0
        };
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
                HostFixedPin = HostFixedPinBox.Text.Trim(),
                ParallelStreams = _parallelStreams,
                ConflictPolicy = _conflictPolicy
            };
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(s));
        }
        catch (Exception ex) { AppLogger.Warn("Settings", "Could not save settings.json", ex.Message); }
    }

    private void SettingsChooseDownloadDir_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFolderDialog { Title = "Choose Default PC Download Folder" };
        if (dlg.ShowDialog(this) == true && !string.IsNullOrWhiteSpace(dlg.FolderName))
        {
            _pcDownloadDir = dlg.FolderName;
            SettingsDownloadDirBox.Text = _pcDownloadDir;
            SaveSettings();
        }
    }

    private void SettingsChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loadingSettings) return;
        if (ParallelStreamsBox.SelectedItem is ComboBoxItem pItem && int.TryParse(pItem.Tag?.ToString(), out int p))
            _parallelStreams = Math.Clamp(p, 1, 4);
        if (ConflictPolicyBox.SelectedItem is ComboBoxItem cItem && cItem.Tag is string pol)
            _conflictPolicy = pol;
        SaveSettings();
    }

    #endregion

    #region Sidebar Navigation & Keyboard Shortcuts

    private void SwitchNav(int index)
    {
        _activeNav = index;
        WifiPanel.Visibility = index == 0 ? Visibility.Visible : Visibility.Collapsed;
        UsbPanel.Visibility = index == 1 ? Visibility.Visible : Visibility.Collapsed;
        HostPanel.Visibility = index == 2 ? Visibility.Visible : Visibility.Collapsed;
        HistoryPanel.Visibility = index == 3 ? Visibility.Visible : Visibility.Collapsed;
        SettingsPanel.Visibility = index == 4 ? Visibility.Visible : Visibility.Collapsed;
        LogsPanel.Visibility = index == 5 ? Visibility.Visible : Visibility.Collapsed;

        Style normal = (Style)FindResource("SidebarNavBtn");
        Style active = (Style)FindResource("SidebarNavActiveBtn");
        NavWifiBtn.Style = index == 0 ? active : normal;
        NavUsbBtn.Style = index == 1 ? active : normal;
        NavHostBtn.Style = index == 2 ? active : normal;
        NavHistoryBtn.Style = index == 3 ? active : normal;
        NavSettingsBtn.Style = index == 4 ? active : normal;
        NavLogsBtn.Style = index == 5 ? active : normal;

        if (index == 1) RefreshUsbDevicesList();
        if (index == 2) RefreshHostUI();
        if (index == 5) RefreshLogsView();
    }

    private void NavWifiBtn_Click(object sender, RoutedEventArgs e) => SwitchNav(0);
    private void NavUsbBtn_Click(object sender, RoutedEventArgs e) => SwitchNav(1);
    private void NavHostBtn_Click(object sender, RoutedEventArgs e) => SwitchNav(2);
    private void NavHistoryBtn_Click(object sender, RoutedEventArgs e) => SwitchNav(3);
    private void NavSettingsBtn_Click(object sender, RoutedEventArgs e) => SwitchNav(4);
    private void NavLogsBtn_Click(object sender, RoutedEventArgs e) => SwitchNav(5);

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (Keyboard.FocusedElement is TextBox) return;
        if (e.Key == Key.A && Keyboard.Modifiers == ModifierKeys.Control)
        {
            if (_activeNav == 0 && _client is not null) { SelectAllWifi(); e.Handled = true; }
            else if (_activeNav == 1 && _usb.IsConnected) { SelectAllUsb(); e.Handled = true; }
        }
        else if (e.Key == Key.Escape)
        {
            if (_activeNav == 0 && _client is not null) { DeselectAllWifi(); e.Handled = true; }
            else if (_activeNav == 1 && _usb.IsConnected) { DeselectAllUsb(); e.Handled = true; }
        }
        else if (e.Key == Key.Enter)
        {
            if (_activeNav == 0 && _client is not null) { WifiOpenFolderBtn_Click(this, new RoutedEventArgs()); e.Handled = true; }
            else if (_activeNav == 1 && _usb.IsConnected) { UsbOpenFolderBtn_Click(this, new RoutedEventArgs()); e.Handled = true; }
        }
    }

    #endregion

    #region QR Code Scanning on PC

    private void QrScanBtn_Click(object sender, RoutedEventArgs e)
    {
        var win = new QrScanWindow { Owner = this };
        if (win.ShowDialog() == true && !string.IsNullOrWhiteSpace(win.ScannedPayload))
        {
            ApplyQrPayloadAndConnect(win.ScannedPayload);
        }
    }

    private void ApplyQrPayloadAndConnect(string raw)
    {
        string clean = raw.Trim();
        string noScheme = clean.Replace("http://", "", StringComparison.OrdinalIgnoreCase)
                               .Replace("https://", "", StringComparison.OrdinalIgnoreCase);
        int qIdx = noScheme.IndexOf('?');
        string hostPart = (qIdx >= 0 ? noScheme[..qIdx] : noScheme).Split('/')[0].Trim();
        string? pin = null;
        if (qIdx >= 0)
        {
            string qs = noScheme[(qIdx + 1)..];
            foreach (string kv in qs.Split('&', StringSplitOptions.RemoveEmptyEntries))
            {
                int eq = kv.IndexOf('=');
                if (eq > 0 && string.Equals(kv[..eq], "pin", StringComparison.OrdinalIgnoreCase))
                {
                    pin = Uri.UnescapeDataString(kv[(eq + 1)..]).Trim();
                }
            }
        }

        if (string.IsNullOrWhiteSpace(hostPart))
        {
            MessageBox.Show(this, $"QR code did not contain a valid WQGlass address:\n{raw}", "QR Scan", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        if (_client is not null) Disconnect();
        EndpointBox.Text = hostPart;
        if (!string.IsNullOrWhiteSpace(pin))
        {
            PinBox.Text = pin;
            ConnectBtn_Click(this, new RoutedEventArgs());
        }
        else
        {
            PinBox.Focus();
            TransferStatusText.Text = $"QR scanned ({hostPart}). Enter PIN and click Connect.";
        }
    }

    #endregion

    #region Wi-Fi Client Mode (Multi-Select, Filters, Parallel Streams)

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
            WifiCountText.Text = _phones.Count.ToString();
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
        if (_client is null) StatusBadgeText.Text = "Scanning Wi-Fi for iPhone, Android & PC…";
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
            MessageBox.Show(this, "Select a discovered device, enter an IP:Port, or click Scan QR.", "WQGlass Transfer", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        if (pin.Length < 4)
        {
            MessageBox.Show(this, "Enter the 4–8 digit pairing PIN shown on the target device.", "WQGlass Transfer", MessageBoxButton.OK, MessageBoxImage.Information);
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
            bool isUsbTunnel = ep.StartsWith("127.0.0.1:", StringComparison.OrdinalIgnoreCase);
            string transportTag = isUsbTunnel ? "🔌 USB Cable" : "📡 Wi-Fi";
            StatusBadgeText.Text = $"● {transportTag} · {info.PlatformIcon} {info.Device} [{info.OsSummary}] · /{info.Root}";
            StatusBadgeText.Foreground = new SolidColorBrush(Color.FromRgb(74, 222, 128));
            StorageLabel.Text = $"{RemoteFileItem.FormatBytes(info.FreeBytes)} free / {RemoteFileItem.FormatBytes(info.TotalBytes)}";
            StorageUsedBar.Value = info.UsedPercent;
            StorageMeterPanel.Visibility = info.TotalBytes > 0 ? Visibility.Visible : Visibility.Collapsed;
            IphoneRootsBar.Visibility = info.NormalizedPlatform == "ios" ? Visibility.Visible : Visibility.Collapsed;
            AppLogger.Info("Client", $"Connected to {info.Device} ({info.NormalizedPlatform} {info.OsSummary}) at {ep} · root=/{info.Root}");
            SetWifiConnectedUI(true);
            await RefreshDirectoryAsync();
        }
        catch (Exception ex)
        {
            AppLogger.Error("Client", $"Failed connecting to {ep}", ex);
            StatusBadgeText.Text = "Connection failed";
            MessageBox.Show(this, ex.Message, "Could Not Connect", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            ConnectBtn.IsEnabled = true;
        }
    }

    private async void IphoneRootSwitch_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null || sender is not Button btn || btn.Tag is not string rootId) return;
        try
        {
            await _client.SwitchRemoteRootAsync(rootId);
            _phoneInfo = await _client.GetInfoAsync();
            _currentPath = "";
            string ep = EndpointBox.Text.Trim();
            string transportTag = ep.StartsWith("127.0.0.1:", StringComparison.OrdinalIgnoreCase) ? "🔌 USB Cable" : "📡 Wi-Fi";
            StatusBadgeText.Text = $"● {transportTag} · {_phoneInfo.PlatformIcon} {_phoneInfo.Device} [{_phoneInfo.OsSummary}] · /{_phoneInfo.Root}";
            AppLogger.Info("Client", $"Switched iPhone shared folder to /{_phoneInfo.Root} (id={rootId})");
            await RefreshDirectoryAsync();
        }
        catch (Exception ex)
        {
            AppLogger.Error("Client", $"Failed switching iPhone folder (id={rootId})", ex);
            MessageBox.Show(this, $"Could not switch iPhone folder: {ex.Message}", "Switch Folder", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async void WifiOpenFolderBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null) return;
        var dir = GetSelectedWifiItems().FirstOrDefault(i => i.IsDir)
                  ?? (FilesList.SelectedItem is RemoteFileItem fi && fi.IsDir ? fi : null);
        if (dir is null) return;
        _currentPath = dir.Path;
        await RefreshDirectoryAsync();
    }

    private void Disconnect()
    {
        _transferCts?.Cancel();
        _client?.Dispose();
        _client = null;
        _phoneInfo = null;
        _appleMux.StopTunnel();
        _allItems.Clear();
        _visibleItems.Clear();
        _currentPath = "";
        ConnectBtn.Content = "Connect";
        StatusBadgeText.Text = _phones.Count > 0 ? $"Found {_phones.Count} device(s) on Wi-Fi" : "Disconnected";
        StatusBadgeText.Foreground = (Brush)FindResource("AccentCyan");
        StorageMeterPanel.Visibility = Visibility.Collapsed;
        IphoneRootsBar.Visibility = Visibility.Collapsed;
        PathLabel.Text = "Not connected — Pick a Wi-Fi device above, Scan QR, or switch to 🔌 USB Cable";
        SetWifiConnectedUI(false);
    }

    private void SetWifiConnectedUI(bool connected)
    {
        SendFilesBtn.IsEnabled = connected;
        SendFolderBtn.IsEnabled = connected;
        NewFolderBtn.IsEnabled = connected;
        SendTextBtn.IsEnabled = connected;
        SelectAllBtn.IsEnabled = connected;
        DeselectAllBtn.IsEnabled = connected;
        InvertSelBtn.IsEnabled = connected;
        UpBtn.IsEnabled = connected && !string.IsNullOrEmpty(_currentPath);
        RefreshBtn.IsEnabled = connected;
        UpdateWifiSelectionState();
    }

    private List<RemoteFileItem> GetSelectedWifiItems()
    {
        var checkedItems = _visibleItems.Where(i => i.IsSelected).ToList();
        if (checkedItems.Count > 0) return checkedItems;
        return FilesList.SelectedItems.Cast<RemoteFileItem>().ToList();
    }

    private void UpdateWifiSelectionState()
    {
        var sel = GetSelectedWifiItems();
        bool hasSel = _client is not null && sel.Count > 0;
        DownloadBtn.IsEnabled = hasSel;
        DeleteBtn.IsEnabled = hasSel;
        RenameBtn.IsEnabled = _client is not null && sel.Count == 1;
        WifiOpenFolderBtn.IsEnabled = _client is not null && sel.Any(i => i.IsDir);

        long totalBytes = sel.Where(i => !i.IsDir).Sum(i => i.Size);
        int folders = sel.Count(i => i.IsDir);
        if (sel.Count == 0)
            WifiSelectionSummary.Text = "0 selected";
        else if (folders > 0 && totalBytes > 0)
            WifiSelectionSummary.Text = $"{sel.Count} selected ({folders} folder(s) + {RemoteFileItem.FormatBytes(totalBytes)})";
        else if (folders > 0)
            WifiSelectionSummary.Text = $"{folders} folder(s) selected";
        else
            WifiSelectionSummary.Text = $"{sel.Count} selected · {RemoteFileItem.FormatBytes(totalBytes)}";
    }

    private void SelectAllWifi()
    {
        foreach (var it in _visibleItems) it.IsSelected = true;
        UpdateWifiSelectionState();
    }

    private void DeselectAllWifi()
    {
        foreach (var it in _visibleItems) it.IsSelected = false;
        FilesList.UnselectAll();
        UpdateWifiSelectionState();
    }

    private void SelectAllBtn_Click(object sender, RoutedEventArgs e) => SelectAllWifi();
    private void DeselectAllBtn_Click(object sender, RoutedEventArgs e) => DeselectAllWifi();

    private void InvertSelBtn_Click(object sender, RoutedEventArgs e)
    {
        foreach (var it in _visibleItems) it.IsSelected = !it.IsSelected;
        UpdateWifiSelectionState();
    }

    private void WifiItemCheckBox_Click(object sender, RoutedEventArgs e) => UpdateWifiSelectionState();
    private void FilesList_SelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateWifiSelectionState();

    private void WifiCategoryChip_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button btn || btn.Tag is not string cat) return;
        _wifiCategory = cat;
        Style inactive = (Style)FindResource("FilterChipBtn");
        Style active = (Style)FindResource("FilterChipActiveBtn");
        foreach (Button b in new[] { ChipAll, ChipFolders, ChipVideos, ChipPhotos, ChipAudio, ChipDocs, ChipArchives })
            b.Style = ReferenceEquals(b, btn) ? active : inactive;
        ApplyWifiFilterAndSort();
    }

    private void SortBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_allItems.Count > 0) ApplyWifiFilterAndSort();
    }

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e) => ApplyWifiFilterAndSort();

    private async Task RefreshDirectoryAsync()
    {
        if (_client is null) return;
        try
        {
            RemoteListResponse res = await _client.ListAsync(_currentPath);
            _allItems.Clear();
            _allItems.AddRange(res.Items);
            ApplyWifiFilterAndSort();
            string rootName = _phoneInfo?.Root ?? "Downloads";
            PathLabel.Text = string.IsNullOrEmpty(_currentPath)
                ? $"/{rootName}   ({_allItems.Count} items)"
                : $"/{rootName}/{_currentPath}   ({_allItems.Count} items)";
            UpBtn.IsEnabled = !string.IsNullOrEmpty(_currentPath);
        }
        catch (Exception ex)
        {
            AppLogger.Error("Client", $"RefreshDirectoryAsync failed at path '{_currentPath}'", ex);
            TransferStatusText.Text = $"Refresh failed: {ex.Message}";
            if (ex.Message.Contains("403", StringComparison.OrdinalIgnoreCase) ||
                ex.Message.Contains("All Files Access", StringComparison.OrdinalIgnoreCase) ||
                ex.Message.Contains("permission", StringComparison.OrdinalIgnoreCase))
            {
                PathLabel.Text = "⚠ Android Storage Permission Needed — Tap 'Grant' inside WQGlass Transfer on your Android phone";
                MessageBox.Show(this,
                    "Android is currently blocking access to that folder.\n\n" +
                    "On your Android phone, open WQGlass Transfer → Share Device tab and tap the amber 'Grant' button to allow Storage / All Files Access, then click Refresh here.",
                    "Android Storage Permission Needed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }
    }

    private static bool IsClickOnCheckBox(DependencyObject? src)
    {
        while (src is not null)
        {
            if (src is CheckBox) return true;
            src = VisualTreeHelper.GetParent(src);
        }
        return false;
    }

    private void ApplyWifiFilterAndSort()
    {
        string q = SearchBox?.Text?.Trim() ?? "";
        IEnumerable<RemoteFileItem> filtered = _allItems.Where(item =>
            (_wifiCategory == "All" || string.Equals(item.Category, _wifiCategory, StringComparison.OrdinalIgnoreCase)) &&
            (string.IsNullOrEmpty(q) || item.Name.Contains(q, StringComparison.OrdinalIgnoreCase)));

        int sortIdx = SortBox?.SelectedIndex ?? 0;
        filtered = sortIdx switch
        {
            1 => filtered.OrderByDescending(i => i.IsDir).ThenByDescending(i => i.Size),
            2 => filtered.OrderByDescending(i => i.IsDir).ThenByDescending(i => i.Mtime),
            3 => filtered.OrderByDescending(i => i.IsDir).ThenBy(i => i.TypeLabel, StringComparer.OrdinalIgnoreCase).ThenBy(i => i.Name, StringComparer.OrdinalIgnoreCase),
            _ => filtered.OrderByDescending(i => i.IsDir).ThenBy(i => i.Name, StringComparer.OrdinalIgnoreCase)
        };

        _visibleItems.Clear();
        foreach (var item in filtered) _visibleItems.Add(item);
        UpdateWifiSelectionState();
    }

    private async void FilesList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (IsClickOnCheckBox(e.OriginalSource as DependencyObject)) return;
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
            await UploadLocalPathsAsync(dlg.FileNames);
    }

    private async void SendFolderBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null) return;
        var dlg = new OpenFolderDialog { Title = "Select Folder to Send" };
        if (dlg.ShowDialog(this) == true && !string.IsNullOrWhiteSpace(dlg.FolderName))
            await UploadLocalPathsAsync(new[] { dlg.FolderName });
    }

    private async void DownloadBtn_Click(object sender, RoutedEventArgs e)
    {
        var sel = GetSelectedWifiItems();
        if (_client is null || sel.Count == 0) return;
        await DownloadItemsAsync(sel);
    }

    private async void SendTextBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null) return;
        string initial = Clipboard.ContainsText() ? Clipboard.GetText() : "";
        if (initial.Length > 2000) initial = initial[..2000];
        string? text = PromptInput("Send Text / Link", $"Send a note or URL to {_phoneInfo?.Device ?? "device"}:", initial);
        if (string.IsNullOrWhiteSpace(text)) return;
        try
        {
            await _client.SendClipboardTextAsync(text);
            TransferStatusText.Text = $"📋 Sent text/link ({text.Length} chars) to {_phoneInfo?.Device ?? "device"}!";
        }
        catch (Exception ex)
        {
            AppLogger.Error("Client", "SendClipboardTextAsync failed", ex);
            MessageBox.Show(this, $"Target device may not support /api/text yet: {ex.Message}", "Send Text", MessageBoxButton.OK, MessageBoxImage.Information);
        }
    }

    private async Task DownloadItemsAsync(IReadOnlyList<RemoteFileItem> items)
    {
        if (_client is null || items.Count == 0) return;
        Directory.CreateDirectory(_pcDownloadDir);

        var fileJobs = new List<(string remotePath, string localPath, long estSize)>();
        async Task CollectRemoteAsync(RemoteFileItem it, string localBase)
        {
            if (it.IsDir)
            {
                string subLocal = Path.Combine(localBase, it.Name);
                Directory.CreateDirectory(subLocal);
                var listing = await _client.ListAsync(it.Path);
                foreach (var child in listing.Items)
                    await CollectRemoteAsync(child, subLocal);
            }
            else
            {
                fileJobs.Add((it.Path, Path.Combine(localBase, it.Name), it.Size));
            }
        }

        BeginTransferUI("Scanning folders & preparing batch download…");
        var sw = Stopwatch.StartNew();
        long totalDoneBytes = 0;
        int completedCount = 0;
        try
        {
            foreach (var it in items) await CollectRemoteAsync(it, _pcDownloadDir);
            if (fileJobs.Count == 0) { EndTransferUI("No files found inside selected folder(s)."); return; }

            long grandTotal = fileJobs.Sum(j => Math.Max(0, j.estSize));
            using var sem = new SemaphoreSlim(Math.Min(_parallelStreams, fileJobs.Count));
            var tasks = new List<Task>();
            var progress = CreateProgressHandler("Downloading", grandTotal);

            for (int i = 0; i < fileJobs.Count; i++)
            {
                int idx = i;
                var job = fileJobs[i];
                tasks.Add(Task.Run(async () =>
                {
                    await sem.WaitAsync(_transferCts!.Token);
                    try
                    {
                        var fsw = Stopwatch.StartNew();
                        long bytes = await _client.DownloadFileAsync(job.remotePath, job.localPath, idx + 1, fileJobs.Count, _conflictPolicy, progress, _transferCts.Token);
                        Interlocked.Add(ref totalDoneBytes, bytes);
                        Interlocked.Increment(ref completedCount);
                        double bps = fsw.Elapsed.TotalSeconds > 0.01 ? bytes / fsw.Elapsed.TotalSeconds : 0;
                        RecordHistory("Wi-Fi", "↓", Path.GetFileName(job.localPath), bytes, bps, "Completed", job.localPath);
                    }
                    finally { sem.Release(); }
                }, _transferCts!.Token));
            }

            await Task.WhenAll(tasks);
            double avgBps = sw.Elapsed.TotalSeconds > 0.05 ? totalDoneBytes / sw.Elapsed.TotalSeconds : 0;
            AppLogger.Info("Client", $"Downloaded {completedCount} file(s) ({RemoteFileItem.FormatBytes(totalDoneBytes)}) at {RemoteFileItem.FormatBytes((long)avgBps)}/s");
            EndTransferUI($"Downloaded {completedCount} file(s) ({RemoteFileItem.FormatBytes(totalDoneBytes)}) at {RemoteFileItem.FormatBytes((long)avgBps)}/s → {_pcDownloadDir}");
        }
        catch (OperationCanceledException)
        {
            AppLogger.Warn("Client", "Batch download cancelled by user.");
            EndTransferUI("Download cancelled.");
        }
        catch (Exception ex)
        {
            AppLogger.Error("Client", "Batch download failed", ex);
            EndTransferUI($"Download error: {ex.Message}");
            MessageBox.Show(this, ex.Message, "Download Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async Task UploadLocalPathsAsync(IReadOnlyList<string> localPaths)
    {
        if (_client is null || localPaths.Count == 0) return;
        var jobs = new List<(string localFile, string remoteDir, long size)>();

        void CollectLocal(string path, string remoteBase)
        {
            if (Directory.Exists(path))
            {
                string folderName = Path.GetFileName(path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
                string nextRemote = string.IsNullOrEmpty(remoteBase) ? folderName : $"{remoteBase}/{folderName}";
                foreach (string file in Directory.GetFiles(path))
                    jobs.Add((file, nextRemote, new FileInfo(file).Length));
                foreach (string sub in Directory.GetDirectories(path))
                    CollectLocal(sub, nextRemote);
            }
            else if (File.Exists(path))
            {
                jobs.Add((path, remoteBase, new FileInfo(path).Length));
            }
        }

        foreach (string p in localPaths) CollectLocal(p, _currentPath);
        if (jobs.Count == 0) return;

        string targetName = _phoneInfo?.Device ?? "device";
        long grandTotal = jobs.Sum(j => j.size);
        BeginTransferUI($"Sending {jobs.Count} file(s) ({RemoteFileItem.FormatBytes(grandTotal)}) to {targetName} ({_parallelStreams}x streams)…");
        var sw = Stopwatch.StartNew();
        long totalSent = 0;

        try
        {
            using var sem = new SemaphoreSlim(Math.Min(_parallelStreams, jobs.Count));
            var tasks = new List<Task>();
            var progress = CreateProgressHandler("Sending", grandTotal);

            for (int i = 0; i < jobs.Count; i++)
            {
                int idx = i;
                var job = jobs[i];
                tasks.Add(Task.Run(async () =>
                {
                    await sem.WaitAsync(_transferCts!.Token);
                    try
                    {
                        var fsw = Stopwatch.StartNew();
                        long bytes = await _client.UploadFileAsync(job.remoteDir, job.localFile, idx + 1, jobs.Count, progress, _transferCts.Token);
                        Interlocked.Add(ref totalSent, bytes);
                        double bps = fsw.Elapsed.TotalSeconds > 0.01 ? bytes / fsw.Elapsed.TotalSeconds : 0;
                        RecordHistory("Wi-Fi", "↑", Path.GetFileName(job.localFile), bytes, bps, "Completed", job.localFile);
                    }
                    finally { sem.Release(); }
                }, _transferCts!.Token));
            }

            await Task.WhenAll(tasks);
            double avgBps = sw.Elapsed.TotalSeconds > 0.05 ? totalSent / sw.Elapsed.TotalSeconds : 0;
            AppLogger.Info("Client", $"Uploaded {jobs.Count} file(s) ({RemoteFileItem.FormatBytes(totalSent)}) to {targetName} at {RemoteFileItem.FormatBytes((long)avgBps)}/s");
            EndTransferUI($"Sent {jobs.Count} file(s) ({RemoteFileItem.FormatBytes(totalSent)}) to {targetName} at {RemoteFileItem.FormatBytes((long)avgBps)}/s!");
            await RefreshDirectoryAsync();
        }
        catch (OperationCanceledException)
        {
            AppLogger.Warn("Client", "Batch upload cancelled by user.");
            EndTransferUI("Upload cancelled.");
        }
        catch (Exception ex)
        {
            AppLogger.Error("Client", "Batch upload failed", ex);
            EndTransferUI($"Upload error: {ex.Message}");
            MessageBox.Show(this, ex.Message, "Upload Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async void NewFolderBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null) return;
        string? name = PromptInput("New Folder", $"Enter folder name to create on {_phoneInfo?.Device ?? "device"}:", "");
        if (string.IsNullOrWhiteSpace(name)) return;
        string target = string.IsNullOrEmpty(_currentPath) ? name.Trim() : $"{_currentPath}/{name.Trim()}";
        try { await _client.CreateFolderAsync(target); await RefreshDirectoryAsync(); }
        catch (Exception ex) { AppLogger.Error("Client", $"CreateFolderAsync failed for '{target}'", ex); MessageBox.Show(this, ex.Message, "New Folder Failed", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private async void RenameBtn_Click(object sender, RoutedEventArgs e)
    {
        var sel = GetSelectedWifiItems();
        if (_client is null || sel.Count != 1) return;
        var item = sel[0];
        string? newName = PromptInput("Rename", $"Rename '{item.Name}' to:", item.Name);
        if (string.IsNullOrWhiteSpace(newName) || newName.Trim() == item.Name) return;
        try { await _client.RenameAsync(item.Path, newName.Trim()); await RefreshDirectoryAsync(); }
        catch (Exception ex) { AppLogger.Error("Client", $"RenameAsync failed for '{item.Path}'", ex); MessageBox.Show(this, ex.Message, "Rename Failed", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private async void DeleteBtn_Click(object sender, RoutedEventArgs e)
    {
        var items = GetSelectedWifiItems();
        if (_client is null || items.Count == 0) return;
        var confirm = MessageBox.Show(this, $"Delete {items.Count} selected item(s) from {_phoneInfo?.Device ?? "device"}?", "Confirm Delete", MessageBoxButton.YesNo, MessageBoxImage.Warning);
        if (confirm != MessageBoxResult.Yes) return;
        try
        {
            foreach (var it in items) await _client.DeleteAsync(it.Path);
            await RefreshDirectoryAsync();
        }
        catch (Exception ex) { AppLogger.Error("Client", "DeleteAsync failed", ex); MessageBox.Show(this, ex.Message, "Delete Failed", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    #endregion

    #region USB Cable Mode (Native WPD/MTP + Apple usbmuxd + ADB USB Bridge)

    private async void RefreshUsbDevicesList()
    {
        try
        {
            var wpdTask = _usb.EnumerateConnectedDevicesAsync();
            var appleTask = Task.Run(() => _appleMux.ListUsbDevices());
            await Task.WhenAll(wpdTask, appleTask);

            var found = wpdTask.Result;
            var appleDevs = appleTask.Result;

            string? selectedId = (UsbDevicesBox.SelectedItem as UsbDeviceSummary)?.DeviceId;
            _usbDevices.Clear();
            foreach (var d in found) _usbDevices.Add(d);

            int totalDetected = Math.Max(_usbDevices.Count, appleDevs.Count);
            UsbCountText.Text = totalDetected.ToString();

            if (_usbDevices.Count > 0)
            {
                var match = _usbDevices.FirstOrDefault(d => d.DeviceId == selectedId) ?? _usbDevices[0];
                UsbDevicesBox.SelectedItem = match;
                if (!_usb.IsConnected)
                {
                    UsbStatusBadge.Text = appleDevs.Count > 0
                        ? $"Detected {_usbDevices.Count} USB device(s) + iPhone USB App Docs ready — click 🍎 iPhone App Docs (USB) or Open USB Device"
                        : $"Detected {_usbDevices.Count} USB cable device(s) — click Open USB Device";
                }
            }
            else if (appleDevs.Count > 0 && !_usb.IsConnected)
            {
                UsbStatusBadge.Text = $"🍎 Detected {appleDevs.Count} iPhone over USB — click 🍎 iPhone App Docs (USB) for Documents & Downloads";
            }
            else if (!_usb.IsConnected)
            {
                UsbStatusBadge.Text = "No USB phone detected — plug in Android (File Transfer/MTP) or iPhone & unlock";
            }
        }
        catch
        {
            // Ignore transient hot-plug enumeration failures.
        }
    }

    private void UsbDetectBtn_Click(object sender, RoutedEventArgs e) => RefreshUsbDevicesList();

    private async void UsbIphoneAppBtn_Click(object sender, RoutedEventArgs e)
    {
        UsbIphoneAppBtn.IsEnabled = false;
        UsbStatusBadge.Text = "Searching for iPhone via Apple USB cable (usbmuxd)…";
        try
        {
            var devices = await Task.Run(() => _appleMux.ListUsbDevices());
            if (devices.Count == 0)
            {
                UsbStatusBadge.Text = "No iPhone detected on Apple USB service.";
                MessageBox.Show(this,
                    "No iPhone was detected on Apple's USB service (usbmuxd).\n\n" +
                    "To connect iPhone App Documents & Downloads over Lightning/USB-C (like iTunes / 3uTools):\n" +
                    "1. Plug your iPhone into this PC with a USB cable and tap 'Trust This Computer'.\n" +
                    "2. Make sure Apple Devices or iTunes (or 3uTools driver) is installed on Windows so Apple Mobile Device Service is running.\n" +
                    "3. Open WQ Glass on your iPhone → LAN Transfer (Share iPhone) — works even with Wi-Fi OFF!",
                    "iPhone USB App Documents",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            AppleUsbDeviceInfo target = devices[0];
            UsbStatusBadge.Text = $"Opening direct USB cable tunnel to iPhone WQ Glass…";

            (bool ok, string localEndpoint, string? err) = await Task.Run(() =>
            {
                string? lastErr = null;
                for (int port = 8765; port <= 8768; port++)
                {
                    if (_appleMux.StartTunnel(target.DeviceId, port, out string ep, out string? eMsg))
                        return (true, ep, (string?)null);
                    lastErr = eMsg;
                }
                return (false, "", lastErr);
            });

            if (!ok)
            {
                AppLogger.Error("AppleUsbMux", "Could not start USB tunnel to iPhone WQ Glass", err);
                UsbStatusBadge.Text = "iPhone WQ Glass server not reachable over USB.";
                MessageBox.Show(this,
                    (err ?? "Could not reach WQ Glass on iPhone over USB.") +
                    "\n\nOpen WQ Glass on your iPhone → Utility Hub → LAN Transfer (Share iPhone) and keep that screen open, then try again.",
                    "iPhone USB App Documents",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            AppLogger.Info("AppleUsbMux", $"Started iPhone USB tunnel at {localEndpoint} (DeviceID={target.DeviceId})");
            string defaultPin = PinBox.Text.Trim();
            string? pin = PromptInput(
                "iPhone USB Cable Ready (App Documents & Downloads)",
                "Connected directly to iPhone over USB cable!\nEnter the 4–8 digit PIN shown on your iPhone WQ Glass screen:",
                defaultPin);

            if (string.IsNullOrWhiteSpace(pin))
            {
                UsbStatusBadge.Text = $"🍎 iPhone USB tunnel ready at {localEndpoint} — enter PIN in Wi-Fi / USB Explorer to connect.";
                return;
            }

            if (_client is not null) Disconnect();
            SwitchNav(0);
            EndpointBox.Text = localEndpoint;
            PinBox.Text = pin.Trim();
            ConnectBtn_Click(sender, e);
        }
        finally
        {
            UsbIphoneAppBtn.IsEnabled = true;
        }
    }

    private async void UsbConnectBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_usb.IsConnected)
        {
            await _usb.DisconnectAsync();
            AppLogger.Info("USB-MTP", "Disconnected USB device.");
            _allUsbItems.Clear();
            _visibleUsbItems.Clear();
            _usbCurrentPath = "\\";
            UsbConnectBtn.Content = "🔌 Open USB Device";
            UsbStatusBadge.Text = "USB device disconnected.";
            UsbPathLabel.Text = "No USB device opened — Select a device above and click Open USB Device";
            SetUsbConnectedUI(false);
            return;
        }

        if (UsbDevicesBox.SelectedItem is not UsbDeviceSummary summary)
        {
            MessageBox.Show(this, "Plug in an Android phone (File Transfer / MTP mode) or iPhone via USB cable and click Detect USB.", "USB Transfer", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        UsbConnectBtn.IsEnabled = false;
        UsbStatusBadge.Text = $"Opening {summary.FriendlyName} over USB…";
        try
        {
            var (ok, err) = await _usb.ConnectAsync(summary);
            if (!ok)
            {
                AppLogger.Error("USB-MTP", $"Failed opening USB device '{summary.DisplayName}'", err);
                UsbStatusBadge.Text = "USB open failed";
                MessageBox.Show(this, err ?? "Could not open USB device.", "USB Cable Transfer", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            AppLogger.Info("USB-MTP", $"Connected USB device: {summary.DisplayName} (ID={summary.DeviceId})");
            _usbCurrentPath = "\\";
            UsbConnectBtn.Content = "Disconnect USB";
            UsbStatusBadge.Text = summary.IsApple
                ? $"● USB Connected: {summary.DisplayName} (Camera Roll · For App Documents click 🍎 iPhone App Docs)"
                : $"● USB Cable Connected: {summary.DisplayName}";
            SetUsbConnectedUI(true);
            await RefreshUsbDirectoryAsync();

            // Auto-enter single storage volume (e.g. Android "Internal shared storage" or iPhone "Internal Storage")
            // so users immediately see their folders and files without an extra step.
            if (_allUsbItems.Count == 1 && _allUsbItems[0].IsDir)
            {
                _usbCurrentPath = _allUsbItems[0].FullPath;
                await RefreshUsbDirectoryAsync();
            }
            else if (_allUsbItems.Count == 0)
            {
                AppLogger.Warn("USB-MTP", $"USB device '{summary.DisplayName}' returned 0 root storage volumes.");
                UsbStatusBadge.Text = summary.IsApple
                    ? "iPhone storage empty — unlock iPhone, tap 'Trust', or click 🍎 iPhone App Docs (USB)!"
                    : "Android storage empty — unlock phone, tap USB notification and pick 'File Transfer (MTP)'!";
                UsbPathLabel.Text = UsbStatusBadge.Text;
            }
        }
        finally
        {
            UsbConnectBtn.IsEnabled = true;
        }
    }

    private void UsbAdbBridgeBtn_Click(object sender, RoutedEventArgs e)
    {
        bool ok = UsbTransferService.TrySetupAdbUsbTunnel(18765, 8765, out string msg);
        if (ok) AppLogger.Info("ADB-USB", msg);
        else AppLogger.Warn("ADB-USB", msg);
        MessageBox.Show(this, msg, "ADB USB Turbo Bridge", MessageBoxButton.OK, ok ? MessageBoxImage.Information : MessageBoxImage.Warning);
        if (ok)
        {
            if (_client is not null) Disconnect();
            EndpointBox.Text = "127.0.0.1:18765";
            SwitchNav(0);
            PinBox.Focus();
        }
    }

    private void SetUsbConnectedUI(bool connected)
    {
        bool isApple = _usb.ConnectedSummary?.IsApple == true;
        UsbImportFilesBtn.IsEnabled = connected && !isApple;
        UsbImportFolderBtn.IsEnabled = connected && !isApple;
        UsbNewFolderBtn.IsEnabled = connected && !isApple;
        UsbSelectAllBtn.IsEnabled = connected;
        UsbDeselectAllBtn.IsEnabled = connected;
        UsbInvertSelBtn.IsEnabled = connected;
        UsbUpBtn.IsEnabled = connected && _usbCurrentPath != "\\";
        UsbRefreshBtn.IsEnabled = connected;
        UpdateUsbSelectionState();
    }

    private async Task RefreshUsbDirectoryAsync()
    {
        if (!_usb.IsConnected) return;
        try
        {
            var listed = await _usb.ListDirectoryAsync(_usbCurrentPath);
            _allUsbItems.Clear();
            _allUsbItems.AddRange(listed);
            ApplyUsbFilter();
            UsbPathLabel.Text = $"USB:{_usbCurrentPath}   ({_allUsbItems.Count} items)";
            UsbUpBtn.IsEnabled = _usbCurrentPath != "\\";
            TransferStatusText.Text = _allUsbItems.Count == 0
                ? $"USB:{_usbCurrentPath} is empty (if Android, ensure USB mode is set to 'File Transfer / MTP' and phone is unlocked)."
                : $"Opened USB:{_usbCurrentPath} ({_allUsbItems.Count} items) — double-click any folder or click 📂 Open Folder to browse inside.";
        }
        catch (Exception ex)
        {
            AppLogger.Error("USB-MTP", $"Failed reading USB folder '{_usbCurrentPath}'", ex);
            TransferStatusText.Text = $"USB folder read error: {ex.Message}";
            UsbStatusBadge.Text = $"USB read error: {ex.Message}";
        }
    }

    private void ApplyUsbFilter()
    {
        string q = UsbSearchBox?.Text?.Trim() ?? "";
        _visibleUsbItems.Clear();
        foreach (var it in _allUsbItems)
        {
            if ((_usbCategory == "All" || string.Equals(it.Category, _usbCategory, StringComparison.OrdinalIgnoreCase)) &&
                (string.IsNullOrEmpty(q) || it.Name.Contains(q, StringComparison.OrdinalIgnoreCase)))
            {
                _visibleUsbItems.Add(it);
            }
        }
        UpdateUsbSelectionState();
    }

    private List<UsbFileItem> GetSelectedUsbItems()
    {
        var checkedItems = _visibleUsbItems.Where(i => i.IsSelected).ToList();
        if (checkedItems.Count > 0) return checkedItems;
        return UsbFilesList.SelectedItems.Cast<UsbFileItem>().ToList();
    }

    private void UpdateUsbSelectionState()
    {
        var sel = GetSelectedUsbItems();
        bool hasSel = _usb.IsConnected && sel.Count > 0;
        UsbExportBtn.IsEnabled = hasSel;
        UsbOpenFolderBtn.IsEnabled = _usb.IsConnected && sel.Any(i => i.IsDir);
        UsbDeleteBtn.IsEnabled = hasSel && _usb.ConnectedSummary?.IsApple != true;
        long total = sel.Where(i => !i.IsDir).Sum(i => i.Size);
        int folders = sel.Count(i => i.IsDir);
        UsbSelectionSummary.Text = sel.Count == 0
            ? "0 selected"
            : folders > 0 ? $"{sel.Count} selected ({folders} folder(s))" : $"{sel.Count} selected · {RemoteFileItem.FormatBytes(total)}";
    }

    private void SelectAllUsb() { foreach (var it in _visibleUsbItems) it.IsSelected = true; UpdateUsbSelectionState(); }
    private void DeselectAllUsb() { foreach (var it in _visibleUsbItems) it.IsSelected = false; UsbFilesList.UnselectAll(); UpdateUsbSelectionState(); }
    private void UsbSelectAllBtn_Click(object sender, RoutedEventArgs e) => SelectAllUsb();
    private void UsbDeselectAllBtn_Click(object sender, RoutedEventArgs e) => DeselectAllUsb();
    private void UsbInvertSelBtn_Click(object sender, RoutedEventArgs e) { foreach (var it in _visibleUsbItems) it.IsSelected = !it.IsSelected; UpdateUsbSelectionState(); }
    private void UsbItemCheckBox_Click(object sender, RoutedEventArgs e) => UpdateUsbSelectionState();
    private void UsbFilesList_SelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateUsbSelectionState();
    private void UsbSearchBox_TextChanged(object sender, TextChangedEventArgs e) => ApplyUsbFilter();

    private void UsbCategoryChip_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button btn || btn.Tag is not string cat) return;
        _usbCategory = cat;
        Style inactive = (Style)FindResource("FilterChipBtn");
        Style active = (Style)FindResource("FilterChipActiveBtn");
        foreach (Button b in new[] { UsbChipAll, UsbChipFolders, UsbChipVideos, UsbChipPhotos, UsbChipAudio, UsbChipDocs })
            b.Style = ReferenceEquals(b, btn) ? active : inactive;
        ApplyUsbFilter();
    }

    private async void UsbOpenFolderBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!_usb.IsConnected) return;
        var dir = GetSelectedUsbItems().FirstOrDefault(i => i.IsDir);
        if (dir is null) return;
        _usbCurrentPath = dir.FullPath;
        await RefreshUsbDirectoryAsync();
    }

    private async void UsbFilesList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (IsClickOnCheckBox(e.OriginalSource as DependencyObject)) return;
        if (!_usb.IsConnected) return;
        UsbFileItem? item = UsbFilesList.SelectedItem as UsbFileItem ?? GetSelectedUsbItems().FirstOrDefault();
        if (item is null) return;
        if (item.IsDir)
        {
            _usbCurrentPath = item.FullPath;
            await RefreshUsbDirectoryAsync();
        }
        else
        {
            await ExportUsbItemsAsync(new[] { item });
        }
    }

    private async void UsbUpBtn_Click(object sender, RoutedEventArgs e)
    {
        _usbCurrentPath = UsbTransferService.GetParentUsbPath(_usbCurrentPath);
        await RefreshUsbDirectoryAsync();
    }

    private async void UsbRefreshBtn_Click(object sender, RoutedEventArgs e) => await RefreshUsbDirectoryAsync();

    private async void UsbExportBtn_Click(object sender, RoutedEventArgs e)
    {
        var sel = GetSelectedUsbItems();
        if (!_usb.IsConnected || sel.Count == 0) return;
        await ExportUsbItemsAsync(sel);
    }

    private async Task ExportUsbItemsAsync(IReadOnlyList<UsbFileItem> items)
    {
        Directory.CreateDirectory(_pcDownloadDir);
        BeginTransferUI("Scanning USB folders for export…");
        var sw = Stopwatch.StartNew();
        long totalBytes = 0;

        try
        {
            var jobs = await _usb.CollectExportsRecursiveAsync(items, _pcDownloadDir, _transferCts!.Token);
            if (jobs.Count == 0) { EndTransferUI("No files found in selected USB folder(s)."); return; }

            long grandTotal = jobs.Sum(j => Math.Max(0, j.size));
            var progress = CreateProgressHandler("USB Export", grandTotal);

            for (int i = 0; i < jobs.Count; i++)
            {
                _transferCts.Token.ThrowIfCancellationRequested();
                var fsw = Stopwatch.StartNew();
                long bytes = await _usb.ExportFileAsync(jobs[i].remotePath, jobs[i].localPath, jobs[i].size, i + 1, jobs.Count, _conflictPolicy, progress, _transferCts.Token);
                totalBytes += bytes;
                double bps = fsw.Elapsed.TotalSeconds > 0.01 ? bytes / fsw.Elapsed.TotalSeconds : 0;
                RecordHistory("USB", "↓", Path.GetFileName(jobs[i].localPath), bytes, bps, "Completed", jobs[i].localPath);
            }

            double avgBps = sw.Elapsed.TotalSeconds > 0.05 ? totalBytes / sw.Elapsed.TotalSeconds : 0;
            AppLogger.Info("USB-MTP", $"Exported {jobs.Count} file(s) ({RemoteFileItem.FormatBytes(totalBytes)}) at {RemoteFileItem.FormatBytes((long)avgBps)}/s");
            EndTransferUI($"USB Export complete: {jobs.Count} file(s) ({RemoteFileItem.FormatBytes(totalBytes)}) at {RemoteFileItem.FormatBytes((long)avgBps)}/s → {_pcDownloadDir}");
        }
        catch (OperationCanceledException)
        {
            AppLogger.Warn("USB-MTP", "USB export cancelled by user.");
            EndTransferUI("USB Export cancelled.");
        }
        catch (Exception ex)
        {
            AppLogger.Error("USB-MTP", "USB export failed", ex);
            EndTransferUI($"USB Export error: {ex.Message}");
            MessageBox.Show(this, ex.Message, "USB Export Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async void UsbImportFilesBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!_usb.IsConnected) return;
        var dlg = new OpenFileDialog { Multiselect = true, Title = "Select Files to Import via USB Cable" };
        if (dlg.ShowDialog(this) == true && dlg.FileNames.Length > 0)
            await ImportLocalPathsToUsbAsync(dlg.FileNames);
    }

    private async void UsbImportFolderBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!_usb.IsConnected) return;
        var dlg = new OpenFolderDialog { Title = "Select Folder to Import via USB Cable" };
        if (dlg.ShowDialog(this) == true && !string.IsNullOrWhiteSpace(dlg.FolderName))
            await ImportLocalPathsToUsbAsync(new[] { dlg.FolderName });
    }

    private async Task ImportLocalPathsToUsbAsync(IReadOnlyList<string> localPaths)
    {
        if (!_usb.IsConnected || localPaths.Count == 0) return;
        if (_usbCurrentPath == "\\")
        {
            MessageBox.Show(this, "Open a storage volume (e.g. Internal shared storage) first before importing files over USB.", "Choose USB Storage Folder", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        var jobs = new List<(string localFile, string usbDir, long size)>();
        var dirsToCreate = new List<(string parent, string name)>();

        void CollectLocal(string path, string usbBase)
        {
            if (Directory.Exists(path))
            {
                string folderName = Path.GetFileName(path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
                dirsToCreate.Add((usbBase, folderName));
                string nextUsb = usbBase.EndsWith('\\') ? usbBase + folderName : usbBase + "\\" + folderName;
                foreach (string file in Directory.GetFiles(path))
                    jobs.Add((file, nextUsb, new FileInfo(file).Length));
                foreach (string sub in Directory.GetDirectories(path))
                    CollectLocal(sub, nextUsb);
            }
            else if (File.Exists(path))
            {
                jobs.Add((path, usbBase, new FileInfo(path).Length));
            }
        }

        foreach (string p in localPaths) CollectLocal(p, _usbCurrentPath);
        if (jobs.Count == 0) return;

        BeginTransferUI($"Importing {jobs.Count} file(s) via USB Cable…");
        var sw = Stopwatch.StartNew();
        long totalBytes = 0;

        try
        {
            long grandTotal = jobs.Sum(j => j.size);
            var progress = CreateProgressHandler("USB Import", grandTotal);

            foreach (var (parent, name) in dirsToCreate)
            {
                try { await _usb.CreateFolderAsync(parent, name); } catch { }
            }
            for (int i = 0; i < jobs.Count; i++)
            {
                _transferCts!.Token.ThrowIfCancellationRequested();
                var fsw = Stopwatch.StartNew();
                long bytes = await _usb.ImportFileAsync(jobs[i].localFile, jobs[i].usbDir, i + 1, jobs.Count, progress, _transferCts.Token);
                totalBytes += bytes;
                double bps = fsw.Elapsed.TotalSeconds > 0.01 ? bytes / fsw.Elapsed.TotalSeconds : 0;
                RecordHistory("USB", "↑", Path.GetFileName(jobs[i].localFile), bytes, bps, "Completed", jobs[i].localFile);
            }

            double avgBps = sw.Elapsed.TotalSeconds > 0.05 ? totalBytes / sw.Elapsed.TotalSeconds : 0;
            AppLogger.Info("USB-MTP", $"Imported {jobs.Count} file(s) ({RemoteFileItem.FormatBytes(totalBytes)}) at {RemoteFileItem.FormatBytes((long)avgBps)}/s");
            EndTransferUI($"USB Import complete: {jobs.Count} file(s) ({RemoteFileItem.FormatBytes(totalBytes)}) at {RemoteFileItem.FormatBytes((long)avgBps)}/s!");
            await RefreshUsbDirectoryAsync();
        }
        catch (OperationCanceledException)
        {
            AppLogger.Warn("USB-MTP", "USB import cancelled by user.");
            EndTransferUI("USB Import cancelled.");
        }
        catch (Exception ex)
        {
            AppLogger.Error("USB-MTP", "USB import failed", ex);
            EndTransferUI($"USB Import error: {ex.Message}");
            MessageBox.Show(this, ex.Message, "USB Import Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async void UsbNewFolderBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!_usb.IsConnected || _usbCurrentPath == "\\") return;
        string? name = PromptInput("New USB Folder", "Folder name to create on phone:", "");
        if (string.IsNullOrWhiteSpace(name)) return;
        try
        {
            await _usb.CreateFolderAsync(_usbCurrentPath, name.Trim());
            await RefreshUsbDirectoryAsync();
        }
        catch (Exception ex) { AppLogger.Error("USB-MTP", $"CreateFolderAsync failed in '{_usbCurrentPath}'", ex); MessageBox.Show(this, ex.Message, "USB New Folder Failed", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private async void UsbDeleteBtn_Click(object sender, RoutedEventArgs e)
    {
        var sel = GetSelectedUsbItems();
        if (!_usb.IsConnected || sel.Count == 0) return;
        if (MessageBox.Show(this, $"Delete {sel.Count} selected item(s) on USB device?", "Confirm USB Delete", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
            return;
        try
        {
            await _usb.DeleteItemsAsync(sel);
            await RefreshUsbDirectoryAsync();
        }
        catch (Exception ex) { AppLogger.Error("USB-MTP", "DeleteItemsAsync failed", ex); MessageBox.Show(this, ex.Message, "USB Delete Failed", MessageBoxButton.OK, MessageBoxImage.Error); }
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
        if (fixedPin.Length >= 4 && fixedPin.Length <= 8) _server.Pin = fixedPin;
        else if (string.IsNullOrWhiteSpace(_server.Pin)) _server.Pin = TransferServer.GenerateRandomPin();

        if (!_server.Start(out string? err))
            MessageBox.Show(this, err ?? "Unable to start PC Host Server.", "Share This PC", MessageBoxButton.OK, MessageBoxImage.Warning);

        SaveSettings();
        RefreshHostUI();
    }

    private void HostChooseFolderBtn_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFolderDialog { Title = "Choose Folder to Share on Wi-Fi" };
        if (dlg.ShowDialog(this) == true && !string.IsNullOrWhiteSpace(dlg.FolderName))
            SetHostRootFolder(dlg.FolderName);
    }

    private void HostQuickFolder_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button btn || btn.Tag is not string tag) return;
        string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string dir = tag switch
        {
            "Downloads" => Path.Combine(profile, "Downloads"),
            "Desktop" => Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
            "Documents" => Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            "Videos" => Environment.GetFolderPath(Environment.SpecialFolder.MyVideos),
            "Pictures" => Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),
            _ => profile
        };
        if (Directory.Exists(dir)) SetHostRootFolder(dir);
    }

    private void SetHostRootFolder(string folder)
    {
        _server.RootPath = folder;
        string lbl = Path.GetFileName(folder.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        _server.RootLabel = string.IsNullOrWhiteSpace(lbl) ? "PC" : lbl;
        HostFolderBox.Text = _server.RootPath;
        SaveSettings();
        if (_server.IsRunning) _hostLogs.Insert(0, $"[{DateTime.Now:HH:mm:ss}] Switched shared folder to: {_server.RootPath}");
        RefreshHostUI();
    }

    private void HostApplyPinBtn_Click(object sender, RoutedEventArgs e)
    {
        string val = HostFixedPinBox.Text.Trim();
        if (string.IsNullOrEmpty(val)) _server.Pin = TransferServer.GenerateRandomPin();
        else if (val.Length >= 4 && val.Length <= 8) _server.Pin = val;
        else { MessageBox.Show(this, "PIN must be 4 to 8 characters.", "Invalid PIN", MessageBoxButton.OK, MessageBoxImage.Warning); return; }
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
        try { Directory.CreateDirectory(_server.RootPath); Process.Start(new ProcessStartInfo { FileName = _server.RootPath, UseShellExecute = true }); }
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
            HostStatusText.Text = $"● Live — Visible on Wi-Fi as \"{Environment.MachineName}\" (/{_server.RootLabel})";
            HostStatusText.Foreground = new SolidColorBrush(Color.FromRgb(74, 222, 128));
            HostPinBigText.Text = _server.Pin;
            HostUrlText.Text = $"{url}   (Auto-discovered by iPhone & Android)";
            HostToggleBtn.Content = "■ Stop Sharing PC";
            HostToggleBtn.Style = (Style)FindResource("DangerBtn");
            HostCopyBtn.IsEnabled = true;
            HostQrImage.Source = RenderQrBitmap(qrUrl);
            HostLiveBadge.Visibility = Visibility.Visible;
        }
        else
        {
            HostStatusText.Text = "PC Host Server Stopped";
            HostStatusText.Foreground = new SolidColorBrush(Color.FromRgb(251, 191, 36));
            HostPinBigText.Text = "----";
            HostUrlText.Text = "Click Start Sharing PC below to share this folder with iPhone, Android, or any browser";
            HostToggleBtn.Content = "▶ Start Sharing PC";
            HostToggleBtn.Style = (Style)FindResource("EmeraldBtn");
            HostCopyBtn.IsEnabled = false;
            HostQrImage.Source = null;
            HostLiveBadge.Visibility = Visibility.Collapsed;
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
        catch { return null; }
    }

    #endregion

    #region Shared Transfer Dock, History, Drag-and-Drop & Helpers

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

    private IProgress<TransferProgressInfo> CreateProgressHandler(string verb, long batchTotalBytes)
    {
        return new Progress<TransferProgressInfo>(p =>
        {
            double pct = p.TotalBytes > 0 ? Math.Clamp(100.0 * p.TransferredBytes / p.TotalBytes, 0, 100) : 0;
            TransferBar.Value = pct;
            double remainingBytes = Math.Max(0, p.TotalBytes - p.TransferredBytes);
            string eta = p.BytesPerSecond > 100 ? RemoteFileItem.FormatEta(remainingBytes / p.BytesPerSecond) : "--";
            TransferStatusText.Text = $"{verb} ({p.FileIndex}/{p.FileCount}): {p.FileName} — {RemoteFileItem.FormatBytes(p.TransferredBytes)} / {RemoteFileItem.FormatBytes(p.TotalBytes)}";
            TransferSpeedText.Text = $"{RemoteFileItem.FormatBytes((long)p.BytesPerSecond)}/s · ETA {eta} · {pct:0}%";
            if (p.BytesPerSecond > _sessionPeakBps)
            {
                _sessionPeakBps = p.BytesPerSecond;
                SessionPeakText.Text = $"{RemoteFileItem.FormatBytes((long)_sessionPeakBps)}/s";
            }
        });
    }

    private void RecordHistory(string transport, string direction, string fileName, long bytes, double avgBps, string status, string localPath)
    {
        Dispatcher.Invoke(() =>
        {
            _sessionTotalBytes += bytes;
            if (avgBps > _sessionPeakBps) _sessionPeakBps = avgBps;
            SessionBytesText.Text = RemoteFileItem.FormatBytes(_sessionTotalBytes);
            SessionPeakText.Text = _sessionPeakBps > 0 ? $"{RemoteFileItem.FormatBytes((long)_sessionPeakBps)}/s" : "--";
            _history.Insert(0, new TransferHistoryEntry
            {
                Timestamp = DateTime.Now.ToString("HH:mm:ss"),
                Transport = transport,
                Direction = direction,
                FileName = fileName,
                Bytes = bytes,
                AvgBytesPerSec = avgBps,
                Status = status,
                LocalPath = localPath
            });
            HistoryCountText.Text = _history.Count.ToString();
        });
    }

    private void ClearHistoryBtn_Click(object sender, RoutedEventArgs e)
    {
        _history.Clear();
        HistoryCountText.Text = "0";
    }

    private void CancelTransferBtn_Click(object sender, RoutedEventArgs e) => _transferCts?.Cancel();

    private void OpenPcDirBtn_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(_pcDownloadDir);
        Process.Start(new ProcessStartInfo { FileName = _pcDownloadDir, UseShellExecute = true });
    }

    private void Window_DragOver(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DataFormats.FileDrop))
        {
            e.Effects = DragDropEffects.None;
            e.Handled = true;
            return;
        }
        if (_activeNav == 0 && _client is not null)
        {
            e.Effects = DragDropEffects.Copy;
            DropOverlay.Visibility = Visibility.Visible;
        }
        else if (_activeNav == 1 && _usb.IsConnected && _usb.ConnectedSummary?.IsApple != true)
        {
            e.Effects = DragDropEffects.Copy;
            UsbDropOverlay.Visibility = Visibility.Visible;
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
        UsbDropOverlay.Visibility = Visibility.Collapsed;
    }

    private async void Window_Drop(object sender, DragEventArgs e)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
        UsbDropOverlay.Visibility = Visibility.Collapsed;
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] dropped || dropped.Length == 0) return;

        if (_activeNav == 0 && _client is not null)
            await UploadLocalPathsAsync(dropped);
        else if (_activeNav == 1 && _usb.IsConnected && _usb.ConnectedSummary?.IsApple != true)
            await ImportLocalPathsToUsbAsync(dropped);
    }

    private string? PromptInput(string title, string label, string initialValue)
    {
        var win = new Window
        {
            Title = title,
            Width = 440,
            Height = 190,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = this,
            ResizeMode = ResizeMode.NoResize,
            Background = (Brush)FindResource("BgCanvas"),
            Foreground = (Brush)FindResource("TextPrimary")
        };
        var panel = new StackPanel { Margin = new Thickness(18) };
        panel.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0, 0, 0, 8), Foreground = (Brush)FindResource("TextSecondary"), TextWrapping = TextWrapping.Wrap });
        var tb = new TextBox { Text = initialValue, Style = (Style)FindResource("GlassTextBox"), Height = 36 };
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

    #endregion

    #region Diagnostic, Error & Crash Logs

    private void OnLogEntryAdded(DiagnosticLogItem item)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (item.Level is "ERROR" or "WARN" or "CRASH")
            {
                _errorLogCount++;
                UpdateErrorBadgeCount();
            }
            if (_activeNav == 5 && AppLogger.MatchesFilter(item, _logFilterLevel))
            {
                DiagnosticLogBox.AppendText(item.formattedLine + Environment.NewLine);
                DiagnosticLogBox.ScrollToEnd();
            }
        });
    }

    private void UpdateErrorBadgeCount()
    {
        int count = Math.Max(_errorLogCount, AppLogger.GetRecentItems().Count(i => i.Level is "ERROR" or "WARN" or "CRASH"));
        if (count > 0)
        {
            ErrorCountText.Text = count.ToString();
            ErrorCountBadge.Visibility = Visibility.Visible;
        }
        else
        {
            ErrorCountBadge.Visibility = Visibility.Collapsed;
        }
    }

    private void RefreshLogsView()
    {
        DiagnosticLogBox.Text = AppLogger.BuildFullDiagnosticReport(_logFilterLevel);
        DiagnosticLogBox.ScrollToEnd();
        UpdateErrorBadgeCount();
    }

    private void LogFilterChip_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button btn || btn.Tag is not string level) return;
        _logFilterLevel = level;
        Style inactive = (Style)FindResource("FilterChipBtn");
        Style active = (Style)FindResource("FilterChipActiveBtn");
        foreach (Button b in new[] { LogChipAll, LogChipErrors, LogChipCrashes })
            b.Style = ReferenceEquals(b, btn) ? active : inactive;
        RefreshLogsView();
    }

    private void RefreshLogsBtn_Click(object sender, RoutedEventArgs e) => RefreshLogsView();

    private void CopyLogsBtn_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            string report = AppLogger.BuildFullDiagnosticReport(_logFilterLevel);
            Clipboard.SetText(report);
            TransferStatusText.Text = "📋 Full diagnostic, error & crash report copied to clipboard — ready to paste & share!";
            MessageBox.Show(this, "Full diagnostic, error & crash report copied to your clipboard!", "Logs Copied", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Copy Logs Failed", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void ExportLogsBtn_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new SaveFileDialog
        {
            Title = "Export WQGlass Transfer Diagnostic & Crash Log",
            Filter = "Log File (*.log;*.txt)|*.log;*.txt|All Files (*.*)|*.*",
            FileName = $"WQGlassTransfer-Windows-Log-{DateTime.Now:yyyyMMdd-HHmmss}.txt"
        };
        if (dlg.ShowDialog(this) == true && !string.IsNullOrWhiteSpace(dlg.FileName))
        {
            try
            {
                File.WriteAllText(dlg.FileName, AppLogger.BuildFullDiagnosticReport("ALL"));
                TransferStatusText.Text = $"💾 Saved diagnostic & crash log to {dlg.FileName}";
                MessageBox.Show(this, $"Saved full diagnostic & crash report to:\n{dlg.FileName}", "Log Exported", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "Export Log Failed", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }
    }

    private void OpenLogFolderBtn_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Directory.CreateDirectory(AppLogger.LogsDirectory);
            Process.Start(new ProcessStartInfo { FileName = AppLogger.LogsDirectory, UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Open Log Folder Failed", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void ClearLogsBtn_Click(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(this, "Clear all saved diagnostic, error, and crash logs?", "Clear Logs", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
            return;
        _errorLogCount = 0;
        AppLogger.ClearAllLogs();
        RefreshLogsView();
    }

    #endregion
}
