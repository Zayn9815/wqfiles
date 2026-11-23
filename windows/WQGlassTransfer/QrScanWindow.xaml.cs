using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using ZXing;
using ZXing.Common;

namespace WQGlassTransfer;

public partial class QrScanWindow : Window
{
    private const int WM_CAP_DRIVER_CONNECT = 0x040A;
    private const int WM_CAP_DRIVER_DISCONNECT = 0x040B;
    private const int WM_CAP_SAVEDIBW = 0x0419;
    private const int WM_CAP_GRAB_FRAME = 0x043C;

    [DllImport("avicap32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr capCreateCaptureWindowW(
        string lpszWindowName, int dwStyle, int x, int y, int nWidth, int nHeight, IntPtr hwndParent, int nID);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int wMsg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int wMsg, IntPtr wParam, string lParam);

    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDesktopWindow();

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindowDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int nWidth, int nHeight);

    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(IntPtr hdc, IntPtr hgdiobj);

    [DllImport("gdi32.dll")]
    private static extern bool BitBlt(IntPtr hdcDest, int xDest, int yDest, int width, int height, IntPtr hdcSrc, int xSrc, int ySrc, int rop);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr hObject);

    private readonly BarcodeReaderGeneric _reader = new()
    {
        AutoRotate = true,
        Options = new DecodingOptions
        {
            TryHarder = true,
            PossibleFormats = new List<BarcodeFormat> { BarcodeFormat.QR_CODE }
        }
    };

    private IntPtr _capHwnd = IntPtr.Zero;
    private DispatcherTimer? _timer;
    private string _tempBmpPath = "";

    public string? ScannedPayload { get; private set; }

    public QrScanWindow()
    {
        InitializeComponent();
        _tempBmpPath = Path.Combine(Path.GetTempPath(), $"wqglass_cam_{Guid.NewGuid():N}.bmp");
        Closed += (_, _) => StopWebcam();
    }

    private void WebcamBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_capHwnd != IntPtr.Zero)
        {
            StopWebcam();
            WebcamBtn.Content = "🎥 Start Webcam";
            ScanStatusText.Text = "Webcam stopped.";
            return;
        }

        try
        {
            IntPtr ownerHwnd = new WindowInteropHelper(this).Handle;
            _capHwnd = capCreateCaptureWindowW("WQCam", 0, 0, 0, 640, 480, ownerHwnd, 0);
            if (_capHwnd == IntPtr.Zero)
            {
                ScanStatusText.Text = "Could not initialize Windows webcam capture.";
                return;
            }
            IntPtr connected = SendMessage(_capHwnd, WM_CAP_DRIVER_CONNECT, IntPtr.Zero, IntPtr.Zero);
            if (connected == IntPtr.Zero)
            {
                DestroyWindow(_capHwnd);
                _capHwnd = IntPtr.Zero;
                ScanStatusText.Text = "No webcam detected (or webcam is busy). Try Scan Screen or Open Image.";
                return;
            }

            WebcamBtn.Content = "■ Stop Webcam";
            PlaceholderText.Visibility = Visibility.Collapsed;
            ScanStatusText.Text = "Webcam live — hold your phone's QR code in front of the camera…";

            _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(260) };
            _timer.Tick += (_, _) => CaptureAndDecodeWebcamFrame();
            _timer.Start();
        }
        catch (Exception ex)
        {
            StopWebcam();
            ScanStatusText.Text = $"Webcam error: {ex.Message}";
        }
    }

    private void CaptureAndDecodeWebcamFrame()
    {
        if (_capHwnd == IntPtr.Zero) return;
        try
        {
            SendMessage(_capHwnd, WM_CAP_GRAB_FRAME, IntPtr.Zero, IntPtr.Zero);
            SendMessage(_capHwnd, WM_CAP_SAVEDIBW, IntPtr.Zero, _tempBmpPath);
            if (!File.Exists(_tempBmpPath)) return;

            byte[] bytes = File.ReadAllBytes(_tempBmpPath);
            var bmp = new BitmapImage();
            using (var ms = new MemoryStream(bytes))
            {
                bmp.BeginInit();
                bmp.CacheOption = BitmapCacheOption.OnLoad;
                bmp.StreamSource = ms;
                bmp.EndInit();
                bmp.Freeze();
            }
            PreviewImage.Source = bmp;

            string? decoded = TryDecodeBitmapSource(bmp);
            if (!string.IsNullOrWhiteSpace(decoded))
            {
                AcceptPayload(decoded);
            }
        }
        catch { }
    }

    private void StopWebcam()
    {
        _timer?.Stop();
        _timer = null;
        if (_capHwnd != IntPtr.Zero)
        {
            try
            {
                SendMessage(_capHwnd, WM_CAP_DRIVER_DISCONNECT, IntPtr.Zero, IntPtr.Zero);
                DestroyWindow(_capHwnd);
            }
            catch { }
            _capHwnd = IntPtr.Zero;
        }
        try { if (File.Exists(_tempBmpPath)) File.Delete(_tempBmpPath); } catch { }
    }

    private void ScreenScanBtn_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            BitmapSource? screen = CapturePrimaryScreen();
            if (screen is null)
            {
                ScanStatusText.Text = "Screen capture failed.";
                return;
            }
            PlaceholderText.Visibility = Visibility.Collapsed;
            PreviewImage.Source = screen;
            string? decoded = TryDecodeBitmapSource(screen);
            if (!string.IsNullOrWhiteSpace(decoded))
            {
                AcceptPayload(decoded);
            }
            else
            {
                ScanStatusText.Text = "No QR code found on the primary screen.";
            }
        }
        catch (Exception ex)
        {
            ScanStatusText.Text = $"Screen scan error: {ex.Message}";
        }
    }

    private void ClipboardBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!Clipboard.ContainsImage())
        {
            ScanStatusText.Text = "Clipboard does not contain an image. Take a screenshot (Win+Shift+S) and try again.";
            return;
        }
        BitmapSource? img = Clipboard.GetImage();
        if (img is null) return;
        PlaceholderText.Visibility = Visibility.Collapsed;
        PreviewImage.Source = img;
        string? decoded = TryDecodeBitmapSource(img);
        if (!string.IsNullOrWhiteSpace(decoded))
        {
            AcceptPayload(decoded);
        }
        else
        {
            ScanStatusText.Text = "No QR code found in clipboard image.";
        }
    }

    private void OpenImageBtn_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog
        {
            Title = "Select QR Code Image",
            Filter = "Images|*.png;*.jpg;*.jpeg;*.bmp;*.webp|All Files|*.*"
        };
        if (dlg.ShowDialog(this) != true) return;

        try
        {
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.UriSource = new Uri(dlg.FileName);
            bmp.EndInit();
            bmp.Freeze();

            PlaceholderText.Visibility = Visibility.Collapsed;
            PreviewImage.Source = bmp;
            string? decoded = TryDecodeBitmapSource(bmp);
            if (!string.IsNullOrWhiteSpace(decoded))
            {
                AcceptPayload(decoded);
            }
            else
            {
                ScanStatusText.Text = "No readable QR code found in that image.";
            }
        }
        catch (Exception ex)
        {
            ScanStatusText.Text = $"Could not load image: {ex.Message}";
        }
    }

    private void AcceptPayload(string payload)
    {
        StopWebcam();
        ScannedPayload = payload;
        DialogResult = true;
        Close();
    }

    private void CloseBtn_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }

    private string? TryDecodeBitmapSource(BitmapSource source)
    {
        try
        {
            BitmapSource bgra = source.Format == PixelFormats.Bgra32
                ? source
                : new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);

            int w = bgra.PixelWidth;
            int h = bgra.PixelHeight;
            int stride = w * 4;
            byte[] pixels = new byte[stride * h];
            bgra.CopyPixels(pixels, stride, 0);

            var lum = new RGBLuminanceSource(pixels, w, h, RGBLuminanceSource.BitmapFormat.BGRA32);
            Result? result = _reader.Decode(lum);
            return result?.Text;
        }
        catch
        {
            return null;
        }
    }

    private static BitmapSource? CapturePrimaryScreen()
    {
        int w = (int)SystemParameters.PrimaryScreenWidth;
        int h = (int)SystemParameters.PrimaryScreenHeight;
        if (w <= 0 || h <= 0) return null;

        IntPtr desk = GetDesktopWindow();
        IntPtr srcDc = GetWindowDC(desk);
        IntPtr memDc = CreateCompatibleDC(srcDc);
        IntPtr hBmp = CreateCompatibleBitmap(srcDc, w, h);
        IntPtr old = SelectObject(memDc, hBmp);
        try
        {
            const int SRCCOPY = 0x00CC0020;
            BitBlt(memDc, 0, 0, w, h, srcDc, 0, 0, SRCCOPY);
            BitmapSource src = Imaging.CreateBitmapSourceFromHBitmap(hBmp, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            src.Freeze();
            return src;
        }
        finally
        {
            SelectObject(memDc, old);
            DeleteObject(hBmp);
            DeleteDC(memDc);
            ReleaseDC(desk, srcDc);
        }
    }
}
