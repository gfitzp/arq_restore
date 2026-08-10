/*
 CdnFetcher — downloads S3 object data through a CloudFront distribution using
 locally-generated signed URLs (canned policy, RSA-SHA1), so bulk restore
 traffic avoids per-GB S3 egress charges. Configured from the env-format file
 written by infra/setup-cloudfront-cdn.sh:

   CDN_DOMAIN=dxxxxxxxxxxxxx.cloudfront.net
   CDN_KEY_PAIR_ID=KXXXXXXXXXXXXX
   CDN_PRIVATE_KEY=/path/to/cloudfront_private_key.pem
   CDN_BUCKET=my-backup-bucket   (optional; sanity-checked against the target)

 The private key never leaves the machine; every request gets a freshly signed
 URL, so short expiries are fine.
*/

#import <Foundation/Foundation.h>

@interface CdnFetcher : NSObject

// ~/.arq_restore_cdn/cdn-config.env, overridable with the ARQ_CDN_CONFIG env var.
+ (NSString *)defaultConfigPath;

- (instancetype)initWithConfigPath:(NSString *)theConfigPath error:(NSError **)error;

- (NSString *)domain;
- (NSString *)bucket;   // nil if the config has no CDN_BUCKET

// Signed URL for the object key (no leading slash), valid for theSeconds from now.
- (NSString *)signedURLStringForObjectKey:(NSString *)theKey expiresIn:(NSTimeInterval)theSeconds error:(NSError **)error;

// Fetches the object (or theRange of it; pass location=NSNotFound for the whole
// object) through the CDN, with retries on transient failures.
- (NSData *)contentsOfRange:(NSRange)theRange ofObjectKey:(NSString *)theKey error:(NSError **)error;
@end
