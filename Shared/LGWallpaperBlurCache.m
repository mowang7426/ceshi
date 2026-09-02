#import "LGWallpaperBlurCache.h"
#import "LGSharedSupport.h"
#import <objc/runtime.h>
#import <CoreImage/CoreImage.h>

// 缓存条目最大数量（不同 variant × radius × style 的组合）
static const NSInteger kLGMaxCacheEntries = 24;

// 模糊半径量化步长（半径接近的复用同一张缓存，避免每个像素差都重算）
static const CGFloat kLGBlurRadiusStep = 5.0;

@interface LGWallpaperBlurCacheEntry : NSObject
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, copy) NSString *key;
@end
@implementation LGWallpaperBlurCacheEntry @end

@interface LGWallpaperBlurCache () {
    NSCache<NSString *, LGWallpaperBlurCacheEntry *> *_cache;
    dispatch_queue_t _workQueue;
    CIContext *_ciContext;
    BOOL _observing;
}
@end

@implementation LGWallpaperBlurCache

+ (instancetype)sharedInstance {
    static LGWallpaperBlurCache *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[LGWallpaperBlurCache alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (!self) return nil;
    _cache = [[NSCache alloc] init];
    _cache.countLimit = kLGMaxCacheEntries;
    _workQueue = dispatch_queue_create("dylv.liquidglass.wallpaperblur", DISPATCH_QUEUE_SERIAL);
    [self setupObservation];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 壁纸变化监听

- (void)setupObservation {
    if (_observing) return;
    _observing = YES;

    // 方式1：SpringBoard 内部通知（最可靠）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_wallpaperDidChange:)
                                                 name:@"SBWallpaperDidChangeNotification"
                                               object:nil];
    // 方式2：兜底的 Darwin 通知
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge void *)self,
                                    LGWallpaperBlurCacheDarwinCallback,
                                    CFSTR("com.apple.springboard.wallpaperchanged"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
}

static void LGWallpaperBlurCacheDarwinCallback(CFNotificationCenterRef center,
                                                 void *observer,
                                                 CFStringRef name,
                                                 const void *object,
                                                 CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        [(__bridge LGWallpaperBlurCache *)observer invalidate];
    });
}

- (void)_wallpaperDidChange:(NSNotification *)note {
    (void)note;
    [self invalidate];
}

- (void)invalidate {
    [_cache removeAllObjects];
    LGLog(@"[WallpaperBlurCache] invalidated all cached wallpapers");
}

#pragma mark - 公共 API

- (UIImage *)blurredWallpaperForVariant:(LGWallpaperVariant)variant
                                   radius:(CGFloat)radius
                       userInterfaceStyle:(UIUserInterfaceStyle)style {
    // 量化半径，减少缓存条目
    CGFloat quantizedRadius = round(radius / kLGBlurRadiusStep) * kLGBlurRadiusStep;
    quantizedRadius = MAX(0.0, quantizedRadius);

    NSString *key = [NSString stringWithFormat:@"%ld|%.0f|%ld",
                     (long)variant, quantizedRadius, (long)style];

    LGWallpaperBlurCacheEntry *entry = [_cache objectForKey:key];
    if (entry.image) return entry.image;

    // 同步获取原始壁纸（这个操作很快，只是拿引用）
    UIImage *rawWallpaper = [self _rawWallpaperForVariant:variant];
    if (!rawWallpaper) {
        LGLog(@"[WallpaperBlurCache] raw wallpaper unavailable for variant=%ld", (long)variant);
        return nil;
    }

    // 半径为 0 直接返回原图
    if (quantizedRadius <= 0.01) {
        LGWallpaperBlurCacheEntry *e = [LGWallpaperBlurCacheEntry new];
        e.image = rawWallpaper;
        e.key = key;
        [_cache setObject:e forKey:key];
        return rawWallpaper;
    }

    // 模糊计算放在后台队列，先返回占位 nil 由调用方处理
    // 但为了简单和即时显示，这里用同步阻塞（首次调用会阻塞 ~50-100ms）
    // 实际使用时建议首次调用后通过 KVO/通知刷新
    __block UIImage *blurred = nil;
    dispatch_sync(_workQueue, ^{
        blurred = [self _blurImage:rawWallpaper radius:quantizedRadius style:style];
    });

    if (blurred) {
        LGWallpaperBlurCacheEntry *e = [LGWallpaperBlurCacheEntry new];
        e.image = blurred;
        e.key = key;
        [_cache setObject:e forKey:key];
        LGLog(@"[WallpaperBlurCache] generated blur key=%@ size=%.0fx%.0f",
              key, blurred.size.width, blurred.size.height);
    }
    return blurred;
}

#pragma mark - 内部：获取原始壁纸

- (UIImage *)_rawWallpaperForVariant:(LGWallpaperVariant)variant {
    // 优先尝试 SBWallpaperProvider（SpringBoard 进程内最可靠）
    UIImage *image = [self _wallpaperViaSBWallpaperProvider:variant];
    if (image) return image;

    // 回退：尝试 SBWallpaperController
    image = [self _wallpaperViaSBWallpaperController:variant];
    if (image) return image;

    // 回退：直接读取文件系统中的壁纸缓存
    image = [self _wallpaperViaFileSystem:variant];
    return image;
}

- (UIImage *)_wallpaperViaSBWallpaperProvider:(LGWallpaperVariant)variant {
    @try {
        Class providerCls = NSClassFromString(@"SBWallpaperProvider");
        if (!providerCls) return nil;
        id provider = [providerCls performSelector:@selector(sharedInstance)];
        if (!provider) return nil;

        // iOS 不同版本 API 不同，依次尝试
        SEL selectors[] = {
            NSSelectorFromString(@"wallpaperImageForVariant:"),
            NSSelectorFromString(@"imageForVariant:"),
            NSSelectorFromString(@"wallpaperImage"),
        };
        NSInteger sbVariant = (variant == LGWallpaperVariantLockScreen) ? 1 : 0;
        for (NSInteger i = 0; i < 3; i++) {
            SEL sel = selectors[i];
            if (![provider respondsToSelector:sel]) continue;
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
                                  [provider methodSignatureForSelector:sel]];
            [inv setTarget:provider];
            [inv setSelector:sel];
            if (i < 2) {
                NSInteger val = sbVariant;
                [inv setArgument:&val atIndex:2];
            }
            [inv invoke];
            UIImage *result = nil;
            [inv getReturnValue:&result];
            if ([result isKindOfClass:[UIImage class]]) return result;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

- (UIImage *)_wallpaperViaSBWallpaperController:(LGWallpaperVariant)variant {
    @try {
        Class ctrlCls = NSClassFromString(@"SBWallpaperController");
        if (!ctrlCls) return nil;
        id shared = [ctrlCls performSelector:@selector(sharedInstance)];
        if (!shared) return nil;

        SEL sel = NSSelectorFromString(@"wallpaperImageForVariant:");
        if (![shared respondsToSelector:sel]) return nil;
        NSInteger sbVariant = (variant == LGWallpaperVariantLockScreen) ? 1 : 0;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
                              [shared methodSignatureForSelector:sel]];
        [inv setTarget:shared];
        [inv setSelector:sel];
        [inv setArgument:&sbVariant atIndex:2];
        [inv invoke];
        UIImage *result = nil;
        [inv getReturnValue:&result];
        return [result isKindOfClass:[UIImage class]] ? result : nil;
    } @catch (__unused NSException *e) {}
    return nil;
}

- (UIImage *)_wallpaperViaFileSystem:(LGWallpaperVariant)variant {
    @try {
        NSArray<NSString *> *candidates;
        if (variant == LGWallpaperVariantLockScreen) {
            candidates = @[
                @"/var/mobile/Library/SpringBoard/LockBackground.jpg",
                @"/var/mobile/Library/SpringBoard/LockBackground.png",
                @"/var/wallpaper/lockbackground.jpg",
            ];
        } else {
            candidates = @[
                @"/var/mobile/Library/SpringBoard/HomeBackground.jpg",
                @"/var/mobile/Library/SpringBoard/HomeBackground.png",
                @"/var/wallpaper/homebackground.jpg",
            ];
        }
        for (NSString *path in candidates) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                UIImage *img = [UIImage imageWithContentsOfFile:path];
                if (img) return img;
            }
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

#pragma mark - 内部：模糊计算

- (UIImage *)_blurImage:(UIImage *)image radius:(CGFloat)radius style:(UIUserInterfaceStyle)style {
    if (!image || radius <= 0.01) return image;

    @autoreleasepool {
        // 限制处理尺寸，避免超大壁纸吃内存
        CGSize maxSize = CGSizeMake(1024, 1024);
        CGFloat scale = MIN(1.0, MIN(maxSize.width / image.size.width,
                                       maxSize.height / image.size.height));
        CGSize targetSize = CGSizeMake(image.size.width * scale,
                                        image.size.height * scale);

        CIImage *inputImage = [[CIImage alloc] initWithImage:image];
        if (!inputImage) return image;

        // 裁剪到目标尺寸（居中裁剪）
        CGRect cropRect = CGRectMake(
            (inputImage.extent.size.width - targetSize.width) / 2.0,
            (inputImage.extent.size.height - targetSize.height) / 2.0,
            targetSize.width, targetSize.height);
        inputImage = [inputImage imageByCroppingToRect:cropRect];

        // 高斯模糊
        CIFilter *blurFilter = [CIFilter filterWithName:@"CIGaussianBlur"];
        [blurFilter setValue:inputImage forKey:kCIInputImageKey];
        [blurFilter setValue:@(radius * 0.5) forKey:kCIInputRadiusKey]; // CI 半径和 UIKit 点换算
        CIImage *blurredImage = blurFilter.outputImage;

        // 裁剪掉模糊边缘溢出
        CGRect outputRect = CGRectInset(blurredImage.extent, radius, radius);
        blurredImage = [blurredImage imageByCroppingToRect:outputRect];

        // 深色模式下稍微压暗（模拟系统玻璃的深色适配）
        if (style == UIUserInterfaceStyleDark) {
            CIFilter *toneFilter = [CIFilter filterWithName:@"CIExposureAdjust"];
            [toneFilter setValue:blurredImage forKey:kCIInputImageKey];
            [toneFilter setValue:@(-0.3) forKey:kCIInputEVKey];
            blurredImage = toneFilter.outputImage;
        }

        if (!blurredImage) return image;

        // 渲染到 CGImage
        if (!_ciContext) {
            _ciContext = [CIContext contextWithOptions:@{
                kCIContextUseSoftwareRenderer: @NO,
                kCIContextPriorityRequestLow: @YES,
            }];
        }
        CGImageRef cgImage = [_ciContext createCGImage:blurredImage fromRect:blurredImage.extent];
        if (!cgImage) return image;

        UIImage *result = [UIImage imageWithCGImage:cgImage
                                                scale:image.scale
                                          orientation:UIImageOrientationUp];
        CGImageRelease(cgImage);
        return result ?: image;
    }
}

@end
