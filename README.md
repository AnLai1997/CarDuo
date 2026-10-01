# SplitCarPlay (Dopamine rootless, iOS 16.5)

Tweak cá nhân: chia màn hình CarPlay thành 2 app chạy song song.

## Kiến trúc CarPlay trên iOS 16 (tóm tắt)
- Giao diện CarPlay chạy trong process **`CarPlay`** (bundle `com.apple.CarPlayApp`,
  `/System/Library/CoreServices/CarPlay.app`), KHÔNG phải SpringBoard.
- Process này link các private framework: `CarPlayUIServices` (prefix `CAR`),
  `CarPlaySupport`, `CarKit`, `FrontBoard`. App bên thứ 3 không vẽ trực tiếp,
  mà được "host" vào một view của process CarPlay (thường tên có chữ `Host`).
- Muốn chia đôi: (1) co view host của app đang chạy xuống nửa trái,
  (2) tạo thêm host view cho app thứ 2 ở nửa phải, (3) cập nhật
  `FBSSceneSettings.frame` để app tự layout đúng kích thước mới chứ không bị cắt.

## Lộ trình
1. **Recon** (code hiện tại, `ENABLE_RESIZE 0`): cài deb, cắm xe/giả lập CarPlay,
   đọc log `[SplitCP]` để lấy tên class host thật + cây view.
2. **Resize**: điền `HOST_VIEW_CLASS`, bật `ENABLE_RESIZE 1`, xác nhận app bị ép nửa trái.
3. **Scene thứ 2**: tìm cách CarPlay tạo scene cho app (hook class quản lý scene
   tìm được ở bước 1), gọi lại cho app thứ 2 với frame nửa phải.
4. **Đúng kích thước**: cập nhật scene settings frame thay vì chỉ co view.

## Build (không cần Theos trên Windows)
- Push repo lên GitHub -> Actions tự build, tải `SplitCarPlay-deb` ở tab Artifacts.
- Hoặc cài WSL Ubuntu + Theos: `make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless`.

## Cài & xem log
```
scp packages/*.deb mobile@<ip-iphone>:/var/jb/tmp/
ssh mobile@<ip-iphone> "sudo dpkg -i /var/jb/tmp/*.deb && killall CarPlay"
ssh mobile@<ip-iphone> "oslog | grep SplitCP"        # cần package oslog từ Procursus
# hoặc từ Windows (libimobiledevice): idevicesyslog | findstr SplitCP
```
`killall CarPlay` là đủ, SpringBoard sẽ tự khởi động lại nó khi xe đang kết nối.

## Lấy tên class mà không cần device
Tool `ipsw` (blacktop/ipsw, chạy được trên Windows) class-dump thẳng từ IPSW 16.5:
```
ipsw download ipsw --version 16.5 --device iPhone14,2
ipsw dyld class-dump <dyld_shared_cache> --class 'CAR*' 
ipsw class-dump "/System/Library/CoreServices/CarPlay.app/CarPlay"
```
Kết hợp với FLEX (package `FLEXing`/`Flexible` trên Dopamine) để xem live hierarchy.

## Tham khảo tweak cùng mảng
- CarBridge (leftyfl1p): cho app thường chạy trên CarPlay, có hook vào CarPlay process
  và SpringBoard – nguồn tốt để xem cách tạo scene cho app.
- NGXPlay: tương tự CarBridge, hỗ trợ iOS 16.
