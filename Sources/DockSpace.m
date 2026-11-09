#import <AppKit/AppKit.h>
#include <dlfcn.h>

// Pizza owns the space and every attached window. Existing desktop spaces and
// system windows are never modified. A level-1 unmanaged space composites
// above Mission Control's level-0 spaces, below the system's screen-lock level.
static int (*pizzaMainConnection)(void);
static uint64_t (*pizzaCreateSpace)(int,int,CFDictionaryRef);
static void (*pizzaDestroySpace)(int,uint64_t);
static void (*pizzaSetSpaceLevel)(int,uint64_t,int);
static int (*pizzaGetSpaceLevel)(int,uint64_t);
static void (*pizzaAddWindows)(int,CFArrayRef,CFArrayRef);
static void (*pizzaRemoveWindows)(int,CFArrayRef,CFArrayRef);
static void (*pizzaShowSpaces)(int,CFArrayRef);
static void (*pizzaHideSpaces)(int,CFArrayRef);
static CFArrayRef (*pizzaWindowSpaces)(int,int,CFArrayRef);
static int (*pizzaWindowOwner)(int,uint32_t,int*);
static uint64_t pizzaSpace;
static int pizzaConnection;
static NSMutableSet<NSNumber*> *pizzaMembers;
static bool pizzaSpaceVisible;
static int pizzaSpaceStatus=-1;

static bool pizzaLoadSpaceFunctions(void) {
    static int loaded;
    if(loaded)return loaded>0;
    loaded=-1;
    void*h=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL);
    if(!h)return false;
#define LOAD(variable,symbol) variable=dlsym(h,symbol); if(!variable)return false;
    LOAD(pizzaMainConnection,"SLSMainConnectionID")
    LOAD(pizzaCreateSpace,"SLSSpaceCreate")
    LOAD(pizzaDestroySpace,"SLSSpaceDestroy")
    LOAD(pizzaSetSpaceLevel,"SLSSpaceSetAbsoluteLevel")
    LOAD(pizzaGetSpaceLevel,"SLSSpaceGetAbsoluteLevel")
    LOAD(pizzaAddWindows,"SLSAddWindowsToSpaces")
    LOAD(pizzaRemoveWindows,"SLSRemoveWindowsFromSpaces")
    LOAD(pizzaShowSpaces,"SLSShowSpaces")
    LOAD(pizzaHideSpaces,"SLSHideSpaces")
    LOAD(pizzaWindowSpaces,"SLSCopySpacesForWindows")
    LOAD(pizzaWindowOwner,"SLSGetWindowOwner")
#undef LOAD
    int*lockLevel=dlsym(h,"kSLSSpaceAbsoluteLevelScreenLock");
    if(!lockLevel || *lockLevel<=1)return false;
    loaded=1;return true;
}
bool PizzaDockSpaceAttach(uint32_t window) {
    NSCAssert([NSThread isMainThread],@"Dock space runs on the main thread");
    if(!window || !pizzaLoadSpaceFunctions()){pizzaSpaceStatus=-2;return false;}
    int connection=pizzaMainConnection(),owner=0;
    if(pizzaWindowOwner(connection,window,&owner)!=0 || owner!=connection){pizzaSpaceStatus=-3;return false;}
    if(pizzaSpace && [pizzaMembers containsObject:@(window)])return true;
    if(!pizzaSpace) {
        uint64_t created=pizzaCreateSpace(connection,1,NULL);
        if(!created){pizzaSpaceStatus=-4;return false;}
        pizzaSetSpaceLevel(connection,created,1);
        if(pizzaGetSpaceLevel(connection,created)!=1){pizzaDestroySpace(connection,created);pizzaSpaceStatus=-5;return false;}
        pizzaSpace=created;pizzaConnection=connection;pizzaMembers=[NSMutableSet set];
    }
    NSArray*spaces=@[@(pizzaSpace)],*windows=@[@(window)];
    pizzaAddWindows(pizzaConnection,(__bridge CFArrayRef)windows,(__bridge CFArrayRef)spaces);
    NSArray*actual=CFBridgingRelease(pizzaWindowSpaces(pizzaConnection,31,(__bridge CFArrayRef)windows));
    if(![actual containsObject:@(pizzaSpace)]){pizzaSpaceStatus=-6;return false;}
    [pizzaMembers addObject:@(window)];
    pizzaShowSpaces(pizzaConnection,(__bridge CFArrayRef)spaces);
    pizzaSpaceVisible=true;pizzaSpaceStatus=0;return true;
}
void PizzaDockSpaceDetach(uint32_t window) {
    if(!pizzaSpace || ![pizzaMembers containsObject:@(window)])return;
    pizzaRemoveWindows(pizzaConnection,(__bridge CFArrayRef)@[@(window)],(__bridge CFArrayRef)@[@(pizzaSpace)]);
    [pizzaMembers removeObject:@(window)];
}
void PizzaDockSpaceSetVisible(bool visible) {
    if(!pizzaSpace)return;
    if(visible)pizzaShowSpaces(pizzaConnection,(__bridge CFArrayRef)@[@(pizzaSpace)]);
    else pizzaHideSpaces(pizzaConnection,(__bridge CFArrayRef)@[@(pizzaSpace)]);
    pizzaSpaceVisible=visible;
}
void PizzaDockSpaceSetMenuTracking(bool tracking) {
    if(pizzaSpace)pizzaSetSpaceLevel(pizzaConnection,pizzaSpace,tracking?0:1);
}
void PizzaDockSpaceDestroy(void) {
    if(!pizzaSpace)return;
    PizzaDockSpaceSetVisible(false);
    if(pizzaMembers.count)pizzaRemoveWindows(pizzaConnection,(__bridge CFArrayRef)pizzaMembers.allObjects,(__bridge CFArrayRef)@[@(pizzaSpace)]);
    pizzaDestroySpace(pizzaConnection,pizzaSpace);pizzaSpace=0;pizzaMembers=nil;
}
uint64_t PizzaDockSpaceIdentifier(void) {return pizzaSpace;}
int PizzaDockSpaceStatus(void) {return pizzaSpaceStatus;}
bool PizzaDockSpaceIsVisible(void) {return pizzaSpaceVisible;}
