#import "CdnFetcher.h"
#import <Security/Security.h>

#define CDN_MAX_ATTEMPTS (5)
#define CDN_INITIAL_RETRY_SLEEP (1.0)
#define CDN_URL_EXPIRY_SECONDS (3600)
#define CDN_REQUEST_TIMEOUT (120)
#define CDN_RESOURCE_TIMEOUT (3600)


@interface CdnFetcher() {
    NSString *_domain;
    NSString *_keyPairId;
    NSString *_bucket;
    SecKeyRef _privateKey;
    NSURLSession *_session;
}
@end


@implementation CdnFetcher

- (NSString *)errorDomain {
    return @"CdnFetcherErrorDomain";
}

+ (NSString *)defaultConfigPath {
    const char *override = getenv("ARQ_CDN_CONFIG");
    if (override != NULL) {
        return [NSString stringWithUTF8String:override];
    }
    return [NSHomeDirectory() stringByAppendingPathComponent:@".arq_restore_cdn/cdn-config.env"];
}

- (instancetype)initWithConfigPath:(NSString *)theConfigPath error:(NSError **)error {
    if (self = [super init]) {
        NSString *contents = [NSString stringWithContentsOfFile:theConfigPath encoding:NSUTF8StringEncoding error:NULL];
        if (contents == nil) {
            SETNSERROR([self errorDomain], -1, @"unable to read CDN config %@ (run infra/setup-cloudfront-cdn.sh first)", theConfigPath);
            return nil;
        }
        NSMutableDictionary *config = [NSMutableDictionary dictionary];
        for (NSString *line in [contents componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"#"]) {
                continue;
            }
            NSRange eq = [line rangeOfString:@"="];
            if (eq.location == NSNotFound) {
                continue;
            }
            [config setObject:[line substringFromIndex:eq.location + 1] forKey:[line substringToIndex:eq.location]];
        }
        _domain = [config objectForKey:@"CDN_DOMAIN"];
        _keyPairId = [config objectForKey:@"CDN_KEY_PAIR_ID"];
        _bucket = [config objectForKey:@"CDN_BUCKET"];
        NSString *privateKeyPath = [config objectForKey:@"CDN_PRIVATE_KEY"];
        if ([_domain length] == 0 || [_keyPairId length] == 0 || [privateKeyPath length] == 0) {
            SETNSERROR([self errorDomain], -1, @"CDN config %@ is missing CDN_DOMAIN, CDN_KEY_PAIR_ID or CDN_PRIVATE_KEY", theConfigPath);
            return nil;
        }

        NSData *pemData = [NSData dataWithContentsOfFile:privateKeyPath];
        if (pemData == nil) {
            SETNSERROR([self errorDomain], -1, @"unable to read CDN private key %@", privateKeyPath);
            return nil;
        }
        SecExternalFormat format = kSecFormatUnknown;
        SecExternalItemType itemType = kSecItemTypePrivateKey;
        SecItemImportExportKeyParameters params;
        memset(&params, 0, sizeof(params));
        params.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION;
        CFArrayRef items = NULL;
        OSStatus status = SecItemImport((__bridge CFDataRef)pemData, CFSTR(".pem"), &format, &itemType, 0, &params, NULL, &items);
        if (status != errSecSuccess || items == NULL || CFArrayGetCount(items) == 0) {
            if (items != NULL) {
                CFRelease(items);
            }
            SETNSERROR([self errorDomain], -1, @"unable to load RSA private key from %@ (SecItemImport status %d)", privateKeyPath, (int)status);
            return nil;
        }
        _privateKey = (SecKeyRef)CFRetain(CFArrayGetValueAtIndex(items, 0));
        CFRelease(items);

        NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        sessionConfig.timeoutIntervalForRequest = CDN_REQUEST_TIMEOUT;
        sessionConfig.timeoutIntervalForResource = CDN_RESOURCE_TIMEOUT;
        sessionConfig.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _session = [NSURLSession sessionWithConfiguration:sessionConfig];
    }
    return self;
}

- (void)dealloc {
    if (_privateKey != NULL) {
        CFRelease(_privateKey);
    }
    [_session finishTasksAndInvalidate];
}

- (NSString *)domain {
    return _domain;
}
- (NSString *)bucket {
    return [_bucket length] > 0 ? _bucket : nil;
}

- (NSString *)signedURLStringForObjectKey:(NSString *)theKey expiresIn:(NSTimeInterval)theSeconds error:(NSError **)error {
    NSString *key = theKey;
    if ([key hasPrefix:@"/"]) {
        key = [key substringFromIndex:1];
    }
    NSString *encodedKey = [key stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *resource = [NSString stringWithFormat:@"https://%@/%@", _domain, encodedKey];
    long long expires = (long long)([[NSDate date] timeIntervalSince1970] + theSeconds);
    NSString *policy = [NSString stringWithFormat:@"{\"Statement\":[{\"Resource\":\"%@\",\"Condition\":{\"DateLessThan\":{\"AWS:EpochTime\":%lld}}}]}", resource, expires];

    CFErrorRef cfError = NULL;
    CFDataRef signature = SecKeyCreateSignature(_privateKey,
                                                kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1,
                                                (__bridge CFDataRef)[policy dataUsingEncoding:NSUTF8StringEncoding],
                                                &cfError);
    if (signature == NULL) {
        NSError *sigError = (__bridge_transfer NSError *)cfError;
        SETNSERROR([self errorDomain], -1, @"unable to sign CloudFront URL policy: %@", [sigError localizedDescription]);
        return nil;
    }
    NSString *encodedSignature = [(__bridge_transfer NSData *)signature base64EncodedStringWithOptions:0];
    // CloudFront's URL-safe base64: + -> -, = -> _, / -> ~
    encodedSignature = [encodedSignature stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    encodedSignature = [encodedSignature stringByReplacingOccurrencesOfString:@"=" withString:@"_"];
    encodedSignature = [encodedSignature stringByReplacingOccurrencesOfString:@"/" withString:@"~"];

    return [NSString stringWithFormat:@"%@?Expires=%lld&Signature=%@&Key-Pair-Id=%@", resource, expires, encodedSignature, _keyPairId];
}

- (NSData *)contentsOfRange:(NSRange)theRange ofObjectKey:(NSString *)theKey error:(NSError **)error {
    NSTimeInterval sleepTime = CDN_INITIAL_RETRY_SLEEP;
    NSError *lastError = nil;
    for (int attempt = 1; attempt <= CDN_MAX_ATTEMPTS; attempt++) {
        if (attempt > 1) {
            [NSThread sleepForTimeInterval:sleepTime];
            sleepTime *= 2;
        }
        NSError *myError = nil;
        NSString *urlString = [self signedURLStringForObjectKey:theKey expiresIn:CDN_URL_EXPIRY_SECONDS error:&myError];
        if (urlString == nil) {
            SETERRORFROMMYERROR;
            return nil;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        if (theRange.location != NSNotFound) {
            [request setValue:[NSString stringWithFormat:@"bytes=%lu-%lu",
                               (unsigned long)theRange.location,
                               (unsigned long)(theRange.location + theRange.length - 1)]
           forHTTPHeaderField:@"Range"];
        }

        __block NSData *responseData = nil;
        __block NSHTTPURLResponse *httpResponse = nil;
        __block NSError *taskError = nil;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        NSURLSessionDataTask *task = [_session dataTaskWithRequest:request
                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *theTaskError) {
            responseData = data;
            httpResponse = (NSHTTPURLResponse *)response;
            taskError = theTaskError;
            dispatch_semaphore_signal(semaphore);
        }];
        [task resume];
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

        if (taskError != nil) {
            lastError = taskError;
            HSLogDetail(@"CDN request for %@ failed (attempt %d): %@", theKey, attempt, taskError);
            continue;
        }
        NSInteger statusCode = [httpResponse statusCode];
        if (statusCode == 200 || statusCode == 206) {
            if (theRange.location != NSNotFound && statusCode == 200 && [responseData length] > theRange.length) {
                // The range was ignored and the full object returned; extract the range.
                if (theRange.location + theRange.length > [responseData length]) {
                    SETNSERROR([self errorDomain], -1, @"CDN returned %lu bytes for %@ but range %lu+%lu was requested",
                               (unsigned long)[responseData length], theKey, (unsigned long)theRange.location, (unsigned long)theRange.length);
                    return nil;
                }
                responseData = [responseData subdataWithRange:theRange];
            }
            return responseData;
        }
        NSString *bodySnippet = [[[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] substringWithRange:NSMakeRange(0, MIN((NSUInteger)200, [responseData length]))];
        if (statusCode >= 500 || statusCode == 429) {
            lastError = [[NSError alloc] initWithDomain:[self errorDomain] code:statusCode
                                            description:[NSString stringWithFormat:@"CDN HTTP %ld for %@: %@", (long)statusCode, theKey, bodySnippet]];
            HSLogDetail(@"CDN request for %@ got HTTP %ld (attempt %d)", theKey, (long)statusCode, attempt);
            continue;
        }
        // 4xx: not retryable. 403 usually means the object is still archived
        // (InvalidObjectState via OAC), the signature/key group is wrong, or the
        // WAF IP allowlist doesn't include this machine's address.
        SETNSERROR([self errorDomain], statusCode, @"CDN HTTP %ld for %@: %@", (long)statusCode, theKey, bodySnippet);
        return nil;
    }
    if (error != NULL) {
        *error = lastError;
    }
    return nil;
}
@end
