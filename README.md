# CarDuo (Dopamine rootless, iOS 16.5)

Tweak cá nhân: chia màn hình CarPlay thành 2 app chạy song song.
Tên hiển thị và tên kỹ thuật đều là **CarDuo** (package `com.anlai97.carduo`, URL scheme `carduo://`,
file dylib/log `CarDuo`).

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

### Thiết kế CarDuo (giao diện CarPlay thật)
Mỗi ngăn hiện **giao diện CarPlay của app** (scene CarPlay / template), không chiếu giao diện iPhone.
Toàn bộ split nằm trong process CarPlay (`DashBoard.framework`), code ở `src/SCPCarSplit.mm` + `src/hooks/CarPlay.xm`:
1. Mở app vào ngăn = gửi đúng sự kiện DashBoard dùng khi chạm icon:
   `[DBDashboard handleEvent:[DBEvent eventWithType:4 context:[DBApplicationLaunchInfo launchInfoForApplication:info]]]`
   (lấy từ `-[DBDashboard _launchAppWithInfo:forURL:]`). DashBoard tự tạo `DBApplicationSceneViewController`;
   app template được proxy qua `com.apple.CarPlayTemplateUIHost` (`initWithApplicationInfo:app proxyApplicationInfo:host`).
2. Hook `-[DBDashboard sceneFrameForAppInfo:proxyAppInfo:]` / `safeAreaInsetsForAppInfo:proxyAppInfo:` trả kích thước ngăn
   (`DBSceneUpdate._frame` gọi đúng hàm này), nên app tự bố cục giao diện CarPlay theo ngăn.
3. Hook `-[DBDashboardRootViewController presentBaseViewController:...]`: đang split thì đưa view controller vào ngăn
   thay vì hiện toàn màn. Hook `backgroundSceneWithCompletion:` / `deactivateSceneWithReasonMask:` giữ scene của ngăn foreground.
4. Nút Home của CarPlay (`_handleHomeEvent:`) hoặc DashBoard về màn chính thì tắt split.
Dock CarPlay vẫn hiện; chạm app trên dock khi đang split thì app vào ngăn vừa chạm.
App iPhone (không có CarPlay) vào ngăn qua CarBridge: CarPlay báo SpringBoard đặt cửa sổ `CBWindow` đúng khung ngăn.

Tweak chỉ nạp vào 2 process (`CarDuo.plist`): **CarPlay** (toàn bộ split, video khởi động, tự mở khi cắm xe)
và **SpringBoard** (nhận URL `carduo://`, đặt khung CarBridge, ghi hộ log). Không nạp vào app nào khác.
Cửa sổ split kiểu cũ trong SpringBoard (chiếu giao diện iPhone, Mirror) đã bỏ từ 1.1.0.

Quy tắc chống crash:
- Gọi method riêng của Apple chỉ qua macro trong `src/common.h`: `objcInvoke*` (trả về object), `objcCall*` (method `void`
  hoặc bỏ kết quả), `objcInvokeT` (số / struct). Macro kiểm tra `respondsToSelector:` trước, thiếu method thì ghi log
  `THIEU METHOD` một lần và bỏ qua. Không dùng `objcInvoke` cho method `void`: ARC release "kết quả" rác -> crash ngẫu nhiên.
- Phần code của tweak trong mỗi hook nằm trong `@try`; `%orig` luôn được gọi. Lỗi chỉ ghi `LOI trong ...` vào log.

Dò ngược DashBoard trên Windows: `ipsw class-dump <dsc_test> DashBoard --re -V` cho địa chỉ method,
rồi disassemble bằng capstone (Python) đọc thẳng các subcache theo bảng mapping (ipsw disass hỏng vì linkedit giả).

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
- Push repo lên GitHub -> Actions tự build, tải `CarDuo_<Version>_rootless` ở tab Artifacts (push tag `v<Version>` thì có thêm GitHub Release kèm file .deb).
- Hoặc cài WSL Ubuntu + Theos: `make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless`.

## Cài đặt trong app Settings
Vào Cài đặt > CarDuo (giao diện HarmonyOS; Tiếng Việt / English ở nút quả cầu góc phải; thẻ tác giả + phiên bản ở cuối trang;
chữ nằm trong `carduoprefs/Resources/*.lproj/Localizable.strings`): bật/tắt, xem trước màn xe, chọn app ngăn trái/phải (chỉ app CarPlay / CarBridge), video khởi động, tự mở khi cắm xe,
kiểu chia, hướng app trong ngăn, tỉ lệ ngăn. App trong ngăn luôn được resize đúng kích thước ngăn và có viền.
Nút bấm kiểu HyperOS: tròn 52pt nền trắng, icon hình học đen, nút đang bật chuyển xanh; bật ra lần lượt
theo kiểu MIUI (lò xo, so le) khi hiện. Cùng một kiểu ở mọi nơi.
Trên màn xe (xem sơ đồ `docs/flow.html`):
- Mở split: nút tròn góc trên phải màn chính CarPlay (mở lại cặp dùng lần trước), giữ icon app 0,7 giây,
  hoặc chạm thẻ nhỏ ở mép trên app đang mở toàn màn rồi chọn app thứ hai. Bật "Tự mở split khi cắm xe" thì
  sau video khởi động tự mở cặp lần trước (chưa có thì dùng Ngăn trái / Ngăn phải trong Cài đặt).
- Việc của TỪNG NGĂN: thẻ trắng nhỏ ở giữa mép trên ngăn, chạm hoặc kéo xuống để hiện thanh nút
  Đổi app / Toàn màn / Đóng (tự ẩn sau 3 giây nếu không thao tác).
- Việc của CẢ CẶP: núm kéo giữa 2 ngăn, kéo để đổi tỉ lệ (nhớ riêng từng cặp), chạm để mở menu
  Đổi chỗ / Tỉ lệ 50-70-30 / Cặp yêu thích 1-3 / Đóng split.
Cần package `PreferenceLoader` (Sileo tự cài theo Depends).

## Cài & xem log
```
scp packages/*.deb mobile@<ip-iphone>:/var/jb/tmp/
ssh mobile@<ip-iphone> "sudo dpkg -i /var/jb/tmp/*.deb && killall CarPlay"
ssh mobile@<ip-iphone> "oslog | grep CarDuo"         # cần package oslog từ Procursus
# hoặc từ Windows (libimobiledevice): idevicesyslog | findstr CarDuo
```
`killall CarPlay` là đủ, SpringBoard sẽ tự khởi động lại nó khi xe đang kết nối.

Tweak luôn ghi log ra `/var/mobile/Documents/CarDuo.log` (mở bằng Filza). Khi SpringBoard khởi động mà file
lớn hơn 2MB thì file cũ được đổi thành `CarDuo.old.log` và bắt đầu file mới.

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
