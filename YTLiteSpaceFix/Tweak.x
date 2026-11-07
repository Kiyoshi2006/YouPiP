// YTLiteSpaceFix
//
// YTLite kiểm tra dung lượng trước khi tải bằng cách hỏi chính YouTube
// (-freeDeviceStorageBytes), rồi đòi trống > 2 x kích thước file.
// Hàm của YouTube trả dung lượng trống "thật", không tính phần iOS tự giải
// phóng khi cần (cache, purgeable), nên thấp hơn nhiều so với con số trong
// Cài đặt > Dung lượng iPhone.
//
// Tweak này nâng giá trị trả về lên mức "available capacity for important
// usage" theo chuẩn của Apple, nếu mức đó lớn hơn.
//
// LƯU Ý: tuyệt đối không dùng class_getInstanceMethod / class_getClassMethod
// để dò. Với method không tồn tại, chúng gọi +resolveInstanceMethod: và ép
// lớp chạy +initialize, làm YouTube sập lúc khởi động. Ở đây chỉ dùng
// class_copyMethodList (chỉ đọc danh sách method của chính lớp đó).

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

static SEL kSel;

static int64_t importantFree(void) {
    NSURL *url = [NSURL fileURLWithPath:NSHomeDirectory()];
    NSNumber *n = nil;
    NSError *err = nil;
    if ([url getResourceValue:&n forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:&err] && n)
        return n.longLongValue;
    return 0;
}

// target là lớp thường (hàm instance) hoặc metaclass (hàm class).
// Chỉ vá method do chính lớp đó khai báo. Trả về số method đã vá.
static int patchOwnMethods(Class target) {
    unsigned int count = 0;
    Method *list = class_copyMethodList(target, &count);
    if (!list) return 0;

    int done = 0;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(list[i]) != kSel) continue;

        // chỉ vá khi kiểu trả về là số nguyên 8 byte
        char *ret = method_copyReturnType(list[i]);
        BOOL ok = ret && (ret[0] == 'q' || ret[0] == 'Q' || ret[0] == 'l' || ret[0] == 'L');
        if (ret) free(ret);
        if (!ok) {
            NSLog(@"[YTLiteSpaceFix] bỏ qua %s: kiểu trả về không phải số nguyên", class_getName(target));
            continue;
        }

        IMP orig = method_getImplementation(list[i]);
        int64_t (^blk)(id) = ^int64_t(id selfObj) {
            int64_t v = ((int64_t (*)(id, SEL))orig)(selfObj, kSel);
            int64_t big = importantFree();
            return big > v ? big : v;
        };
        method_setImplementation(list[i], imp_implementationWithBlock(blk));
        NSLog(@"[YTLiteSpaceFix] đã vá %s", class_getName(target));
        done++;
    }
    free(list);
    return done;
}

static int patchClass(Class c) {
    if (!c) return 0;
    return patchOwnMethods(c) + patchOwnMethods(object_getClass(c));
}

__attribute__((constructor))
static void init(void) {
    kSel = @selector(freeDeviceStorageBytes);

    // YTLite gọi hàm này trên YTAutoOfflineController, thử đúng lớp đó trước
    int n = patchClass(objc_lookUpClass("YTAutoOfflineController"));
    if (n > 0) return;

    // Không thấy thì quét toàn bộ lớp, chạy nền để không làm chậm lúc mở app.
    // Người dùng chỉ tải video sau khi app đã mở nên kịp vá.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        int total = 0;
        for (unsigned int i = 0; i < count; i++)
            total += patchClass(classes[i]);
        free(classes);
        NSLog(@"[YTLiteSpaceFix] quét toàn bộ lớp xong, đã vá %d hàm", total);
    });
}
