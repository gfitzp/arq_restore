/*
 Arq7ThawPlanner — walks an Arq 7 backup record's trees and collects the set of
 unique target objects (pack files and standalone blobs) referenced by a restore,
 so Glacier restore ("thaw") requests can be issued before downloading.
*/

#import "TargetConnection.h"
@class Arq7KeySet;
@class Arq7BlobLoc;

@interface Arq7ThawPlanItem : NSObject
@property (readonly, strong) NSString *objectPath;       // full path relative to target root (includes pathPrefix)
@property (readonly) BOOL isPacked;
@property (readonly) unsigned long long referencedBytes; // total stored bytes referenced within this object
@property (readonly) NSUInteger referencedBlobCount;
- (instancetype)initWithObjectPath:(NSString *)theObjectPath isPacked:(BOOL)theIsPacked;
- (instancetype)initWithObjectPath:(NSString *)theObjectPath
                          isPacked:(BOOL)theIsPacked
                   referencedBytes:(unsigned long long)theReferencedBytes
               referencedBlobCount:(NSUInteger)theReferencedBlobCount;
- (void)addReferencedBytes:(unsigned long long)theBytes;
@end

@interface Arq7ThawPlanner : NSObject
- (instancetype)initWithPlanUUID:(NSString *)thePlanUUID
                      folderUUID:(NSString *)theFolderUUID
                targetConnection:(TargetConnection *)theConn
                          keySet:(Arq7KeySet *)theKeySet
                    relativePath:(NSString *)theRelativePath
                  backupRecordId:(NSString *)theBackupRecordId
                        delegate:(id <TargetConnectionDelegate>)theDelegate;

// Dictionary of objectPath -> Arq7ThawPlanItem for every object referenced by
// the restore set (data, xattr, acl and tree blobs), or nil on error.
- (NSDictionary *)planItemsByObjectPath:(NSError **)error;
@end

// Issues S3 RestoreObject requests concurrently. Reissuing for an already-restored
// object extends its restore window; an in-progress restore counts as alreadyInProgress.
@interface Arq7ThawRequester : NSObject
+ (void)requestRestoreOfObjectPaths:(NSArray *)theObjectPaths
                   targetConnection:(TargetConnection *)theConn
                               days:(NSUInteger)theDays
                               tier:(int)theTier
                          requested:(unsigned long long *)outRequested
                  alreadyInProgress:(unsigned long long *)outAlreadyInProgress
                             failed:(unsigned long long *)outFailed;
@end
