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

Tweak chỉ nạp vào 2 process (`CarDuo.plist`): **CarPlay** (toàn bộ split, tự mở khi cắm xe)
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
chữ nằm trong `carduoprefs/Resources/*.lproj/Localizable.strings`), chỉ còn: bật/tắt, tự mở khi cắm xe (mở lại cách chia
gần nhất, chưa có thì Bố cục yêu thích 1), cách dùng, Bố cục yêu thích 1-3. Không còn xem trước, ngăn trái/phải mặc định,
kiểu chia, hướng app, tỉ lệ: hướng chia tự theo màn xe (ngang -> trái/phải, dọc -> trên/dưới), tỉ lệ chia đều theo bố cục,
kéo thanh chia để đổi và tự nhớ theo cặp app. App trong ô luôn được resize đúng kích thước ô.
Nút bấm kiểu HyperOS: tròn 52pt nền trắng, icon hình học đen, nút đang bật chuyển xanh; bật ra lần lượt
theo kiểu MIUI (lò xo, so le) khi hiện. Cùng một kiểu ở mọi nơi.
Trên màn xe (xem sơ đồ `docs/flow.html`):
- Mở split: nút CarDuo trên dock CarPlay (ngay trên nút Home; khe không đủ thì giữa đồng hồ và cụm icon dock)
  -> bảng bố cục. Đang mở app toàn màn: chọn bố cục thì app đó vào ô 1, các ô còn lại hiện bảng chọn app
  (trong hình ô 1 là logo app đang mở, ô còn lại dấu +). Ở màn chính: mọi ô trống, hiện bảng chọn app. Giữ icon app 0,7 giây ở màn chính
  cũng mở bảng bố cục. App mở toàn màn không có gì đè lên (đã bỏ logo ở mép trên app, nút dock làm thay).
  Bật "Tự mở split khi cắm xe" thì khi cắm xe tự mở cặp lần trước (chưa có thì dùng Ngăn trái / Ngăn phải).
- Việc của TỪNG Ô (kiểu HyperOS): thanh "•••" ở giữa mép trên ô. Chạm -> thanh nút
  Đổi app / Toàn màn hình (thoát chia, app này toàn màn) │ Tắt app (đỏ, tự ẩn sau 3,5 giây).
  Giữ và kéo "•••": thẻ icon app chạy theo tay, ô bên dưới viền xanh, thả -> đổi chỗ 2 ô.
  Ô hẹp thì cả thanh nút tự thu nhỏ cho vừa. Đã bỏ "Phóng to tạm" (trùng với Toàn màn hình).
  Tắt một app (hoặc huỷ bảng chọn của ô trống) thì bớt một ô: 3 còn 2, 2 còn 1 = app đó về toàn màn.
- Góc ô: bo 12pt ở chỗ giáp ô bên cạnh và cả 2 góc trái của ô sát dock (ô bên trái); góc sát mép màn khác vuông.
- Vạch chia (kiểu HyperOS): khe đen 6pt, tay nắm viên thuốc trắng. Kéo: mọi ô phủ thẻ tối + icon app,
  scene chỉ đổi kích thước 1 lần khi thả tay (CBWindow CarBridge ẩn lúc kéo). Thả tay tự hít
  1/3 · 1/2 · 2/3 (3 ô: bước 1/12, ô nhỏ nhất 20%). Kéo cho 1 ô còn dưới 12% -> đóng ô đó.
  Chạm 1 lần vào tay nắm -> thanh tỉ lệ mặc định (2 ô: 1/3 · 1/2 · 2/3; 3 ô: đều · giữa to · trái to · phải to;
  1 lớn + 2: ô lớn 1/3 · 1/2 · 2/3), tỉ lệ đang dùng tô xanh, tự ẩn sau 4 giây.
  Chạm 2 lần vào vạch -> đổi chỗ 2 ô hai bên. Bố cục 2 ô nhớ tỉ lệ riêng từng cặp app.
- CarBridge (YouTube, TikTok...) chỉ chạy 1 app: app CarBridge mới thay app CarBridge cũ ngay trong ô của nó
  và app cũ bị tắt hẳn; app cũ đang mở dở thì báo "Đợi ... mở xong". Gần đây / Yêu thích có 2 app CarBridge
  thì chỉ mở app đầu, ô kia hiện bảng chọn.
- Đang mở app vào ô: thẻ icon app (phóng ra, nhịp thở, vòng xoay) tới khi app hiện (CarBridge: tới khi
  CBWindow chiếu xong, tối đa 6 giây), rồi icon phóng to mờ dần. Mở lỗi thì ô trống hiện lại bảng chọn.
- Mọi tác vụ hẹn giờ đi qua `SCPCAfter` (bọc @try), mọi nút / cử chỉ bọc @try: lỗi chỉ ghi log, không sập CarPlay.
- 1 lớn + 2 nhỏ: ô 1 lớn bên trái (chia trên/dưới: ở trên), ô 2 và 3 xếp chồng; 1 tay nắm tròn ở chỗ giao
  2 vạch kéo được 2 chiều; kéo dọc vạch thì chỉ đổi 1 chiều. Tay nắm vạch ngang lệch 1/4 để không đè "•••".
- Đổi bố cục khi đang chia: nút CarDuo trên dock vẫn hiện -> bảng "Đổi bố cục" (bố cục đang dùng tô sáng).
  App giữ thứ tự ô; thêm ô thì ô mới hiện bảng chọn; bớt ô thì app ở ô cuối về nền.
- Bố cục "2 + 1 lớn" (mã 31): bản lật của 1 lớn + 2, ô lớn bên phải (màn dọc: ở dưới); kéo vạch, tỉ lệ mặc định,
  đổi chỗ dùng chung với 1 lớn + 2. Có trong bảng nút CarDuo, Gần đây và Bố cục yêu thích trong Cài đặt.
- Hình trong hình (kiểu "cửa sổ nhỏ" HyperOS): nút trên thanh ••• của mỗi ô đưa app của ô đó ra cửa sổ nổi
  (`floatPane`, số ô giả `SCPC_FLOAT_SLOT` = 9), nằm trên các ô chia, bo đủ 4 góc. Chưa có cửa sổ nổi thì ô đó được
  bớt (cần ≥ 2 ô); đã có thì đổi chỗ: app đang nổi về lại ô vừa bấm. Không có mục riêng trong bảng nút CarDuo.
  Kéo ••• của cửa sổ nổi để di chuyển, thả ra hít sát cạnh trái/phải; thanh ••• của nó có Đổi app / Đưa về ô /
  Toàn màn hình / Tắt app. "Đưa về ô" trả app về đúng ô, bố cục (cả 1 lớn + 2 / 2 + 1 lớn) và tỉ lệ trước khi đưa ra;
  bố cục đã đổi từ đó thì thêm 1 ô ở cuối, chia đều; đã đủ 3 ô thì báo không đưa về được. Đóng cửa sổ nổi khi chỉ còn 1 ô thì app ô đó về toàn màn. Không dùng với YouTube/TikTok (CBWindow luôn nằm
  trên mọi view CarPlay); cửa sổ nổi tự né ô đang chiếu CarBridge, không còn chỗ né thì tự đóng.
- Bảng của nút CarDuo chỉ dùng icon, không có chữ: mỗi hàng có icon mục bên trái (2 ô = bố cục, đồng hồ = Gần đây,
  ngôi sao = Yêu thích), các lựa chọn là hình bố cục / icon app trong từng ô; Gần đây trống thì là 1 ô viền nét đứt.
  Cuối hàng đầu có nút thoát đỏ: đang chia thì thoát chia màn, app ở ô đang chọn về toàn màn (không có app thì
  về màn chính); chưa chia thì chỉ đóng bảng.
  Hàng bố cục vẽ theo app thật: ở màn chính mọi ô là dấu + (chọn là mọi ô hiện bảng chọn app); đang mở 1 app
  thì ô 1 là logo app đó, các ô còn lại dấu +; đang chia thì mỗi ô là app đang nằm trong ô đó.
- Bảng của nút CarDuo có 3 mục: Mặc định (2 ô / 3 ô / 1 lớn + 2), Gần đây (tối đa 3 cách chia vừa dùng,
  lưu ở key `RecentLayouts`, mỗi ô hiện icon app; bấm là mở lại đúng bố cục và app), Yêu thích (bố cục yêu thích
  1-3 trong Cài đặt). "Gần đây" luôn hiện (trống thì có dòng gợi ý). Yêu thích không còn nằm trong menu thanh chia.
- Bố cục yêu thích trong Cài đặt: Tên, chọn bố cục (`FavNLayout` = 2 / 3 / 13), rồi app cho Ô 1 / Ô 2 / Ô 3
  (`FavNLeft` / `FavNRight` / `FavNThird`; Ô 3 chỉ hiện khi bố cục có 3 ô). Cặp cũ tự thành bố cục 2 ô.
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
