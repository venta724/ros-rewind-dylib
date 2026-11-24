/*
 * ROS-Rewind Companion Auth Overlay Dylib (rosrewind_auth.dylib)
 *
 * Works alongside rosauthhook.dylib (preserving UniSDK _completeLogin, TLS, and NPK asset adoption):
 * 1. Suppresses the automatic startup ntLogin popup so the user lands cleanly on the
 *    Server Selection + Play interface first.
 * 2. When the user taps PLAY (while unauthenticated) or taps the Account icon,
 *    replaces RosLoginVC's native UI with a transparent WKWebView overlay loading
 *    https://api.roscambo.com/auth/modal (centered two-panel Sign In / Register modal
 *    over the dimmed live game, zero reload).
 * 3. On Sign In / Register success, hands the launch ticket straight into rosauthhook.dylib's
 *    rosmobile://auth?ticket=<ticket> callback -> _completeLogin().
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static IMP g_orig_rosLogin_viewDidLoad = NULL;
static IMP g_orig_rosLogin_layout = NULL;
static IMP g_orig_ntLogin = NULL;
static BOOL g_suppressedInitialAutoLogin = NO;
static BOOL g_hasCompletedAuth = NO;
static NSTimeInterval g_launchTimestamp = 0;

@interface RosRewindModalBridge : NSObject <WKScriptMessageHandler, WKNavigationDelegate>
@property (nonatomic, weak) UIViewController *hostVC;
@property (nonatomic, strong) WKWebView *webView;
@end

@implementation RosRewindModalBridge

- (void)dismissHostWindow {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = self.hostVC.view.window;
        if (win) {
            win.hidden = YES;
            win.rootViewController = nil;
        }
        [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"rosAuth"];
        self.webView = nil;
    });
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"rosAuth"]) return;
    if (![message.body isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *dict = (NSDictionary *)message.body;
    NSString *action = dict[@"action"];

    if ([action isEqualToString:@"close"]) {
        NSLog(@"[rosrewind_auth] User closed auth modal");
        [self dismissHostWindow];
        return;
    }

    if ([action isEqualToString:@"authenticated"]) {
        NSString *ticket = dict[@"ticket"];
        NSString *username = dict[@"username"] ?: @"Player";
        NSLog(@"[rosrewind_auth] Authenticated user=%@ ticket=%@", username, ticket);
        g_hasCompletedAuth = YES;
        [self dismissHostWindow];

        if (ticket.length > 0) {
            NSString *encoded = [ticket stringByAddingPercentEncodingWithAllowedCharacters:
                                 [NSCharacterSet URLQueryAllowedCharacterSet]];
            NSString *urlStr = [NSString stringWithFormat:@"rosmobile://auth?ticket=%@", encoded];
            NSURL *url = [NSURL URLWithString:urlStr];
            dispatch_async(dispatch_get_main_queue(), ^{
                id<UIApplicationDelegate> del = [UIApplication sharedApplication].delegate;
                if ([del respondsToSelector:@selector(application:openURL:options:)]) {
                    [del application:[UIApplication sharedApplication] openURL:url options:@{}];
                } else {
                    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
                }
            });
        }
    }
}

/* Accept local ROS-Rewind LAN HTTPS certificate inside WKWebView */
- (void)webView:(WKWebView *)webView
didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]
        && challenge.protectionSpace.serverTrust != NULL) {
        NSURLCredential *cred = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
        completionHandler(NSURLSessionAuthChallengeUseCredential, cred);
        return;
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

@end

static const void *kBridgeAssocKey = &kBridgeAssocKey;

static void rosrewind_viewDidLoad(id self, SEL _cmd) {
    UIViewController *vc = (UIViewController *)self;
    /* Make host VC and its overlay window transparent so the live game shows behind the dimmed modal */
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.opaque = NO;
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (vc.view.window) {
            vc.view.window.backgroundColor = [UIColor clearColor];
            vc.view.window.opaque = NO;
        }
    });

    /* Remove any existing subviews from RosLoginVC */
    for (UIView *sub in vc.view.subviews) {
        [sub removeFromSuperview];
    }

    RosRewindModalBridge *bridge = [[RosRewindModalBridge alloc] init];
    bridge.hostVC = vc;

    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    [ucc addScriptMessageHandler:bridge name:@"rosAuth"];

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.userContentController = ucc;
    cfg.allowsInlineMediaPlayback = YES;

    WKWebView *wv = [[WKWebView alloc] initWithFrame:vc.view.bounds configuration:cfg];
    wv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    wv.opaque = NO;
    wv.backgroundColor = [UIColor clearColor];
    wv.scrollView.backgroundColor = [UIColor clearColor];
    wv.scrollView.opaque = NO;
    wv.scrollView.bounces = NO;
    wv.navigationDelegate = bridge;

    bridge.webView = wv;
    objc_setAssociatedObject(vc, kBridgeAssocKey, bridge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [vc.view addSubview:wv];

    NSURL *url = [NSURL URLWithString:@"https://api.roscambo.com/auth/modal"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:15.0];
    [wv loadRequest:req];
    NSLog(@"[rosrewind_auth] Presented transparent WKWebView modal -> %@", url);
}

static void rosrewind_viewDidLayoutSubviews(id self, SEL _cmd) {
    UIViewController *vc = (UIViewController *)self;
    RosRewindModalBridge *bridge = objc_getAssociatedObject(vc, kBridgeAssocKey);
    if (bridge.webView) {
        bridge.webView.frame = vc.view.bounds;
    }
    if (vc.view.window) {
        vc.view.window.backgroundColor = [UIColor clearColor];
        vc.view.window.opaque = NO;
    }
}

static void rosrewind_ntLogin(id self, SEL _cmd) {
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - g_launchTimestamp;
    /* Suppress ONLY the first automatic startup ntLogin call (within initial launch)
       so the user reaches Server Selection + Play naturally without a forced popup. */
    if (!g_suppressedInitialAutoLogin && !g_hasCompletedAuth && elapsed < 15.0) {
        g_suppressedInitialAutoLogin = YES;
        NSLog(@"[rosrewind_auth] Suppressed automatic startup ntLogin (elapsed=%.1fs); waiting for Play or Account tap", elapsed);
        return;
    }
    if (g_orig_ntLogin) {
        ((void (*)(id, SEL))g_orig_ntLogin)(self, _cmd);
    }
}

static void install_rosrewind_hooks(void) {
    Class loginVC = NSClassFromString(@"RosLoginVC");
    if (loginVC) {
        Method mLoad = class_getInstanceMethod(loginVC, @selector(viewDidLoad));
        if (mLoad) {
            g_orig_rosLogin_viewDidLoad = method_setImplementation(mLoad, (IMP)rosrewind_viewDidLoad);
        }
        Method mLayout = class_getInstanceMethod(loginVC, @selector(viewDidLayoutSubviews));
        if (mLayout) {
            g_orig_rosLogin_layout = method_setImplementation(mLayout, (IMP)rosrewind_viewDidLayoutSubviews);
        }
        NSLog(@"[rosrewind_auth] Hooked RosLoginVC -> transparent WKWebView modal");
    } else {
        NSLog(@"[rosrewind_auth] Warning: RosLoginVC class not found yet");
    }

    Class sdkBase = NSClassFromString(@"NtSdkBase");
    if (sdkBase) {
        SEL loginSel = sel_registerName("ntLogin");
        Method mLogin = class_getInstanceMethod(sdkBase, loginSel);
        if (mLogin) {
            g_orig_ntLogin = method_setImplementation(mLogin, (IMP)rosrewind_ntLogin);
            NSLog(@"[rosrewind_auth] Wrapped NtSdkBase::ntLogin (auto-login suppression active)");
        }
    }
}

__attribute__((constructor))
static void rosrewind_auth_init(void) {
    g_launchTimestamp = [[NSDate date] timeIntervalSince1970];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        /* Delay 0.25s so rosauthhook.dylib finishes its own didFinishLaunching swizzles first */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            install_rosrewind_hooks();
        });
    }];
}
