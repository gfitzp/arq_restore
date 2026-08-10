#import "Arq7ThawPlanner.h"
#import "Arq7KeySet.h"
#import "Arq7BackupRecord.h"
#import "Arq7BlobReader.h"
#import "Arq7BlobLoc.h"
#import "Arq7Node.h"
#import "Arq7Tree.h"


@implementation Arq7ThawPlanItem {
    unsigned long long _referencedBytes;
    NSUInteger _referencedBlobCount;
}
@synthesize objectPath = _objectPath;
@synthesize isPacked = _isPacked;

- (instancetype)initWithObjectPath:(NSString *)theObjectPath isPacked:(BOOL)theIsPacked {
    return [self initWithObjectPath:theObjectPath isPacked:theIsPacked referencedBytes:0 referencedBlobCount:0];
}
- (instancetype)initWithObjectPath:(NSString *)theObjectPath
                          isPacked:(BOOL)theIsPacked
                   referencedBytes:(unsigned long long)theReferencedBytes
               referencedBlobCount:(NSUInteger)theReferencedBlobCount {
    if (self = [super init]) {
        _objectPath = theObjectPath;
        _isPacked = theIsPacked;
        _referencedBytes = theReferencedBytes;
        _referencedBlobCount = theReferencedBlobCount;
    }
    return self;
}
- (unsigned long long)referencedBytes {
    return _referencedBytes;
}
- (NSUInteger)referencedBlobCount {
    return _referencedBlobCount;
}
- (void)addReferencedBytes:(unsigned long long)theBytes {
    _referencedBytes += theBytes;
    _referencedBlobCount++;
}
@end


@interface Arq7ThawPlanner() {
    NSString *_planUUID;
    NSString *_folderUUID;
    TargetConnection *_conn;
    Arq7KeySet *_keySet;
    NSString *_relativePath;
    NSString *_backupRecordId;
    id <TargetConnectionDelegate> _delegate;
    Arq7BlobReader *_blobReader;
    NSMutableDictionary *_itemsByObjectPath;
    NSUInteger _scannedNodes;
}
@end


@implementation Arq7ThawPlanner

- (instancetype)initWithPlanUUID:(NSString *)thePlanUUID
                      folderUUID:(NSString *)theFolderUUID
                targetConnection:(TargetConnection *)theConn
                          keySet:(Arq7KeySet *)theKeySet
                    relativePath:(NSString *)theRelativePath
                  backupRecordId:(NSString *)theBackupRecordId
                        delegate:(id <TargetConnectionDelegate>)theDelegate {
    if (self = [super init]) {
        _planUUID = thePlanUUID;
        _folderUUID = theFolderUUID;
        _conn = theConn;
        _keySet = theKeySet;
        _relativePath = theRelativePath;
        _backupRecordId = theBackupRecordId;
        _delegate = theDelegate;
    }
    return self;
}

- (NSString *)errorDomain {
    return @"Arq7ThawPlannerErrorDomain";
}

- (NSDictionary *)planItemsByObjectPath:(NSError **)error {
    Arq7BackupRecord *record = nil;
    if (_backupRecordId != nil) {
        record = [Arq7BackupRecord backupRecordWithId:_backupRecordId
                                          forPlanUUID:_planUUID
                                           folderUUID:_folderUUID
                                     targetConnection:_conn
                                               keySet:_keySet
                                             delegate:_delegate
                                                error:error];
        if (record != nil && !record.isComplete) {
            fprintf(stderr, "warning: backup record %s is incomplete (the backup did not finish); some files may be missing or unrestorable\n",
                    [_backupRecordId UTF8String]);
        }
    } else {
        record = [Arq7BackupRecord mostRecentBackupRecordForPlanUUID:_planUUID
                                                          folderUUID:_folderUUID
                                                    targetConnection:_conn
                                                              keySet:_keySet
                                                            delegate:_delegate
                                                               error:error];
    }
    if (record == nil) {
        return nil;
    }

    printf("planning thaw for backup from %s\n", [[record.creationDate description] UTF8String]);

    if (record.node == nil) {
        SETNSERROR([self errorDomain], -1, @"backup record has no node (version %d — Arq5-compat records not supported)", record.version);
        return nil;
    }
    if (![record.node isTree]) {
        SETNSERROR([self errorDomain], -1, @"root node is not a directory");
        return nil;
    }

    _blobReader = [[Arq7BlobReader alloc] initWithPlanUUID:_planUUID
                                          targetConnection:_conn
                                                    keySet:_keySet
                                                  delegate:_delegate];
    _itemsByObjectPath = [NSMutableDictionary dictionary];
    _scannedNodes = 0;

    [self addBlobLoc:record.node.treeBlobLoc];
    Arq7Tree *rootTree = [_blobReader treeForBlobLoc:record.node.treeBlobLoc error:error];
    if (rootTree == nil) {
        return nil;
    }

    if (_relativePath != nil) {
        NSString *path = _relativePath;
        if ([path hasPrefix:@"/"]) {
            path = [path substringFromIndex:1];
        }
        while ([path hasSuffix:@"/"]) {
            // A trailing slash (e.g. from shell tab completion) would otherwise
            // become a literal "/" path component.
            path = [path substringToIndex:[path length] - 1];
        }
        NSArray *components = [path pathComponents];
        Arq7Tree *currentTree = rootTree;
        for (NSUInteger i = 0; i < [components count]; i++) {
            NSString *component = [components objectAtIndex:i];
            Arq7Node *childNode = [currentTree childNodeWithName:component];
            if (childNode == nil) {
                SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"path component '%@' not found", component);
                return nil;
            }
            if ([childNode isTree]) {
                [self addBlobLoc:childNode.treeBlobLoc];
                currentTree = [_blobReader treeForBlobLoc:childNode.treeBlobLoc error:error];
                if (currentTree == nil) {
                    return nil;
                }
                if (i == [components count] - 1) {
                    if (![self collectTree:currentTree error:error]) {
                        return nil;
                    }
                    return _itemsByObjectPath;
                }
            } else {
                if (i < [components count] - 1) {
                    SETNSERROR([self errorDomain], -1, @"'%@' is not a directory", component);
                    return nil;
                }
                [self collectNodeBlobLocs:childNode];
                return _itemsByObjectPath;
            }
        }
    }

    if (![self collectTree:rootTree error:error]) {
        return nil;
    }
    return _itemsByObjectPath;
}


#pragma mark internal

- (BOOL)collectTree:(Arq7Tree *)theTree error:(NSError **)error {
    for (NSString *childName in [theTree childNodeNames]) {
        Arq7Node *childNode = [theTree childNodeWithName:childName];
        if ([childNode deleted]) {
            continue;
        }
        if ([childNode isTree]) {
            [self collectNodeBlobLocs:childNode];
            Arq7Tree *childTree = [_blobReader treeForBlobLoc:childNode.treeBlobLoc error:error];
            if (childTree == nil) {
                return NO;
            }
            if (![self collectTree:childTree error:error]) {
                return NO;
            }
        } else {
            [self collectNodeBlobLocs:childNode];
        }
    }
    return YES;
}

- (void)collectNodeBlobLocs:(Arq7Node *)theNode {
    if ([theNode isTree]) {
        [self addBlobLoc:[theNode treeBlobLoc]];
    } else {
        for (Arq7BlobLoc *blobLoc in [theNode dataBlobLocs]) {
            [self addBlobLoc:blobLoc];
        }
    }
    [self addBlobLoc:[theNode aclBlobLoc]];
    for (Arq7BlobLoc *blobLoc in [theNode xattrsBlobLocs]) {
        [self addBlobLoc:blobLoc];
    }

    _scannedNodes++;
    if (_scannedNodes % 10000 == 0) {
        printf("scanned %lu items; %lu unique objects so far\n",
               (unsigned long)_scannedNodes, (unsigned long)[_itemsByObjectPath count]);
    }
}

- (void)addBlobLoc:(Arq7BlobLoc *)theBlobLoc {
    if (theBlobLoc == nil || theBlobLoc.relativePath == nil) {
        return;
    }
    NSString *objectPath = [NSString stringWithFormat:@"%@%@", [_conn pathPrefix], theBlobLoc.relativePath];
    Arq7ThawPlanItem *item = [_itemsByObjectPath objectForKey:objectPath];
    if (item == nil) {
        item = [[Arq7ThawPlanItem alloc] initWithObjectPath:objectPath isPacked:theBlobLoc.isPacked];
        [_itemsByObjectPath setObject:item forKey:objectPath];
    }
    [item addReferencedBytes:theBlobLoc.length];
}
@end


@implementation Arq7ThawRequester

+ (void)requestRestoreOfObjectPaths:(NSArray *)theObjectPaths
                   targetConnection:(TargetConnection *)theConn
                               days:(NSUInteger)theDays
                               tier:(int)theTier
                          requested:(unsigned long long *)outRequested
                  alreadyInProgress:(unsigned long long *)outAlreadyInProgress
                             failed:(unsigned long long *)outFailed {
    __block unsigned long long requestedCount = 0;
    __block unsigned long long alreadyInProgressCount = 0;
    __block unsigned long long failedCount = 0;
    NSLock *statsLock = [[NSLock alloc] init];
    dispatch_apply([theObjectPaths count], dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t idx) {
        NSString *objectPath = [theObjectPaths objectAtIndex:idx];
        BOOL alreadyRestoredOrRestoring = NO;
        NSError *myError = nil;
        BOOL ok = [theConn restoreObjectAtPath:objectPath forDays:theDays tier:theTier alreadyRestoredOrRestoring:&alreadyRestoredOrRestoring delegate:nil error:&myError];
        [statsLock lock];
        if (!ok) {
            failedCount++;
            if (failedCount <= 5) {
                fprintf(stderr, "restore request failed for %s: %s\n", [objectPath UTF8String], [[myError localizedDescription] UTF8String]);
            }
        } else if (alreadyRestoredOrRestoring) {
            alreadyInProgressCount++;
        } else {
            requestedCount++;
        }
        unsigned long long done = requestedCount + alreadyInProgressCount + failedCount;
        if (done % 1000 == 0) {
            printf("issued %llu of %lu restore requests\n", done, (unsigned long)[theObjectPaths count]);
        }
        [statsLock unlock];
    });
    if (outRequested != NULL) {
        *outRequested = requestedCount;
    }
    if (outAlreadyInProgress != NULL) {
        *outAlreadyInProgress = alreadyInProgressCount;
    }
    if (outFailed != NULL) {
        *outFailed = failedCount;
    }
}
@end
