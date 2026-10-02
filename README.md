# SplitCarPlay (Dopamine rootless, iOS 16.5)

Tweak cá nhân: chia màn hình CarPlay thành 2 app chạy song song.

## Kiến trúc (đã xác minh qua mã nguồn carplay-cast, iOS 14+)
Tham khảo `ref/carplay-cast/` (Ethan Arbuckle, github.com/EthanArbuckle/carplay-cast).
Cách CarBridge/carplay-cast đưa app thường lên CarPlay:

1. **CarPlay process** (`com.apple.CarPlayApp`): hook `CARApplication +_newApplicationLibrary`
   để icon app thường xuất hiện; hook `CARApplicationLaunchInfo +launchInfoForApplication:...`
   để khi bấm icon thì gửi `NSDistributedNotification` sang SpringBoard thay vì launch kiểu CarPlay.
   Đóng app CarPlay native đang chạy bằng `CARDashboard handleEvent:` (CAREvent type 1 = Home).
2. **SpringBoard** (`CRCarplayWindow`): lấy `CADisplay` của xe qua
   `AVExternalDevice currentCarPlayExternalDevice` -> `screenIDs`, tạo `FBSDisplayConfiguration`
   -> `UIRootSceneWindow initWithDisplayConfiguration:` = cửa sổ nằm trên màn xe.
   Tạo scene cho app: `SBSceneManagerCoordinator mainDisplaySceneManager`
   -> `_sceneIdentityForApplication:createPrimaryIfRequired:` -> `SBApplicationSceneHandleRequest`
   -> `fetchOrCreateApplicationSceneHandleForRequest:` -> `SBDeviceApplicationSceneEntity`
   -> `SBAppViewController initWithIdentifier:andApplicationSceneEntity:`. View của nó
   add vào cửa sổ, scale bằng `CGAffineTransformMakeScale` cho vừa khung.
   Giữ app sống khi khoá máy: hook `SBSuspendedUnderLockManager`, `FBScene updateSettings:...`,
   `BKSDisplayServicesSetScreenBlanked`.
3. **App process** (UIKit): nhận notification xoay màn hình, ép `UIWindow _setRotatableViewOrientation:...`.

### Thiết kế SplitCarPlay
Cửa sổ SpringBoard trên màn xe chia làm 2 ngăn (trái/phải), mỗi ngăn host một
`SBAppViewController` riêng, scale theo kích thước ngăn. App chạy ở hướng dọc (portrait)
vì ngăn nửa màn 800x480 ~ 380x480 gần với tỉ lệ dọc của iPhone.
Chọn app: long-press icon trên dashboard CarPlay -> lần 1 vào ngăn trái, lần 2 vào ngăn phải.

### Đã đối chiếu với iOS 16.5 (class-dump từ IPSW 20F66, thư mục `headers/` local)
- Code SpringBoard nằm trong `SpringBoard.framework` (binary SpringBoard chỉ là stub).
- Code app CarPlay nằm trong `DashBoard.framework`, prefix `DB`: `DBDashboard`, `DBIconView`,
  `DBEvent`, `DBApplicationLaunchInfo`; `[UIApplication _currentDashboard]` vẫn còn.
- Đổi tên so với iOS 14: `layoutStateManager` (bỏ `_`),
  `sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:`,
  `primarySceneIdentifierForBundleIdentifier:sceneSessionRole:displayIdentity:`,
  `FBScene.clientProcess` thay `client.process`, `updateSettingsWithBlock:` thay `mutableSettings`,
  `_setRotatableViewOrientation:(long long)duration:(double)force:(BOOL)`.

### Cách lấy header trên Windows (không cần Mac)
1. `tools/ipsw/ipsw.exe extract --remote --dmg sys|fs -o dmg <URL IPSW>` tải DMG.
2. 7-Zip 25 giải nén được root FS (UDIF+LZFSE) và phần lớn dyld cache từ DMG SystemOS (APFS thô),
   trừ 2 subcache `.dyldlinkedit` và `.symbols` (nén LZFSE trong APFS).
3. Giả 3 file đó: copy một subcache nhỏ thật, vá UUID (đọc từ header cache chính),
   vá mapping address/size đúng dải địa chỉ, giữ offset code signature của file mẫu.
   `ipsw class-dump <DSC> <dylib> --headers -o D:/...` chạy được (ObjC metadata không cần linkedit).
   Dùng đường dẫn kiểu `D:/...` cho `-o` và `MSYS_NO_PATHCONV=1` trong Git Bash.

### Lộ trình
1. ~~Class-dump SpringBoard + CarPlay 16.5~~ xong.
2. Build xanh, cài, kiểm tra 1 ngăn chạy được trên 16.5.
3. Kiểm tra 2 ngăn, chỉnh scale/orientation.
4. Giao diện chọn app, lưu cặp app mặc định.

## Build (không cần Theos trên Windows)
- Push repo lên GitHub -> Actions tự build, tải `SplitCarPlay-deb` ở tab Artifacts.
- Hoặc cài WSL Ubuntu + Theos: `make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless`.

## Cài đặt trong app Settings
Vào Cài đặt > SplitCarPlay: bật/tắt, chọn app ngăn trái/phải (AltList), tự mở khi cắm xe,
kiểu chia, hướng app trong ngăn, tỉ lệ ngăn. App trong ngăn luôn được resize đúng kích thước ngăn và có viền.
Nút bấm kiểu HyperOS: tròn 52pt nền trắng, icon hình học đen, nút đang bật chuyển xanh; bật ra lần lượt
theo kiểu MIUI (lò xo, so le) khi hiện. Cùng một kiểu ở mọi nơi.
- Việc của TỪNG NGĂN: tab "..." ở giữa mép trên ngăn, chạm hoặc kéo xuống để hiện thanh nút
  Đổi app / Toàn màn / Cửa sổ nổi (PiP) / Đóng, ngay dưới tab (tự ẩn sau 8 giây).
- Việc của CẢ CẶP: núm kéo kiểu Xiaomi (thanh trắng mỏng) giữa 2 ngăn, kéo để đổi tỉ lệ, chạm để mở menu
  Đổi chỗ / Tỉ lệ (icon là bố cục sẽ áp tiếp) / Cặp yêu thích 1-3 / CarPlay.
- Khi chỉ còn 1 app chiếm hết màn, mép phải ngăn có nút tròn "chia đôi": app hiện tại về nửa trái,
  nửa phải hiện bảng chọn app để ghép cặp (Huỷ thì về lại toàn màn).
Mục "Gỡ lỗi" có nút mở/đóng split ngay trên màn iPhone.
Cần package `PreferenceLoader` và `AltList` (Sileo tự cài theo Depends).

## Test ngay trên màn iPhone (chưa có xe, cách cũ qua SSH)
Tạo file prefs qua SSH (đổi bundle id tuỳ ý, nên dùng app bên thứ ba):
```
cat > /var/jb/var/mobile/Library/Preferences/com.anpham.splitcarplay.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>TestLeft</key><string>com.google.ios.youtube</string>
  <key>TestRight</key><string>com.apple.mobilesafari</string>
  <key>TestOnMainScreen</key><true/>
</dict></plist>
PLIST
```
- Respring: sau 10 giây cửa sổ chia đôi hiện trên màn iPhone (xoay ngang).
- Hoặc không cần respring: `notifyutil -p com.anpham.splitcarplay.test` (package `notifyutil`/`darwintools`).
- Đóng: kéo dấu "..." của một ngăn xuống rồi bấm nút Home, hoặc `notifyutil -p com.anpham.splitcarplay.close`.
- Xoá key `TestOnMainScreen` khi không muốn tự mở nữa.

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
