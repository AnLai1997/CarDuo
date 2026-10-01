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

### Lộ trình
1. Class-dump SpringBoard + CarPlay 16.5 (từ IPSW, tool `ipsw` + 7-Zip) để xác nhận các
   selector trên còn đúng ở iOS 16.5 (carplay-cast viết cho iOS 14).
2. Port phần host app của carplay-cast sang ARC + rootless, 1 ngăn, chạy được trên 16.5.
3. Mở rộng thành 2 ngăn.
4. Giao diện chọn app, lưu cặp app mặc định.

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
