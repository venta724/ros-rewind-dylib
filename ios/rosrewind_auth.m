/*
 * ROS-Rewind Companion Auth Overlay Dylib (rosrewind_auth.dylib)
 *
 * Works alongside rosauthhook.dylib (preserving UniSDK _completeLogin, TLS, and NPK asset adoption):
 * 1. Owns its own transparent UIWindow + WKWebView (never leaves rosauthhook's _g_loginWindow stuck).
 * 2. Remember Me support via NSUserDefaults:
 *    - If Remember Me is saved, silently refreshes ticket via /v2/ros/relaunch_mobile_ios_v2 and
 *      calls ros_apply_ticket() so UILogin shows Account/Feedback icons and tapping PLAY enters
 *      the Lobby immediately with ZERO login popup!
 *    - If not logged in / logged out, suppresses the automatic startup popup so the user lands
 *      cleanly on Server Selection + Play first; tapping PLAY opens the Sign In / Register modal.
 * 3. Tapping the Account icon (ntOpenManager / ntSwitchAccount / ntLogin when already signed in)
 *    opens the Account Info modal (Left Poster + Right Username, GID, Status, and LOG OUT button).
 * 4. Calls rosauthhook.dylib's exported ros_apply_ticket(const char *) directly via dlsym()
 *    so ticket -> exchangeTicket -> _completeLogin() -> Lobby works reliably every time!
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

typedef void (*ros_apply_ticket_fn)(const char *ticket);

static IMP g_orig_ntLogin = NULL;
static IMP g_orig_ntOpenManager = NULL;
static IMP g_orig_ntLogout = NULL;
static IMP g_orig_contentVC_viewDidLoad = NULL;

static UIWindow *g_modalWindow = nil;
static BOOL g_suppressedInitialAutoLogin = NO;
static BOOL g_isAuthenticated = NO;
static NSTimeInterval g_launchTimestamp = 0;

static NSString * const kKeyRemember = @"rosrewind_remember";
static NSString * const kKeyUsername = @"rosrewind_username";
static NSString * const kKeyGid      = @"rosrewind_gid";
static NSString * const kKeySession  = @"rosrewind_session";

static void apply_ticket_to_rosauthhook(NSString *ticket) {
    if (ticket.length == 0) return;
    ros_apply_ticket_fn fn = (ros_apply_ticket_fn)dlsym(RTLD_DEFAULT, "ros_apply_ticket");
    if (fn) {
        NSLog(@"[rosrewind_auth] Calling ros_apply_ticket(%@)", ticket);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            fn([ticket UTF8String]);
        });
    } else {
        NSLog(@"[rosrewind_auth] ERROR: ros_apply_ticket symbol not found!");
    }
}

static void dismiss_modal_window(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_modalWindow) {
            g_modalWindow.hidden = YES;
            g_modalWindow.rootViewController = nil;
            g_modalWindow = nil;
        }
    });
}

@interface RosRewindModalVC : UIViewController <WKScriptMessageHandler, WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy) NSString *modalURLString;
@end

@implementation RosRewindModalVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.opaque = NO;

    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    [ucc addScriptMessageHandler:self name:@"rosAuth"];

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.userContentController = ucc;
    cfg.allowsInlineMediaPlayback = YES;

    WKWebView *wv = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
    wv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    wv.opaque = NO;
    wv.backgroundColor = [UIColor clearColor];
    wv.scrollView.backgroundColor = [UIColor clearColor];
    wv.scrollView.opaque = NO;
    wv.scrollView.bounces = NO;
    wv.navigationDelegate = self;
    self.webView = wv;
    [self.view addSubview:wv];

    NSURL *url = [NSURL URLWithString:self.modalURLString ?: @"https://api.roscambo.com/auth/modal"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:15.0];
    [wv loadRequest:req];
    NSLog(@"[rosrewind_auth] Presenting WKWebView modal -> %@", url);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.webView.frame = self.view.bounds;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"rosAuth"]) return;
    if (![message.body isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *dict = (NSDictionary *)message.body;
    NSString *action = dict[@"action"];

    if ([action isEqualToString:@"close"]) {
        NSLog(@"[rosrewind_auth] Modal closed by user");
        [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"rosAuth"];
        dismiss_modal_window();
        return;
    }

    if ([action isEqualToString:@"logout"]) {
        NSLog(@"[rosrewind_auth] User logged out — clearing saved session");
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setBool:NO forKey:kKeyRemember];
        [ud removeObjectForKey:kKeyUsername];
        [ud removeObjectForKey:kKeyGid];
        [ud removeObjectForKey:kKeySession];
        [ud synchronize];
        g_isAuthenticated = NO;
        return;
    }

    if ([action isEqualToString:@"authenticated"]) {
        NSString *ticket   = dict[@"ticket"] ?: @"";
        NSString *username = dict[@"username"] ?: @"Player";
        NSString *gid      = dict[@"gid"] ?: @"100001";
        NSString *session  = dict[@"session"] ?: @"";
        BOOL remember      = [dict[@"remember"] boolValue];

        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setBool:remember forKey:kKeyRemember];
        [ud setObject:username forKey:kKeyUsername];
        [ud setObject:gid forKey:kKeyGid];
        [ud setObject:session forKey:kKeySession];
        [ud synchronize];

        g_isAuthenticated = YES;
        NSLog(@"[rosrewind_auth] Authenticated user=%@ gid=%@ remember=%d -> applying ticket", username, gid, remember);
        [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"rosAuth"];
        dismiss_modal_window();
        apply_ticket_to_rosauthhook(ticket);
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

static void present_auth_modal(NSString *mode) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_modalWindow != nil) return;

        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }

        UIWindow *win = activeScene ? [[UIWindow alloc] initWithWindowScene:activeScene]
                                    : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        win.windowLevel = UIWindowLevelAlert + 10.0;
        win.backgroundColor = [UIColor clearColor];
        win.opaque = NO;

        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSString *savedUser = [ud stringForKey:kKeyUsername] ?: @"";
        NSString *savedGid  = [ud stringForKey:kKeyGid] ?: @"100001";
        NSString *encUser = [savedUser stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        NSString *urlStr = [NSString stringWithFormat:@"https://api.roscambo.com/auth/modal?mode=%@&username=%@&gid=%@",
                            mode ?: @"signin", encUser ?: @"", savedGid];

        RosRewindModalVC *vc = [[RosRewindModalVC alloc] init];
        vc.modalURLString = urlStr;
        win.rootViewController = vc;
        g_modalWindow = win;
        [win makeKeyAndVisible];
    });
}

/* Silent Remember-Me relaunch: fetches a fresh ticket for saved session without showing popup */
static void silent_relaunch_saved_session(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *session = [ud stringForKey:kKeySession] ?: @"";
    NSString *username = [ud stringForKey:kKeyUsername] ?: @"";
    if (username.length == 0) return;

    NSURL *url = [NSURL URLWithString:@"https://api.roscambo.com/v2/ros/relaunch_mobile_ios_v2"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{ @"session": session, @"username": username };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSession *sess = [NSURLSession sharedSession];
    [[sess dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!err && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *ticket = json[@"auth"];
            if ([json[@"success"] boolValue] && ticket.length > 0) {
                g_isAuthenticated = YES;
                NSLog(@"[rosrewind_auth] Remember Me silent login succeeded for %@", username);
                apply_ticket_to_rosauthhook(ticket);
                return;
            }
        }
        NSLog(@"[rosrewind_auth] Silent relaunch failed, user can sign in on Play");
    }] resume];
}

static void rosrewind_ntLogin(id self, SEL _cmd) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL remembered = [ud boolForKey:kKeyRemember] && ([ud stringForKey:kKeyUsername].length > 0);
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - g_launchTimestamp;

    /* Already authenticated in this run -> complete immediately without showing popup */
    if (g_isAuthenticated) {
        NSLog(@"[rosrewind_auth] ntLogin called while already authenticated -> continuing into game");
        if (g_orig_ntLogin) ((void (*)(id, SEL))g_orig_ntLogin)(self, _cmd);
        return;
    }

    /* Remember Me active -> silently authenticate without popup so Play & Account icon work */
    if (remembered) {
        NSLog(@"[rosrewind_auth] Remember Me active -> silent login");
        silent_relaunch_saved_session();
        return;
    }

    /* Initial startup auto-login -> suppress popup so user reaches Server Selection + Play first */
    if (!g_suppressedInitialAutoLogin && elapsed < 15.0) {
        g_suppressedInitialAutoLogin = YES;
        NSLog(@"[rosrewind_auth] Suppressed automatic startup ntLogin (elapsed=%.1fs)", elapsed);
        return;
    }

    /* User tapped PLAY while unauthenticated -> open Sign In / Register modal */
    present_auth_modal(@"signin");
}

static void rosrewind_ntOpenManager(id self, SEL _cmd) {
    NSLog(@"[rosrewind_auth] Account icon tapped (authenticated=%d)", g_isAuthenticated);
    present_auth_modal(g_isAuthenticated ? @"account" : @"signin");
}

static void rosrewind_ntLogout(id self, SEL _cmd) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:NO forKey:kKeyRemember];
    [ud removeObjectForKey:kKeyUsername];
    [ud removeObjectForKey:kKeyGid];
    [ud removeObjectForKey:kKeySession];
    [ud synchronize];
    g_isAuthenticated = NO;
    if (g_orig_ntLogout) ((void (*)(id, SEL))g_orig_ntLogout)(self, _cmd);
}

/*
 * Restyle RosContentVC (initial asset download screen) to replace the black "RoS Cambo" screen
 * with the authentic Rules of Survival ruins background (rosrewind_download_bg.jpg) + bottom
 * dark bar with status text, size counter, and RoS yellow (#F7E125) progress bar.
 */
static void rosrewind_contentVC_viewDidLoad(id self, SEL _cmd) {
    if (g_orig_contentVC_viewDidLoad) {
        ((void (*)(id, SEL))g_orig_contentVC_viewDidLoad)(self, _cmd);
    }

    UIViewController *vc = (UIViewController *)self;
    UIView *root = vc.view;
    if (!root) return;

    UILabel *statusLbl = nil;
    UILabel *detailLbl = nil;
    UIProgressView *bar = nil;
    UIButton *closeBtn = nil;

    @try {
        statusLbl = [vc valueForKey:@"status"];
        detailLbl = [vc valueForKey:@"detail"];
        bar       = [vc valueForKey:@"bar"];
        closeBtn  = [vc valueForKey:@"close"];
    } @catch (NSException *ex) {
        NSLog(@"[rosrewind_auth] RosContentVC KVC lookup warning: %@", ex);
    }

    /* Remove old RoS Cambo layout & labels */
    for (UIView *sub in [root.subviews copy]) {
        [sub removeFromSuperview];
    }

    root.backgroundColor = [UIColor blackColor];

    /* 1. Full-screen authentic Rules of Survival ruins background */
    NSString *bgPath = [[NSBundle mainBundle] pathForResource:@"rosrewind_download_bg" ofType:@"jpg"];
    UIImage *bgImg = bgPath ? [UIImage imageWithContentsOfFile:bgPath] : nil;
    if (bgImg) {
        UIImageView *bgView = [[UIImageView alloc] initWithImage:bgImg];
        bgView.contentMode = UIViewContentModeScaleAspectFill;
        bgView.clipsToBounds = YES;
        bgView.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:bgView];
        [NSLayoutConstraint activateConstraints:@[
            [bgView.topAnchor constraintEqualToAnchor:root.topAnchor],
            [bgView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
            [bgView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [bgView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        ]];
    }

    /* 2. Bottom dark tactical progress container */
    UIView *footer = [[UIView alloc] init];
    footer.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.10 alpha:0.80];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:footer];
    [NSLayoutConstraint activateConstraints:@[
        [footer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [footer.heightAnchor constraintEqualToConstant:72.0],
    ]];

    if (bar) {
        bar.translatesAutoresizingMaskIntoConstraints = NO;
        bar.progressTintColor = [UIColor colorWithRed:0.969 green:0.882 blue:0.145 alpha:1.0]; /* #F7E125 RoS Yellow */
        bar.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.22];
        bar.layer.cornerRadius = 3.0;
        bar.clipsToBounds = YES;
        [footer addSubview:bar];
        [NSLayoutConstraint activateConstraints:@[
            [bar.leadingAnchor constraintEqualToAnchor:footer.safeAreaLayoutGuide.leadingAnchor constant:24.0],
            [bar.trailingAnchor constraintEqualToAnchor:footer.safeAreaLayoutGuide.trailingAnchor constant:-24.0],
            [bar.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor constant:-18.0],
            [bar.heightAnchor constraintEqualToConstant:6.0],
        ]];
    }

    if (statusLbl) {
        statusLbl.translatesAutoresizingMaskIntoConstraints = NO;
        statusLbl.textColor = [UIColor whiteColor];
        statusLbl.font = [UIFont boldSystemFontOfSize:13.0];
        statusLbl.textAlignment = NSTextAlignmentLeft;
        [footer addSubview:statusLbl];
        [NSLayoutConstraint activateConstraints:@[
            [statusLbl.leadingAnchor constraintEqualToAnchor:footer.safeAreaLayoutGuide.leadingAnchor constant:24.0],
            [statusLbl.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor constant:-32.0],
        ]];
    }

    if (detailLbl) {
        detailLbl.translatesAutoresizingMaskIntoConstraints = NO;
        detailLbl.textColor = [UIColor colorWithRed:0.969 green:0.882 blue:0.145 alpha:1.0];
        detailLbl.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
        detailLbl.textAlignment = NSTextAlignmentRight;
        [footer addSubview:detailLbl];
        [NSLayoutConstraint activateConstraints:@[
            [detailLbl.trailingAnchor constraintEqualToAnchor:footer.safeAreaLayoutGuide.trailingAnchor constant:-24.0],
            [detailLbl.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor constant:-32.0],
        ]];
    }

    if (closeBtn) {
        closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:closeBtn];
        [NSLayoutConstraint activateConstraints:@[
            [closeBtn.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:12.0],
            [closeBtn.trailingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.trailingAnchor constant:-16.0],
        ]];
    }

    NSLog(@"[rosrewind_auth] Restyled RosContentVC with RoS ruins background + bottom yellow progress bar");
}

static void install_content_vc_hook(void) {
    static BOOL hooked = NO;
    if (hooked) return;
    Class contentVC = NSClassFromString(@"RosContentVC");
    if (contentVC) {
        Method mContent = class_getInstanceMethod(contentVC, @selector(viewDidLoad));
        if (mContent) {
            g_orig_contentVC_viewDidLoad = method_setImplementation(mContent, (IMP)rosrewind_contentVC_viewDidLoad);
            hooked = YES;
            NSLog(@"[rosrewind_auth] Wrapped RosContentVC::viewDidLoad (ruins download screen)");
        }
    }
}

static void install_rosrewind_hooks(void) {
    install_content_vc_hook();

    Class sdkBase = NSClassFromString(@"NtSdkBase");
    if (!sdkBase) {
        NSLog(@"[rosrewind_auth] Warning: NtSdkBase not found");
        return;
    }

    Method mLogin = class_getInstanceMethod(sdkBase, sel_registerName("ntLogin"));
    if (mLogin) {
        g_orig_ntLogin = method_setImplementation(mLogin, (IMP)rosrewind_ntLogin);
        NSLog(@"[rosrewind_auth] Wrapped NtSdkBase::ntLogin");
    }

    Method mMgr = class_getInstanceMethod(sdkBase, sel_registerName("ntOpenManager"));
    if (mMgr) {
        g_orig_ntOpenManager = method_setImplementation(mMgr, (IMP)rosrewind_ntOpenManager);
        NSLog(@"[rosrewind_auth] Wrapped NtSdkBase::ntOpenManager (Account icon)");
    }

    Method mLogout = class_getInstanceMethod(sdkBase, sel_registerName("ntLogout"));
    if (mLogout) {
        g_orig_ntLogout = method_setImplementation(mLogout, (IMP)rosrewind_ntLogout);
    }
}

__attribute__((constructor))
static void rosrewind_auth_init(void) {
    g_launchTimestamp = [[NSDate date] timeIntervalSince1970];
    /* Hook RosContentVC immediately so the download screen is styled even if shown right at launch */
    install_content_vc_hook();
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        /* Delay 0.25s so rosauthhook.dylib installs its hooks first, then we wrap them cleanly */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            install_rosrewind_hooks();
        });
    }];
}
