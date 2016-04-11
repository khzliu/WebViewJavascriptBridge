//
//  WebViewJavascriptBridgeBase.m
//
//  Created by @LokiMeyburg on 10/15/14.
//  Copyright (c) 2014 @LokiMeyburg. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "WebViewJavascriptBridgeBase.h"

@implementation WebViewJavascriptBridgeBase {
    id _webViewDelegate;
    long _uniqueId;
    NSBundle *_resourceBundle;
}

static bool logging = false;

+ (void)enableLogging { logging = true; }

//初始化Bridge ，并指定接收到Javascript消息的默认的handler方法
-(id)initWithHandler:(WVJBHandler)messageHandler resourceBundle:(NSBundle*)bundle
{
    self = [super init];
    _resourceBundle = bundle;
    self.messageHandler = messageHandler;
    self.messageHandlers = [NSMutableDictionary dictionary];
    self.startupMessageQueue = [NSMutableArray array];
    self.responseCallbacks = [NSMutableDictionary dictionary];
    _uniqueId = 0;
    return(self);
}

- (void)dealloc {
    self.startupMessageQueue = nil;
    self.responseCallbacks = nil;
    self.messageHandlers = nil;
    self.messageHandler = nil;
}
//清空消息队列，还原初始化状态
- (void)reset {
    self.startupMessageQueue = [NSMutableArray array];
    self.responseCallbacks = [NSMutableDictionary dictionary];
    _uniqueId = 0;
}

//向javascript发送消息 消息
- (void)sendData:(id)data responseCallback:(WVJBResponseCallback)responseCallback handlerName:(NSString*)handlerName {
    
    //封装消息体
    NSMutableDictionary* message = [NSMutableDictionary dictionary];
    
    if (data) {
        message[@"data"] = data;
    }
    
    if (responseCallback) {
        NSString* callbackId = [NSString stringWithFormat:@"objc_cb_%ld", ++_uniqueId];
        self.responseCallbacks[callbackId] = [responseCallback copy];
        message[@"callbackId"] = callbackId;
    }
    
    if (handlerName) {
        message[@"handlerName"] = handlerName;
    }
    //把消息体加入消息队列
    [self _queueMessage:message];
}

/** 处理 javascript 对 oc 的调用 -write by khzliu */

- (void)flushMessageQueue:(NSString *)messageQueueString{
    id messages = [self _deserializeMessageJSON:messageQueueString];
    if (![messages isKindOfClass:[NSArray class]]) {
        NSLog(@"WebViewJavascriptBridge: WARNING: Invalid %@ received: %@", [messages class], messages);
        return;
    }
    for (WVJBMessage* message in messages) {
        if (![message isKindOfClass:[WVJBMessage class]]) {
            NSLog(@"WebViewJavascriptBridge: WARNING: Invalid %@ received: %@", [message class], message);
            continue;
        }
        [self _log:@"RCVD" json:message];
        
        NSString* responseId = message[@"responseId"];
        if (responseId) {//这里表示该消息是不是OC调用JS之后的一个回调消息 如果是则走这里
            WVJBResponseCallback responseCallback = _responseCallbacks[responseId];
            responseCallback(message[@"responseData"]);
            [self.responseCallbacks removeObjectForKey:responseId];
        } else {//这里表示JS主动调用OC的方法
            WVJBResponseCallback responseCallback = NULL;
            
            //获取JS传来消息的Callback ID
            NSString* callbackId = message[@"callbackId"];
            if (callbackId) {
                //如果JS传了callback 这就建立一个OC的Callback 以供调起JS的callback
                responseCallback = ^(id responseData) {
                    if (responseData == nil) {
                        responseData = [NSNull null];
                    }
                    
                    WVJBMessage* msg = @{ @"responseId":callbackId, @"responseData":responseData };
                    [self _queueMessage:msg];
                };
            } else {
                responseCallback = ^(id ignoreResponseData) {
                    // Do nothing
                };
            }
            
            //获取处理该消息的方法，如果没有，则使用默认处理方法
            WVJBHandler handler;
            if (message[@"handlerName"]) {
                handler = self.messageHandlers[message[@"handlerName"]];
            } else {
                handler = self.messageHandler;
            }
            
            if (!handler) {
                [NSException raise:@"WVJBNoHandlerException" format:@"No handler for message from JS: %@", message];
            }
            
            handler(message[@"data"], responseCallback);
        }
    }
}

//注入本地的WebViewJavascriptBridge.js.txt文件
- (void)injectJavascriptFile:(BOOL)shouldInject {
    if(shouldInject){
        NSBundle *bundle = _resourceBundle ? _resourceBundle : [NSBundle mainBundle];
        NSString *filePath = [bundle pathForResource:@"WebViewJavascriptBridge.js" ofType:@"txt"];
        NSString *js = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:nil];
        [self _evaluateJavascript:js];
        [self dispatchStartUpMessageQueue];
    }
    
}

//开始分发执行消息队里里的消息
- (void)dispatchStartUpMessageQueue {
    if (self.startupMessageQueue) {
        for (id queuedMessage in self.startupMessageQueue) {
            [self _dispatchMessage:queuedMessage];
        }
        self.startupMessageQueue = nil;
    }
}

/** 判断是否符合拦截的协议名 -write by khzliu */
-(BOOL)isCorrectProcotocolScheme:(NSURL*)url {
    if([[url scheme] isEqualToString:kCustomProtocolScheme]){
        return YES;
    } else {
        return NO;
    }
}
/** 判读是否符合拦截的域名 -write by khzliu */
-(BOOL)isCorrectHost:(NSURL*)url {
    if([[url host] isEqualToString:kQueueHasMessage]){
        return YES;
    } else {
        return NO;
    }
}

-(void)logUnkownMessage:(NSURL*)url {
    NSLog(@"WebViewJavascriptBridge: WARNING: Received unknown WebViewJavascriptBridge command %@://%@", kCustomProtocolScheme, [url path]);
}

-(NSString *)webViewJavascriptCheckCommand {
    return @"typeof WebViewJavascriptBridge == \'object\';";
}

//获取javascript中所有的消息队列
-(NSString *)webViewJavascriptFetchQueyCommand {
    return @"WebViewJavascriptBridge._fetchQueue();";
}

// Private
// -------------------------------------------

- (void) _evaluateJavascript:(NSString *)javascriptCommand {
    [self.delegate _evaluateJavascript:javascriptCommand];
}

/** 这里的消息队列只是用来首次启动的时候，javascript调用OC的消息会存到该队列
 如果有消息队列，则把消息插入到队列当中，如果没有消息队列 则直接分发执行改消息 -write by khzliu */
- (void)_queueMessage:(WVJBMessage*)message {
    if (self.startupMessageQueue) {
        [self.startupMessageQueue addObject:message];
    } else {
        [self _dispatchMessage:message];
    }
}

/** invoke 该消息 -write by khzliu */

- (void)_dispatchMessage:(WVJBMessage*)message {
    NSString *messageJSON = [self _serializeMessage:message];   //消息json序列化
    [self _log:@"SEND" json:messageJSON];   //log 消息日志
    
    /** 转义消息中的非法字符 -write by khzliu */
    messageJSON = [messageJSON stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    messageJSON = [messageJSON stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    messageJSON = [messageJSON stringByReplacingOccurrencesOfString:@"\'" withString:@"\\\'"];
    messageJSON = [messageJSON stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    messageJSON = [messageJSON stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    messageJSON = [messageJSON stringByReplacingOccurrencesOfString:@"\f" withString:@"\\f"];
    messageJSON = [messageJSON stringByReplacingOccurrencesOfString:@"\u2028" withString:@"\\u2028"];
    messageJSON = [messageJSON stringByReplacingOccurrencesOfString:@"\u2029" withString:@"\\u2029"];
    
    /** 下面这条语句非常关键，改语句执行了一个已注入的javascript对象的方法 messageJSON 则是要传递的参数 -write by khzliu */
    NSString* javascriptCommand = [NSString stringWithFormat:@"WebViewJavascriptBridge._handleMessageFromObjC('%@');", messageJSON];
    
    /** 判断当前执行环境是否为主线程，如果为主线程则直接执行 如果不是则获取主线程后再执行  -write by khzliu */
    if ([[NSThread currentThread] isMainThread]) {
        [self _evaluateJavascript:javascriptCommand];

    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self _evaluateJavascript:javascriptCommand];
        });
    }
}

/** 序列化json字符串 NSDicitonary转NSString-write by khzliu */
- (NSString *)_serializeMessage:(id)message {
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:message options:0 error:nil] encoding:NSUTF8StringEncoding];
}
/** 类型转换 json string to NSDictionray -write by khzliu */
- (NSArray*)_deserializeMessageJSON:(NSString *)messageJSON {
    return [NSJSONSerialization JSONObjectWithData:[messageJSON dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingAllowFragments error:nil];
}

/** log 日志打印 -write by khzliu */
- (void)_log:(NSString *)action json:(id)json {
    if (!logging) { return; }
    if (![json isKindOfClass:[NSString class]]) {
        json = [self _serializeMessage:json];
    }
    if ([json length] > 500) {
        NSLog(@"WVJB %@: %@ [...]", action, [json substringToIndex:500]);
    } else {
        NSLog(@"WVJB %@: %@", action, json);
    }
}

@end