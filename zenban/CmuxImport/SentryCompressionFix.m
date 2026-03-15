#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *const ZenbanSentryErrorDomain = @"SentryErrorDomain";
static NSString *const ZenbanSentryClientName = @"sentry.cocoa";
static NSString *const ZenbanSentryRequestBuilderClassName = @"_TtC6Sentry25SentryNSURLRequestBuilder";
static NSString *const ZenbanSentrySerializationClassName = @"_TtC6Sentry24SentrySerializationSwift";

static Class ZenbanSentryResolveClass(NSString *name, NSString *mangledName)
{
    Class resolvedClass = NSClassFromString(name);
    if (resolvedClass != Nil) {
        return resolvedClass;
    }

    if (mangledName.length > 0) {
        resolvedClass = NSClassFromString(mangledName);
    }

    return resolvedClass;
}

static NSError *ZenbanSentryRequestError(NSString *description)
{
    return [NSError errorWithDomain:ZenbanSentryErrorDomain
                               code:103
                           userInfo:@{ NSLocalizedDescriptionKey : description }];
}

static NSData *_Nullable ZenbanSentryEnvelopeData(id envelope)
{
    Class serializationClass =
        ZenbanSentryResolveClass(@"SentrySerializationSwift", ZenbanSentrySerializationClassName);
    SEL selector = NSSelectorFromString(@"dataWithEnvelope:");
    if (serializationClass == Nil || ![serializationClass respondsToSelector:selector]) {
        return nil;
    }

    NSData *(*implementation)(id, SEL, id) = (NSData *(*)(id, SEL, id))[serializationClass methodForSelector:selector];
    if (implementation == NULL) {
        return nil;
    }

    return implementation(serializationClass, selector, envelope);
}

static NSURL *_Nullable ZenbanSentryEnvelopeURLFromDsn(id dsn)
{
    SEL selector = NSSelectorFromString(@"getEnvelopeEndpoint");
    if (dsn == nil || ![dsn respondsToSelector:selector]) {
        return nil;
    }

    NSURL *(*implementation)(id, SEL) = (NSURL *(*)(id, SEL))[dsn methodForSelector:selector];
    if (implementation == NULL) {
        return nil;
    }

    return implementation(dsn, selector);
}

static NSURL *_Nullable ZenbanSentryURLFromDsn(id dsn)
{
    SEL selector = NSSelectorFromString(@"url");
    if (dsn == nil || ![dsn respondsToSelector:selector]) {
        return nil;
    }

    NSURL *(*implementation)(id, SEL) = (NSURL *(*)(id, SEL))[dsn methodForSelector:selector];
    if (implementation == NULL) {
        return nil;
    }

    return implementation(dsn, selector);
}

static NSString *ZenbanSentryAuthHeader(NSURL *dsnURL)
{
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObjects:
        @"sentry_version=7",
        [NSString stringWithFormat:@"sentry_client=%@", ZenbanSentryClientName],
        [NSString stringWithFormat:@"sentry_key=%@", dsnURL.user ?: @""],
        nil
    ];

    if (dsnURL.password.length > 0) {
        [parts addObject:[NSString stringWithFormat:@"sentry_secret=%@", dsnURL.password]];
    }

    return [@"Sentry " stringByAppendingString:[parts componentsJoinedByString:@","]];
}

static NSURLRequest *_Nullable ZenbanSentryEnvelopeRequest(NSURL *url,
                                                           NSData *data,
                                                           NSString *_Nullable authHeader,
                                                           NSError **error)
{
    if (url == nil) {
        if (error != NULL) {
            *error = ZenbanSentryRequestError(@"Missing Sentry envelope URL");
        }
        return nil;
    }

    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:url
                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                            timeoutInterval:15.0];
    request.HTTPMethod = @"POST";
    request.HTTPBody = data;
    [request setValue:@"application/x-sentry-envelope" forHTTPHeaderField:@"Content-Type"];
    [request setValue:ZenbanSentryClientName forHTTPHeaderField:@"User-Agent"];
    if (authHeader.length > 0) {
        [request setValue:authHeader forHTTPHeaderField:@"X-Sentry-Auth"];
    }

    return request;
}

@interface ZenbanSentryRequestBuilderShim : NSObject
- (NSURLRequest *_Nullable)zenban_sentry_createEnvelopeRequest:(id)envelope
                                                           dsn:(id)dsn
                                                         error:(NSError *_Nullable *_Nullable)error;
- (NSURLRequest *_Nullable)zenban_sentry_createEnvelopeRequest:(id)envelope
                                                           url:(NSURL *)url
                                                         error:(NSError *_Nullable *_Nullable)error;
@end

@implementation ZenbanSentryRequestBuilderShim

- (NSURLRequest *_Nullable)zenban_sentry_createEnvelopeRequest:(id)envelope
                                                           dsn:(id)dsn
                                                         error:(NSError *_Nullable *_Nullable)error
{
    NSData *data = ZenbanSentryEnvelopeData(envelope);
    if (data == nil) {
        if (error != NULL) {
            *error = ZenbanSentryRequestError(@"Envelope cannot be converted to data");
        }
        return nil;
    }

    NSURL *envelopeURL = ZenbanSentryEnvelopeURLFromDsn(dsn);
    NSURL *dsnURL = ZenbanSentryURLFromDsn(dsn);
    NSString *authHeader = dsnURL != nil ? ZenbanSentryAuthHeader(dsnURL) : nil;
    return ZenbanSentryEnvelopeRequest(envelopeURL, data, authHeader, error);
}

- (NSURLRequest *_Nullable)zenban_sentry_createEnvelopeRequest:(id)envelope
                                                           url:(NSURL *)url
                                                         error:(NSError *_Nullable *_Nullable)error
{
    NSData *data = ZenbanSentryEnvelopeData(envelope);
    if (data == nil) {
        if (error != NULL) {
            *error = ZenbanSentryRequestError(@"Envelope cannot be converted to data");
        }
        return nil;
    }

    return ZenbanSentryEnvelopeRequest(url, data, nil, error);
}

@end

void InstallSentryCompressionFix(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class requestBuilderClass =
            ZenbanSentryResolveClass(@"SentryNSURLRequestBuilder", ZenbanSentryRequestBuilderClassName);
        if (requestBuilderClass == Nil) {
            return;
        }

        Method originalDsnMethod =
            class_getInstanceMethod(requestBuilderClass, NSSelectorFromString(@"createEnvelopeRequest:dsn:error:"));
        Method replacementDsnMethod =
            class_getInstanceMethod(ZenbanSentryRequestBuilderShim.class,
                                    @selector(zenban_sentry_createEnvelopeRequest:dsn:error:));
        if (originalDsnMethod != NULL && replacementDsnMethod != NULL) {
            method_exchangeImplementations(originalDsnMethod, replacementDsnMethod);
        }

        Method originalURLMethod =
            class_getInstanceMethod(requestBuilderClass, NSSelectorFromString(@"createEnvelopeRequest:url:error:"));
        Method replacementURLMethod =
            class_getInstanceMethod(ZenbanSentryRequestBuilderShim.class,
                                    @selector(zenban_sentry_createEnvelopeRequest:url:error:));
        if (originalURLMethod != NULL && replacementURLMethod != NULL) {
            method_exchangeImplementations(originalURLMethod, replacementURLMethod);
        }
    });
}
