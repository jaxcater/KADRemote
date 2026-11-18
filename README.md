# KAD Remote

Ứng dụng quản lý PC Windows từ xa qua iPhone (hỗ trợ cả **khi đi ngoài đường qua 4G/Cloudflare Tunnel** lẫn **Wi-Fi nhà / Tailscale**).

## Tính năng chính

1. **Stream màn hình PC trực tiếp (`Screen Stream`)**
   - Xem màn hình PC real-time trên iPhone để kiểm tra lỗi, theo dõi tiến trình.
   - Chế độ **Điều khiển từ xa**: chạm để click trái/phải/double-click, cuộn trang, gõ chữ Unicode, phím tắt nhanh (`Ctrl+C`, `Alt+F4`, `Win+D`, `TaskMgr`).
   - Chế độ **Xem / Zoom**: kéo & phóng to chi tiết màn hình, chụp ảnh lưu về Thư viện ảnh iPhone.
2. **Chạy PowerShell từ xa (`PSSHELL`)**
   - Terminal tương tác real-time qua WebSocket (`/ws/ps`), hỗ trợ `Ctrl+C`, lịch sử lệnh, gợi ý lệnh nhanh.
3. **Truyền file 2 chiều (iPhone ↔ PC)**
   - Duyệt ổ đĩa (`C:\`, `D:\`), `Desktop`, `Downloads`, `Documents`.
   - Tải file từ PC về iPhone (lưu vào Tệp / Chia sẻ).
   - Gửi file, ảnh, video từ iPhone lên PC.
   - Tạo thư mục, đổi tên, xóa file/thư mục.
4. **Chạy file & Quản lý tiến trình trên PC**
   - Chạy `.exe`, `.bat`, `.cmd`, `.ps1`, hoặc mở bất kỳ file nào trên PC (hỗ trợ tham số, quyền Admin, chờ & xem output).
   - Xem Task Manager & tắt ứng dụng bị treo, Khóa màn hình / Ngủ / Khởi động lại / Tắt PC.
5. **Kết nối cực dễ qua mã QR**
   - `Kad.exe` tích hợp sẵn **Cloudflare Quick Tunnel** (tự động tạo link `https://*.trycloudflare.com` không cần mở port router) và sinh **QR Code** để app iPhone quét kết nối trong 1 giây.

---

## Cấu trúc dự án

- `windows/KADRemote.Host/`: App Windows Host (.NET 9 WPF + Kestrel Server) → build ra **`Kad.exe`** (single-file).
- `ios/KADRemote/`: App iOS SwiftUI (XcodeGen) → build ra **`Kad.ipa`** (unsigned).
- `.github/workflows/build.yml`: Tự động build cả `Kad.exe` và `Kad.ipa` (unsigned) và đẩy lên GitHub Releases.

---

## Cách Build

### 1. Build `Kad.exe` trên Windows
Yêu cầu [.NET 9 SDK](https://dotnet.microsoft.com/download/dotnet/9.0):

```powershell
dotnet publish windows/KADRemote.Host/KADRemote.Host.csproj -c Release -r win-x64 -o dist/windows
```

File đầu ra: `dist/windows/Kad.exe`

### 2. Build `Kad.ipa` (unsigned)
Do iOS `.ipa` bắt buộc biên dịch bằng Xcode trên macOS, dự án đã cấu hình sẵn GitHub Actions:
- Khi push code lên GitHub (`https://github.com/jaxcater/KADRemote.git`), workflow **Build KAD Remote** sẽ tự động chạy trên `macos-latest` và xuất ra **`Kad.ipa`** (unsigned) trong **Actions Artifacts** và **Releases**.
- Cài `Kad.ipa` lên iPhone bằng **Sideloadly**, **AltStore**, **SideStore**, **TrollStore** hoặc **ESign**.

---

## Hướng dẫn sử dụng nhanh

1. Chạy **`Kad.exe`** trên PC Windows ở nhà.
2. Bấm **"Bật Tunnel"** (hoặc bật tùy chọn *Tự bật Tunnel từ xa khi mở app*) để tạo URL kết nối qua 4G/Internet.
3. Mở app **KAD Remote** trên iPhone → bấm **"Quét mã QR từ PC"** → quét QR trên màn hình Windows.
4. Chọn **"Ẩn xuống Tray"** trên PC để ứng dụng chạy ngầm khi bạn đi ra ngoài.
