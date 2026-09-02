#pragma once
#import <UIKit/UIKit.h>

/// 壁纸变体：锁屏 / 主屏幕
typedef NS_ENUM(NSInteger, LGWallpaperVariant) {
    LGWallpaperVariantLockScreen = 0,
    LGWallpaperVariantHomeScreen = 1,
};

/// 壁纸模糊缓存单例
/// 核心思想：静态表面（Dock、文件夹、小组件、灵动岛等）背后就是壁纸，
/// 不需要每帧用 CABackdropLayer 实时捕获，预模糊一次缓存即可。
/// 壁纸变化时自动失效并重新生成。
@interface LGWallpaperBlurCache : NSObject

+ (instancetype)sharedInstance;

/// 获取指定半径和明暗模式的模糊壁纸
/// @param variant 锁屏 or 主屏幕
/// @param radius 模糊半径（点，内部会按屏幕缩放换算）
/// @param style 浅色 / 深色模式
/// @return 模糊后的 UIImage，若壁纸不可用则返回 nil
- (UIImage *)blurredWallpaperForVariant:(LGWallpaperVariant)variant
                                   radius:(CGFloat)radius
                       userInterfaceStyle:(UIUserInterfaceStyle)style;

/// 手动失效缓存（壁纸变化通知会自动调用，一般不需要手动调）
- (void)invalidate;

@end
