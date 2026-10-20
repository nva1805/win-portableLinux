# win-portableLinux

Ubuntu 24.04 LTS + desktop XFCE trên SSD ngoài, chạy bằng QEMU portable trong Windows x64. Không cần WSL, không boot BIOS, không cài QEMU/driver/service lên máy mượn.

## Cài mới trên SSD

1. Tải repo bằng **Code → Download ZIP**, giải nén vào một thư mục riêng trên SSD (ví dụ `F:\win-portableLinux`). Không chạy trực tiếp bên trong ZIP.
2. Nhấp đúp **`SETUP.cmd`** bằng tài khoản Windows thường; giữ Internet và SSD kết nối cho tới khi báo `SETUP COMPLETE`.
3. Mở **`START-UBUNTU-DESKTOP.cmd`** để dùng giao diện, hoặc **`START-UBUNTU-TERMINAL.cmd`** để chỉ dùng dòng lệnh.

SETUP tự tải đúng phiên bản QEMU, Ubuntu và công cụ giải nén từ các nguồn HTTPS trong [`setup/sources.json`](setup/sources.json), kiểm tra checksum ghim sẵn, **chỉ giải nén** bộ cài Windows, tạo ổ QCOW2 và cài XFCE bên trong máy ảo. Kết thúc thành công sẽ xóa cache tải xuống/giải nén của setup; giữ công thức seed để có thể dựng lại sau này. Không cần cài Git/GitHub để sử dụng repo tải dạng ZIP.

Tải khoảng 800 MiB ban đầu, sau đó APT tải thêm gói desktop. Cần tối thiểu 10 GiB trống để cài; nên chừa ít nhất 24 GiB cho sử dụng. Thời gian tùy mạng và tăng tốc sẵn có, có thể từ vài phút tới lâu hơn đáng kể khi phải giả lập TCG. Không có lời hứa “một click là xong tức thì”.

Nếu lỗi mạng/cài gói, đọc `runtime/logs`, sửa nguyên nhân rồi chạy lại `SETUP.cmd`. Đĩa đã tạo bởi setup được giữ để tiếp tục. **Không tự ghi đè/xóa ổ Ubuntu có sẵn**, kể cả ổ từ bộ portable cũ. Cài mới nên dùng thư mục mới; sao lưu riêng nếu muốn thay hệ điều hành.

## Tài khoản và dữ liệu

- Tên tài khoản: **`ubuntu`**, tự đăng nhập cục bộ; `sudo` không cần mật khẩu.
- Mật khẩu đăng nhập ban đầu **bị khóa**, không phải mật khẩu rỗng. Đặt mật khẩu cá nhân trong Ubuntu: `sudo passwd ubuntu`. Việc này không tắt tự đăng nhập.
- Làm việc trong **`~/work`** (`/home/ubuntu/work`).
- Cài công cụ trong Ubuntu: `sudo apt update`, rồi `sudo apt install ten-goi`.
- Toàn bộ hệ điều hành, ứng dụng, mật khẩu và dự án nằm trong **`disks/ubuntu.qcow2`**. Repo Git không chứa chúng.
- VS Code, Chrome, Node.js chưa cài sẵn; khi cần chọn bộ Linux/Ubuntu amd64 chính thức. Nền Ubuntu thật, dùng XFCE nhẹ chứ không phải GNOME của Ubuntu Desktop mặc định.

**Seed là công thức dựng máy, không phải bản sao lưu.** Muốn đổi SSD mà giữ nguyên mọi app và dự án đã cài thêm, tắt Ubuntu rồi sao chép cả bộ portable; không chạy setup lại từ đầu. Muốn sao lưu hệ điều hành và công việc, sao chép QCOW2 khi máy ảo đã tắt. Không sao chép ổ đang chạy.

## Tắt và chuyển máy

Trong Ubuntu mở Terminal gõ **`sudo poweroff`**, hoặc chọn **Shut down Portable Ubuntu** trong menu. Đợi QEMU và cửa sổ khởi chạy thoát, sau đó Safely Remove/Eject SSD trên Windows.

Không rút ổ hay đóng cưỡng bức để tắt. Giữ terminal khởi chạy (có thể thu nhỏ) trong khi dùng desktop: nó theo dõi máy ảo và giữ khóa chống mở trùng. Nút X QEMU bị vô hiệu hóa để tránh tắt nhầm. Chỉ mở **một** chế độ Ubuntu mỗi lần.

Lần sau cắm SSD vào Windows x64 khác, mở một trong hai nút START; **không chạy setup lại**. Đường dẫn dựa vào vị trí bộ mở, không cố định F. Các chương trình đang mở không tự được giữ nguyên giữa các lần tắt máy.

## Cấu hình và màn hình

Sửa `config.json` khi Ubuntu đã tắt:

```json
{
  "MemoryMB": 2048,
  "CPUs": 2,
  "Accelerator": "auto",
  "DiskSizeGiB": 24,
  "DisplayWidth": 0,
  "DisplayHeight": 0
}
```

- RAM/CPU áp dụng mỗi lần mở. `DiskSizeGiB` chỉ dùng lúc **tạo ổ mới**, sửa nó không tự đổi dung lượng ổ đã cài.
- `auto` thử WHPX **đã có sẵn**, với `kernel-irqchip=off`; nếu không khởi tạo được thì thử TCG. Nếu WHPX khởi tạo được nhưng lỗi lúc chạy, đặt `Accelerator` thành `tcg` thủ công. Không tự bật Windows Hypervisor/Hyper-V và không cần cấu hình BIOS.
- Hai giá trị màn hình bằng `0` nghĩa là tự lấy kích thước màn Windows chính và quảng bá cho Ubuntu qua EDID ảo, giới hạn 3840×2160. Có thể đặt cả hai thành `1920` và `1080` để cố định Full HD.
- Không dùng kéo giãn ảnh để giả độ phân giải cao. Khởi động desktop sẽ chọn mode ưu tiên của card ảo. Cửa sổ có thể lớn hơn vùng làm việc; dùng toàn màn hình hoặc đặt độ phân giải thấp hơn trong `config.json`.
- Có sẵn bộ đọc SVG để icon không bị phóng ảnh nhỏ; icon desktop 64 px. Hình nền có bảng phím tắt trong `~/Pictures`.

## Phím tắt thường dùng

| Phím | Tác dụng |
|---|---|
| Ctrl + Alt + F | Bật/tắt toàn màn hình QEMU, không phải chụp ảnh |
| Ctrl + Alt + G | Giữ/nhả chuột và bàn phím về Windows |
| Ctrl + Alt + 0 | Kích thước hình gốc |
| Alt + F2 | Tìm và mở ứng dụng bên trong Ubuntu |
| Alt + Tab | Chuyển ứng dụng Ubuntu |
| Alt + F4 | Đóng cửa sổ đang chọn; cẩn thận cửa sổ nào đang nhận phím |
| Ctrl + L trong Thunar | Nhập đường dẫn |
| Ctrl + Shift + C / V trong Terminal | Sao chép / dán |
| Ctrl + C trong Terminal | Ngắt lệnh đang chạy, không phải sao chép |

## Thư mục nào làm gì?

- `setup/`: mã tải/cài, nguồn ghim checksum, seed, hình nền. Được đưa lên GitHub.
- `tools/`: bộ khởi chạy và cầu nối terminal. Được đưa lên GitHub.
- `qemu/`: máy ảo và thư viện tải/giải nén. Không đưa lên GitHub.
- `disks/ubuntu.qcow2`: Ubuntu và dữ liệu cá nhân. Không đưa lên GitHub.
- `runtime/`: tệp tạm, khóa phiên, trạng thái setup và log. Không đưa lên GitHub.

Không cần thư mục `ubuntu` ngoài ổ ảo và không phụ thuộc `ubuntu/READY`. `runtime/setup-state.json` giúp biết bộ cài đã hoàn tất hay đang dở; nó cũng bảo vệ khỏi chạy lại seed trên một ổ không thuộc setup này.

## Giới hạn và bảo mật

- Dành cho Windows 10/11 x64 Intel/AMD cho phép EXE/CMD/PowerShell chạy từ SSD. Windows ARM, chính sách chặn ứng dụng và máy thiếu tài nguyên có thể không dùng được. Không bảo đảm mọi máy chạy ngay; chưa thử máy vật lý thứ hai.
- Bản QEMU Windows ghim hiện tại là build experimental của nhà cung cấp được trang QEMU liên kết; không gọi đây là build QEMU stable. Nền Ubuntu vẫn là LTS. Cập nhật nguồn cần đối chiếu checksum và kiểm thử lại.
- Không chia sẻ ổ máy chủ/clipboard vào Ubuntu, không mở SSH hay port forward vào máy ảo. Terminal dùng TCP loopback ngẫu nhiên; cổng đóng khi QEMU thoát. QMP chỉ bật loopback khi setup hoặc kiểm thử, không bật ở chế độ thường.
- Không sửa PATH/chính sách PowerShell/biến môi trường toàn máy; chỉ đổi thư mục tạm và cấu hình của tiến trình sang SSD.
- **Không bảo đảm “không dấu vết”**: Windows có thể ghi Prefetch, antivirus, nhật ký, pagefile hoặc crash dump trên C. Không xóa log/bảo mật Windows. Không bảo mật được dữ liệu khỏi quản trị viên máy mượn.
- Tự đăng nhập + sudo không mật khẩu ưu tiên tiện lợi cục bộ, không phải cấu hình cho máy nhiều người dùng. SSD chưa mã hóa; ai đọc được ổ có thể đọc dữ liệu.
- Checksum ghim bảo vệ tính toàn vẹn tải xuống, không thay thế kiểm toán nhà cung cấp hay xác minh chữ ký GPG. Không có mật khẩu/token cá nhân trong seed; tuyệt đối không commit QCOW2, `.local-tools`, `.env`, khóa SSH hoặc credentials.

## Kiểm thử / phát triển

Không cần Pester hoặc gói PowerShell ngoài:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Validate.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup\Setup.ps1 -ValidateOnly
```

Kiểm thử tích hợp phải dùng **thư mục mới**; không dùng Ubuntu đang làm việc. Bộ CI chỉ kiểm tra mã/seed, không tuyên bố đã boot WHPX trên mọi máy. Gói APT nhận cập nhật bảo mật từ Ubuntu nên cấu hình được tái lập, không phải ảnh đĩa bit-for-bit giống mãi mãi.

Nguồn: [Ubuntu cloud image](https://cloud-images.ubuntu.com/releases/noble/release-20261017/), [QEMU Windows](https://qemu.weilnetz.de/w64/), [QEMU download](https://www.qemu.org/download/), [7-Zip](https://www.7-zip.org/download.html), [cloud-init NoCloud](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html). Repo phân phối mã điều phối và hình nền, không phân phối lại các bộ nhị phân Ubuntu/QEMU/7-Zip. Các phần mềm tải về giữ giấy phép tương ứng của nhà cung cấp.
