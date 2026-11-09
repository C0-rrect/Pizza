#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <string.h>
@interface NSObject (PizzaCacheRead)
- (id)initWithURL:(NSURL *)url;
- (id)initWithBundleIdentifier:(NSString *)identifier;
- (id)icon;
- (id)digest;
- (id)initWithSize:(CGSize)size scale:(double)scale;
- (id)imageForDescriptor:(id)descriptor;
- (id)prepareImageForDescriptor:(id)descriptor;
- (CGImageRef)CGImageForDescriptor:(id)descriptor;
+ (id)defaultIconCache;
- (id)storeIndex;
@end
// Read-only identity/index bridge. No database or cache mutation occurs here.
char *PizzaCopyCacheSnapshot(const char *input) { @autoreleasepool {
    @try {
        if (!dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices",RTLD_LAZY)) return strdup("{}");
        NSArray *apps=[NSJSONSerialization JSONObjectWithData:[@(input) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSMutableDictionary *identities=[NSMutableDictionary dictionary];
        for (NSDictionary *app in apps) {
            NSMutableArray *digests=[NSMutableArray array];
            id icon=[[NSClassFromString(@"ISIcon") alloc] initWithURL:[NSURL fileURLWithPath:app[@"path"]]];
            if ([icon respondsToSelector:@selector(icon)]) icon=[icon icon];
            // Request the normal Finder/Dock sizes through IconServices itself.
            // This also recreates missing cache entries after macOS evicts its index.
            for (NSNumber *size in @[@16,@32,@128]) {
                for (NSNumber *scale in @[@1,@2]) {
                    id descriptor=[[NSClassFromString(@"ISImageDescriptor") alloc] initWithSize:CGSizeMake(size.doubleValue,size.doubleValue) scale:scale.doubleValue];
                    [icon prepareImageForDescriptor:descriptor];
                    [icon CGImageForDescriptor:descriptor];
                }
            }
            if ([icon respondsToSelector:@selector(digest)] && [icon digest]) [digests addObject:[[icon digest] description]];
            id bundleIcon=[[NSClassFromString(@"ISBundleIdentifierIcon") alloc] initWithBundleIdentifier:app[@"bundleID"]];
            if ([bundleIcon respondsToSelector:@selector(digest)] && [bundleIcon digest]) [digests addObject:[[bundleIcon digest] description]];
            identities[app[@"bundleID"]]=digests;
        }
        id cache=[NSClassFromString(@"ISIconCache") defaultIconCache];
        NSDictionary *result=@{@"identities":identities,@"index":[[cache storeIndex] description]?:@""};
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        return strdup([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String?:"{}");
    } @catch (NSException *exception) { return strdup("{}"); }
}}
