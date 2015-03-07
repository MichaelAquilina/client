//
//  KBRPClient.m
//  Keybase
//
//  Created by Gabriel on 12/15/14.
//  Copyright (c) 2014 Gabriel Handford. All rights reserved.
//

#import "KBRPClient.h"
#import "KBRPC.h"
#import "KBRUtils.h"
#import "KBAlert.h"
#import "AppDelegate.h"
#import "KBRPCRegistration.h"
#import "KBInstaller.h"
#import "KBRPCRecord.h"

#import <MPMessagePack/MPMessagePackServer.h>
#import <NAChloride/NAChloride.h>

@interface KBRPClient ()
@property MPMessagePackClient *client;
@property MPMessagePackServer *server;
@property MPOrderedDictionary *registrations;

@property NSString *socketPath;
@property KBRPCRecord *recorder;

@property NSInteger connectAttempt;
@property KBRPClientStatus status;
@end

@implementation KBRPClient

- (instancetype)init {
  if ((self = [super init])) {
    NSString *user = [NSProcessInfo.processInfo.environment objectForKey:@"USER"];
    NSAssert(user, @"No user");
    self.socketPath = NSStringWithFormat(@"/tmp/keybase-%@/keybased.sock", user);
#ifdef DEBUG
    self.socketPath = @"/tmp/keybase-debug.sock";
#endif

  }
  return self;
}

- (void)open {
  [self open:nil];
}

- (void)open:(void (^)(NSError *error))completion {
  NSAssert(self.status == KBRPClientStatusNone, @"Not closed");

  _status = KBRPClientStatusOpening;

  _client = [[MPMessagePackClient alloc] initWithName:@"KBRPClient" options:MPMessagePackOptionsFramed];
  _client.delegate = self;

  _recorder = [[KBRPCRecord alloc] init];
  
  GHWeakSelf gself = self;
  _client.requestHandler = ^(NSNumber *messageId, NSString *method, NSArray *params, MPRequestCompletion completion) {
    GHDebug(@"Received request: %@(%@)", method, [params join:@", "]);

    id sessionId = [[params lastObject] objectForKey:@"sessionID"];

    if ([NSUserDefaults.standardUserDefaults boolForKey:@"Preferences.Advanced.Record"]) {
      [gself.recorder recordRequest:method params:params sessionId:[sessionId integerValue] callback:YES];
    }
    MPRequestHandler requestHandler;
    if (sessionId) {
      KBRPCRegistration *registration = gself.registrations[sessionId];
      requestHandler = [registration requestHandlerForMethod:method];
    }
    if (!requestHandler) requestHandler = [gself _requestHandlerForMethod:method]; // TODO: Remove when we have session id in all requests
    if (requestHandler) {
      requestHandler(messageId, method, params, completion);
    } else {
      GHDebug(@"No handler for request: %@", method);
      completion(KBMakeError(-1, @"Method not found: %@", method), nil);
    }
  };

  _client.coder = [[KBRPCCoder alloc] init];

  GHDebug(@"Connecting to keybased (%@)...", self.socketPath);
  _connectAttempt++;
  [_client openWithSocket:self.socketPath completion:^(NSError *error) {
    if (error) {
      GHDebug(@"Error connecting to keybased: %@", error);
      if (!gself.autoRetryDisabled) {
        // Retry
        [self openAfterDelay:2];
      } else {
        if (completion) completion(error);
      }
      [self.delegate RPClient:self didErrorOnConnect:error connectAttempt:gself.connectAttempt];
      return;
    }

    GHDebug(@"Connected");
    gself.connectAttempt = 1;
    gself.status = KBRPClientStatusOpen;
    [self.delegate RPClientDidConnect:self];
    if (completion) completion(nil);
  }];
}

// Request handler for method of any session (Will be deprecated)
- (MPRequestHandler)_requestHandlerForMethod:(NSString *)method {
  NSMutableArray *requestHandlers = [NSMutableArray array];
  for (id key in [self.registrations reverseKeyEnumerator]) {
    KBRPCRegistration *registration = self.registrations[key];
    MPRequestHandler requestHandler = [registration requestHandlerForMethod:method];
    if (requestHandler) [requestHandlers addObject:requestHandler];
  }
  NSCAssert([requestHandlers count] < 2, @"More than 1 registered request handler");
  return [requestHandlers firstObject];
}

- (NSInteger)nextSessionId {
  static NSInteger gSessionId = 0;
  return ++gSessionId;
}

- (void)close {
  [_client close];
  self.status = KBRPClientStatusNone;
  [self.delegate RPClientDidDisconnect:self];
}

- (void)openAfterDelay:(NSTimeInterval)delay {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [self open:nil];
  });
}

- (void)sendRequestWithMethod:(NSString *)method params:(NSArray *)params sessionId:(NSInteger)sessionId completion:(MPRequestCompletion)completion {
  if (_client.status != MPMessagePackClientStatusOpen) {
    completion(KBMakeError(-400, @"We are unable to connect to the keybase daemon."), nil);
    return;
  }

  NSAssert(sessionId > 0, @"Bad session id");

  [_client sendRequestWithMethod:method params:params messageId:sessionId completion:^(NSError *error, id result) {
    [self unregister:sessionId];
    if (error) {
      GHDebug(@"Error: %@", error);
      NSDictionary *errorInfo = error.userInfo[MPErrorInfoKey];
      error = KBMakeErrorWithRecovery(error.code, NSStringWithFormat(@"Oops, we had a problem (%@).", @(error.code)), @"%@: %@", errorInfo[@"name"], errorInfo[@"desc"]);
    }
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"Preferences.Advanced.Record"]) {
      if (result) [self.recorder recordResponse:method response:result sessionId:sessionId];
    }
    GHDebug(@"Result: %@", result);
    completion(error, result);
  }];

  NSMutableArray *mparams = [params mutableCopy];
  mparams[0] = KBScrubPassphrase(params[0]);

  //NSNumber *messageId = request[1];
  GHDebug(@"Sent request: %@(%@)", method, mparams);
  if ([NSUserDefaults.standardUserDefaults boolForKey:@"Preferences.Advanced.Record"]) {
    [self.recorder recordRequest:method params:[_client encodeObject:params] sessionId:sessionId callback:NO];
  }
}

- (void)check:(void (^)(NSError *error))completion {
  KBRConfigRequest *config = [[KBRConfigRequest alloc] initWithClient:self];
  [config getCurrentStatus:^(NSError *error, KBRGetCurrentStatusRes *status) {
    completion(error);
  }];
}

- (void)registerMethod:(NSString *)method sessionId:(NSInteger)sessionId requestHandler:(MPRequestHandler)requestHandler {
  if (!self.registrations) self.registrations = [MPOrderedDictionary dictionary];
  KBRPCRegistration *registration = self.registrations[@(sessionId)];
  if (!registration) {
    registration = [[KBRPCRegistration alloc] init];
    self.registrations[@(sessionId)] = registration;
  }
  [registration registerMethod:method requestHandler:requestHandler];
}

- (void)unregister:(NSInteger)sessionId {
  [self.registrations removeObjectForKey:@(sessionId)];
}

- (void)openAndCheck:(void (^)(NSError *error))completion {
  [self open:^(NSError *error) {
    if (error) {
      completion(error);
      return;
    }
    [self check:^(NSError *error) {
      if (error) {
        completion(error);
        return;
      }
    }];
    completion(nil);
  }];
}

- (void)checkInstall:(KBCompletionBlock)completion {
  KBInstaller *installer = [[KBInstaller alloc] init];
  [installer checkInstall:^(NSError *error, BOOL installed, KBInstallType installType) {
    GHDebug(@"Installed? %@, Type: %@", @(installed), @(installType));
    completion(error);
  }];
}

NSDictionary *KBScrubPassphrase(NSDictionary *dict) {
  NSMutableDictionary *mdict = [dict mutableCopy];
  if (mdict[@"passphrase"]) mdict[@"passphrase"] = @"[FILTERED PASSPHRASE]";
  if (mdict[@"password"]) mdict[@"password"] = @"[FILTERED PASSWORD]";
  if (mdict[@"inviteCode"]) mdict[@"inviteCode"] = @"[FILTERED INVITE CODE]";
  if (mdict[@"email"]) mdict[@"email"] = @"[FILTERED EMAIL]";
  return mdict;
}

#pragma mark -

- (void)client:(MPMessagePackClient *)client didError:(NSError *)error fatal:(BOOL)fatal {
  GHDebug(@"Error (fatal=%d): %@", fatal, error);
}

- (void)client:(MPMessagePackClient *)client didChangeStatus:(MPMessagePackClientStatus)status {
  if (status == MPMessagePackClientStatusClosed) {
    // TODO: What if we have open requests?
    if (!_autoRetryDisabled) [self openAfterDelay:2];
  } else if (status == MPMessagePackClientStatusOpen) {
    
  }
}

- (void)client:(MPMessagePackClient *)client didReceiveNotificationWithMethod:(NSString *)method params:(id)params {
  GHDebug(@"Notification: %@(%@)", method, [params join:@","]);
}

@end

@implementation KBRPCCoder
- (id)encodeObject:(id)obj {
  return [obj conformsToProtocol:@protocol(MTLJSONSerializing)] ? [MTLJSONAdapter JSONDictionaryFromModel:obj] : obj;
}
@end