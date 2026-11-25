# Facebook-Plus — Bản Đồ Tính Năng (Feature Map)

> Cập nhật lần cuối: `2026-11-25` (`v1.1.0`)
> Kiến trúc mục tiêu: `iphoneos-arm64` (Rootless / Rootfull / Roothide `.deb` & `TrollFools` `.zip`)
> Tiến trình mục tiêu: `com.facebook.Facebook` (`Facebook` iOS `15.1+`, đã kiểm chứng thực tế trên `Facebook 588.0.0` / `iOS 17.2.1` `iPhone 14 Pro Max`)

---

## 1. Lõi Hệ Thống & Tùy Chọn (`src/Core/`)

| File | Hàm / Lớp chính | Chức năng phục vụ |
|---|---|---|
| `src/Core/FBPEntry.xm` | `FBPInstallAllHooks()`, `%ctor` | Điểm khởi chạy trung tâm của Tweak; đăng ký callback `_dyld_register_func_for_add_image` để kích hoạt an toàn các nhóm hook trên các framework nạp trễ (`FBFeedAttachmentsFramework`, `FBSharedDynamicFramework`, ...) qua chốt `FBP_ONCE`. |
| `src/Core/FBPlus.h` & `src/Core/FBPlus.m` | Các hằng `FBPKey*`, `FBPConfirmPromptVisible()`, `FBPFontScopeActive()`, `FBPVideoButtonsAlpha()`, `FBPAttachDraggableBehavior()`, `FBPIsButtonDragging()`, `FBPShouldSuppressTapAfterDrag()`, `FBPResolvedButtonCenter()`, `FBPResetVideoButtonPositions()` | Khai báo và định nghĩa khóa cấu hình, thông báo nội bộ (`FBPSettingsDidChangeNotification`, `FBPVideoButtonsDidChangeNotification`), bộ điều phối kéo thả nút nổi (`FBPDraggableButtonCoordinator` dùng `UIPanGestureRecognizer` kẹp biên `safeAreaInsets`, lưu tọa độ chuẩn hóa `"rx,ry"` vào `FBPPrefs`, chống bấm nhầm `TouchUpInside` sau khi kéo) và hàm tính độ trong suốt (`[0.15 .. 1.0]`). |
| `src/Core/FBPPrefs.h` & `src/Core/FBPPrefs.m` | `+[FBPPrefs shared]`, `+[FBPPrefs defaultValues]`, `-boolForKey:`, `-doubleForKey:`, `-stringForKey:`, `-commit`, `-resetToDefaults` | Kho lưu trữ cấu hình bền vững trên suite `com.shajon.fbplus` (`NSUserDefaults`), khởi tạo giá trị mặc định ngay khi mở app và phát thông báo cập nhật tức thời. |
| `src/Core/FBPResources.h` & `src/Core/FBPResources.m` | `FBPL()`, `+[UIImage fbp_imageNamed:]`, `+[UIImage fbp_symbolNamed:size:weight:]`, `FBPPanelColor()`, `FBPCardColor()`, `FBPTintColor()` | Nạp gói tài nguyên `FacebookPlus.bundle`, tra cứu đa ngôn ngữ (18 ngôn ngữ trong `Localizations/*.lproj`), bảng màu tối chuẩn của trang cài đặt. |
| `src/Core/FBPTrace.h` & `src/Core/FBPTrace.m` | `FBPTraceEmit()`, `FBPTraceFire()`, `FBPLogWriteExportFile()` | Hệ thống ghi nhật ký chẩn đoán vòng lặp nhẹ, hỗ trợ xuất file log để gỡ lỗi thực tế trên thiết bị. |

---

## 2. Chặn Quảng Cáo, Bảng Tin & Bình Luận (`src/Features/Ads/`, `Feed/`, `Comments/`, `Reels/`)

| File | Nhóm Hook / Hàm chính | Chức năng phục vụ |
|---|---|---|
| `src/Features/Ads/FBPAdsHooks.xm` | `FBPModelIsBlockedAd()`, `FBPInitAdsHooks()` | Nhận diện đơn vị quảng cáo tài trợ (Sponsored / Ad) trên News Feed, Video và Marketplace. |
| `src/Features/Feed/FBPFeedHooks.xm` & `FBPFeedSurveyHooks.xm` | `FBPInitFeedHooks()`, `FBPInitFeedSurveyHooks()` | Lọc bỏ bài đề xuất (`ENGAGEMENT`), gợi ý kết bạn (`PYMK`), gợi ý nhóm/trang, Reels/Stories chèn ngang trên bảng tin, quảng bá Threads và thẻ khảo sát. |
| `src/Features/Comments/FBPCommentHooks.xm` | `%group FBPCommentEmojiBanner` (`FBStaticEmojiBannerController`), `%group FBPCommentProductBanner` (`FBCommentStreamRootComponentModel`), `%group FBPReelsProductTag`, `%group FBPVideoProductBanner`, `FBPApplyEmojiBannerPreferenceLive()`, `FBPInitCommentHooks()` | **1) Chặn hàng quick icon khi bình luận (`FBPKeyNoCommentEmojiBar`):** Hook `FBStaticEmojiBannerController` (`-commentComposerComponentDidMount`, `-showBannerIfValidWithComposerState:`, `-shouldHideComposerViewTopBorder`, `-_bannerProvidingBlock`) và gọi `-hideBannerDueToPrimaryBanner` để thu gọn hoàn toàn dải emoji nhanh `52pt` (`static-emoji-banner`: `❤️ 🙌 🔥 👏 😢 😍 😮 😂`) phía trên ô nhập bình luận với **0px khoảng trống đen**, giữ nguyên đường viền mảnh và các nút chụp ảnh / đính kèm; đồng bộ bật/tắt tức thời khi đổi trong mục *Quảng cáo & Bảng tin*.<br>**2) Ẩn biểu ngữ sản phẩm / affiliate (`FBPKeyNoCommentProductBanner`):** Gỡ sticky footer sản phẩm trong khung bình luận, thẻ sản phẩm trên Reels và banner Shopee dưới video Page. |
| `src/Features/Reels/FBPReelsMidCardHooks.xm` & `FBPReelsSurveyHooks.xm` | `FBPInitReelsMidCardHooks()`, `FBPInitReelsSurveyHooks()` | Chặn thẻ đề xuất toàn màn hình giữa các Reels (`FBPKeyNoReelsRecommended`) và khảo sát Reels. |

---

## 3. Tải Video / Reels / Stories & Điều Khiển Nút Nổi (`src/Features/Downloads/`, `Stories/`)

| File | Lớp / Hàm chính | Chức năng phục vụ |
|---|---|---|
| `src/Features/Downloads/FBPReelsDownloader.xm` | `FBPReelDownloadHandler`, `FBPGetOrCreateWindowButton()`, `FBPGetOrCreateHideOverlayButton()`, `FBPReelButtonTracker` (`-tick:`, `-setButton:visible:`), `FBPInitReelsDownloader()` | Hiển thị 2 nút nổi trên Reels / trình phát video hợp nhất (`FBVideoHomeUnifiedPlayerViewController`): **Nút Con mắt** (`kFBPHideOverlayButtonTag` — ẩn/hiện lớp phủ giao diện Cinema Mode) và **Nút Tải về** (`kFBPDownloadButtonTag`). Hỗ trợ **chỉnh độ trong suốt (`15%`–`100%`)** thời gian thực và **nhấn kéo di chuyển vị trí độc lập** (`FBPKeyVideoEyePosition`, `FBPKeyVideoDownloadPosition`) không lo bấm nhầm hay bị `CADisplayLink` ghi đè khi đang kéo. |
| `src/Features/Downloads/FBPStoryDownloader.xm` | `FBPStoryDownloadTarget`, `FBPStoryInstallOrUpdateButton()`, `FBPStoryCaptureCurrentVideo()`, `FBPStoryCaptureCurrentPhoto()` | Tải video và ảnh Story chất lượng cao nhất vào Photos; nút Tải Story (`kFBPStoryDownloadTag`) đồng bộ độ trong suốt `FBPVideoButtonsAlpha()` và kéo thả lưu vị trí riêng (`FBPKeyStoryDownloadPosition`). |
| `src/Features/Stories/FBPStoryHooks.xm` | `FBPStoryMenuTarget`, `FBPInstallStoryFallbackButton()`, `%group FBPStorySeenModern/Mutator`, `%group FBPStoryAdvance`, `%group FBPStoryTray` | Xem Story ẩn danh không gửi biên nhận đã xem, chặn tự chuyển Story tiếp theo, ẩn khay Story đầu bảng tin; nút Con mắt đánh dấu đã xem (`FBPViewTagStoryButton`) hỗ trợ chỉnh độ trong suốt và kéo thả vị trí (`FBPKeyStoryEyePosition`). |
| `src/Features/Downloads/FBPDownloadVariants.m`, `FBPDashManifest.m`, `FBPDashDownload.m`, `FBPMediaMuxer.m`, `FBPMediaConverter.m`, `FBPVP9Converter.m`, `FBPDownloadStore.m`, `FBPDownloadManagerController.m` | Bộ giải mã DASH / ghép hình+tiếng / chuyển mã AV1 & VP9 sang H.264/HEVC, Trình quản lý tải xuống | Cho phép chọn độ phân giải + dung lượng trước khi lưu, theo dõi tiến trình tải, dừng / thử lại và mở trực tiếp trong ứng dụng Ảnh. |

---

## 4. Giao Diện Cài Đặt & Tiện Ích Khác (`src/Settings/`, `src/UI/`, `src/PluginsInject/`)

| File | Lớp / Hàm chính | Chức năng phục vụ |
|---|---|---|
| `src/Settings/FBPSettingsController.m` | `FBPSettingsCell` (`-setSliderMode:`), `FBPTableController` (`-configureCell:withRow:`, `-fbpSliderChanged:`, `-fbpSliderFinished:`), `FBPCategoryCatalog()`, `FBPSettingsDetailController`, `FBPSettingsMenuController` | Giao diện cài đặt phân nhóm thẻ tối của Facebook Plus:<br>- Trong **Quảng cáo & Bảng tin (`cat.ads.title`)**: Công tắc `Chặn hàng quick icon khi bình luận` (`FBPKeyNoCommentEmojiBar`).<br>- Trong **Tải xuống (`cat.downloads.title`)**: Thanh trượt mượt `Độ trong suốt nút Video` (`FBPKeyVideoButtonsOpacity`, `15%`–`100%`) và dòng thao tác `Đặt lại vị trí nút Video` (`kActionResetVideoButtons`). |
| `src/Features/OLED/`, `HDR/`, `Fonts/`, `AppIcons/`, `Sidebar/`, `Confirmation/`, `Links/`, `Cache/`, `FacebookPlus/` | Các bộ hook giao diện & xác nhận thao tác | Chế độ tối đen tuyền OLED, tắt HDR chói sáng, đổi phông chữ & biểu tượng app, dọn gọn thanh bên, hỏi xác nhận trước khi Thích / Bình luận / Chia sẻ / Kết bạn, mở liên kết bằng Safari, dọn bộ nhớ đệm tự động. |
| `src/PluginsInject/` | `SideloadFix.xm`, `SecRebinds.xm`, `Paths.mm` | Tương thích môi trường sideload / TrollStore / Rootless jailbreak (ánh xạ Keychain & App Group an toàn khi thiếu entitlement gốc). |
