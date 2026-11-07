// YTLiteSpaceFix
//
// YTLite kiểm tra dung lượng trước khi tải bằng cách hỏi chính YouTube
// (-freeDeviceStorageBytes), rồi đòi trống > 2 x kích thước file.
// Hàm của YouTube trả dung lượng trống "thật", không tính phần iOS tự giải
// phóng khi cần (cache, purgeable), nên thấp hơn nhiều so với con số trong
// Cài đặt > Dung lượng iPhone.
//
// Tweak này tìm mọi lớp có hàm freeDeviceStorageBytes (kiểu số nguyên 8 byte)
// và nâng giá trị trả về lên mức "available capacity for important usage"
// theo chuẩn của Apple, nếu mức đó lớn hơn.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static SEL kSel;

static int64_t importantFree(void) {
    NSURL *url = [NSURL fileURLWithPath:NSHomeDirectory()];
    NSNumber *n = nil;
    NSError *err = nil;
    if ([url getResourceValue:&n forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:&err] && n)
        return n.longLongValue;
    return 0;
}

// target có thể là lớp thường (hàm instance) hoặc metaclass (hàm class)
static void patchOn(Class target) {
    Method m = class_getInstanceMethod(target, kSel);
    if (!m) return;

    // chỉ vá khi chính lớp này tự định nghĩa, không vá hàm thừa kế
    Class sup = class_getSuperclass(target);
    if (sup) {
        Method sm = class_getInstanceMethod(sup, kSel);
        if (sm && method_getImplementation(sm) == method_getImplementation(m)) return;
    }

    // chỉ vá khi kiểu trả về là số nguyên 8 byte
    char *ret = method_copyReturnType(m);
    BOOL ok = ret && (ret[0] == 'q' || ret[0] == 'Q' || ret[0] == 'l' || ret[0] == 'L');
    if (ret) free(ret);
    if (!ok) {
        NSLog(@"[YTLiteSpaceFix] bỏ qua %s: kiểu trả về không phải số nguyên", class_getName(target));
        return;
    }

    IMP orig = method_getImplementation(m);
    int64_t (^blk)(id) = ^int64_t(id selfObj) {
        int64_t v = ((int64_t (*)(id, SEL))orig)(selfObj, kSel);
        int64_t big = importantFree();
        return big > v ? big : v;
    };
    method_setImplementation(m, imp_implementationWithBlock(blk));
    NSLog(@"[YTLiteSpaceFix] đã vá %s", class_getName(target));
}

__attribute__((constructor))
static void init(void) {
    kSel = @selector(freeDeviceStorageBytes);
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        Class c = list[i];
        patchOn(c);
        patchOn(object_getClass(c));
    }
    free(list);
}
