#import "Arq7Restorer.h"
#import "Arq7KeySet.h"
#import "Arq7BackupRecord.h"
#import "Arq7BlobReader.h"
#import "Arq7BlobLoc.h"
#import "Arq7Node.h"
#import "Arq7Tree.h"
#import "Arq7ThawPlanner.h"
#import "S3Service.h"
#import "TargetConnection.h"
#import "FileAttributes.h"
#import "XAttrSet.h"
#import "DataInputStream.h"
#import "BufferedInputStream.h"
#import "Item.h"
#import "ByteSize.h"
#import "Spinner.h"
#include <sys/stat.h>
#include <utime.h>

// Cap on restore-status HEAD requests per polling round; objects confirmed
// restored are cached for the life of the run so the total overhead stays
// bounded at roughly one successful HEAD per archived object.
#define HEAD_BUDGET_PER_ROUND (5000)
// Reissue restore requests for still-needed objects this often so their
// restore windows never lapse mid-restore (extensions are billed as GETs).
#define EXTENSION_INTERVAL_SECONDS (12 * 3600)
#define MAX_FILE_ATTEMPTS (3)


@interface Arq7RestoreWorkItem : NSObject
@property (strong) Arq7Node *node;
@property (strong) NSString *destPath;
@property BOOL restored;
@property NSUInteger attempts;
@end
@implementation Arq7RestoreWorkItem
@end


@interface Arq7Restorer() {
    NSString *_planUUID;
    NSString *_folderUUID;
    TargetConnection *_conn;
    Arq7KeySet *_keySet;
    NSString *_relativePath;
    NSString *_destinationPath;
    NSString *_backupRecordId;
    int _glacierRetrievalTier;
    NSUInteger _glacierRestoreDays;
    NSUInteger _pollMinutes;
    id <TargetConnectionDelegate> _delegate;
    Arq7BlobReader *_blobReader;
    NSMutableArray *_fileItems;         // Arq7RestoreWorkItem, walk order
    NSMutableArray *_dirItems;          // Arq7RestoreWorkItem, parents before children
    NSSet *_archivedObjectPaths;
    NSMutableSet *_readyObjectPaths;    // archived objects confirmed restored
    NSDate *_lastExtensionDate;
    Spinner *_spinner;
    NSUInteger _collectedCount;
}
@end


@implementation Arq7Restorer

- (instancetype)initWithPlanUUID:(NSString *)thePlanUUID
                      folderUUID:(NSString *)theFolderUUID
                targetConnection:(TargetConnection *)theConn
                          keySet:(Arq7KeySet *)theKeySet
                    relativePath:(NSString *)theRelativePath
                 destinationPath:(NSString *)theDestinationPath
                  backupRecordId:(NSString *)theBackupRecordId
            glacierRetrievalTier:(int)theGlacierRetrievalTier
              glacierRestoreDays:(NSUInteger)theGlacierRestoreDays
                     pollMinutes:(NSUInteger)thePollMinutes
                        delegate:(id <TargetConnectionDelegate>)theDelegate {
    if (self = [super init]) {
        _planUUID = thePlanUUID;
        _folderUUID = theFolderUUID;
        _conn = theConn;
        _keySet = theKeySet;
        _relativePath = theRelativePath;
        _destinationPath = theDestinationPath;
        _backupRecordId = theBackupRecordId;
        _glacierRetrievalTier = theGlacierRetrievalTier;
        _glacierRestoreDays = theGlacierRestoreDays;
        _pollMinutes = thePollMinutes;
        _delegate = theDelegate;
        _spinner = [[Spinner alloc] init];
    }
    return self;
}

- (NSString *)errorDomain {
    return @"Arq7RestorerErrorDomain";
}

- (BOOL)restore:(NSError **)error {
    // Load the requested backup record, or the most recent complete one.
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
        return NO;
    }

    printf("restoring backup from %s\n", [[record.creationDate description] UTF8String]);

    _blobReader = [[Arq7BlobReader alloc] initWithPlanUUID:_planUUID
                                          targetConnection:_conn
                                                    keySet:_keySet
                                                  delegate:_delegate];

    if (record.node == nil) {
        SETNSERROR([self errorDomain], -1, @"backup record has no node (version %d — Arq5-compat records not supported in Arq7Restorer)", record.version);
        return NO;
    }

    // The root node should be a tree node.
    if (![record.node isTree]) {
        SETNSERROR([self errorDomain], -1, @"root node is not a directory");
        return NO;
    }

    // Fetch the root tree.
    Arq7Tree *rootTree = [_blobReader treeForBlobLoc:record.node.treeBlobLoc error:error];
    if (rootTree == nil) {
        return NO;
    }

    _fileItems = [NSMutableArray array];
    _dirItems = [NSMutableArray array];

    [_spinner start:@"scanning backup contents"];
    BOOL collected = [self collectWorkItemsFromRootTree:rootTree error:error];
    [_spinner stop];
    if (!collected) {
        return NO;
    }

    return [self runRestoreLoop:error];
}


#pragma mark internal

// Walks to _relativePath (if any) and gathers the file/directory work items.
- (BOOL)collectWorkItemsFromRootTree:(Arq7Tree *)rootTree error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];

    // Walk to relative path if specified.
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
        BOOL collected = NO;
        for (NSUInteger i = 0; i < [components count]; i++) {
            NSString *component = [components objectAtIndex:i];
            Arq7Node *childNode = [currentTree childNodeWithName:component];
            if (childNode == nil) {
                SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"path component '%@' not found", component);
                return NO;
            }
            if ([childNode isTree]) {
                currentTree = [_blobReader treeForBlobLoc:childNode.treeBlobLoc error:error];
                if (currentTree == nil) {
                    return NO;
                }
                if (i == [components count] - 1) {
                    // Last component is a directory — collect this subtree.
                    if (![fm createDirectoryAtPath:_destinationPath withIntermediateDirectories:YES attributes:nil error:error]) {
                        return NO;
                    }
                    if (![self collectTree:currentTree toPath:_destinationPath error:error]) {
                        return NO;
                    }
                    collected = YES;
                }
            } else {
                if (i < [components count] - 1) {
                    SETNSERROR([self errorDomain], -1, @"'%@' is not a directory", component);
                    return NO;
                }
                // Last component is a file — restore just this file.
                Arq7RestoreWorkItem *item = [[Arq7RestoreWorkItem alloc] init];
                item.node = childNode;
                item.destPath = _destinationPath;
                [_fileItems addObject:item];
                collected = YES;
            }
        }
        if (!collected) {
            SETNSERROR([self errorDomain], -1, @"unable to resolve relative path '%@'", _relativePath);
            return NO;
        }
        return YES;
    }
    if (![fm createDirectoryAtPath:_destinationPath withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    return [self collectTree:rootTree toPath:_destinationPath error:error];
}

// Creates the directory structure and gathers file/directory work items.
- (BOOL)collectTree:(Arq7Tree *)theTree toPath:(NSString *)theDestPath error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *childName in [theTree childNodeNames]) {
        Arq7Node *childNode = [theTree childNodeWithName:childName];
        if ([childNode deleted]) {
            continue;
        }
        _collectedCount++;
        if (_collectedCount % 200 == 0) {
            [_spinner setLabel:[NSString stringWithFormat:@"scanning backup contents (%lu items)", (unsigned long)_collectedCount]];
        }

        NSString *childPath = [theDestPath stringByAppendingPathComponent:childName];

        if ([childNode isTree]) {
            if (![fm createDirectoryAtPath:childPath withIntermediateDirectories:YES attributes:nil error:error]) {
                return NO;
            }
            Arq7RestoreWorkItem *dirItem = [[Arq7RestoreWorkItem alloc] init];
            dirItem.node = childNode;
            dirItem.destPath = childPath;
            [_dirItems addObject:dirItem];

            Arq7Tree *childTree = [_blobReader treeForBlobLoc:childNode.treeBlobLoc error:error];
            if (childTree == nil) {
                return NO;
            }
            if (![self collectTree:childTree toPath:childPath error:error]) {
                return NO;
            }
        } else {
            Arq7RestoreWorkItem *fileItem = [[Arq7RestoreWorkItem alloc] init];
            fileItem.node = childNode;
            fileItem.destPath = childPath;
            [_fileItems addObject:fileItem];
        }
    }
    return YES;
}

- (NSArray *)objectPathsForNode:(Arq7Node *)theNode {
    NSMutableArray *ret = [NSMutableArray array];
    for (Arq7BlobLoc *blobLoc in [theNode dataBlobLocs]) {
        [self addObjectPathForBlobLoc:blobLoc toArray:ret];
    }
    [self addObjectPathForBlobLoc:[theNode aclBlobLoc] toArray:ret];
    for (Arq7BlobLoc *blobLoc in [theNode xattrsBlobLocs]) {
        [self addObjectPathForBlobLoc:blobLoc toArray:ret];
    }
    return ret;
}

- (void)addObjectPathForBlobLoc:(Arq7BlobLoc *)theBlobLoc toArray:(NSMutableArray *)theArray {
    if (theBlobLoc == nil || theBlobLoc.relativePath == nil) {
        return;
    }
    [theArray addObject:[NSString stringWithFormat:@"%@%@", [_conn pathPrefix], theBlobLoc.relativePath]];
}

- (BOOL)runRestoreLoop:(NSError **)error {
    // Universe of objects referenced by the files to restore.
    NSMutableSet *allObjectPaths = [NSMutableSet set];
    for (Arq7RestoreWorkItem *item in _fileItems) {
        [allObjectPaths addObjectsFromArray:[self objectPathsForNode:item.node]];
    }

    // Determine which referenced objects are archived, from directory listings.
    NSMutableSet *archived = [NSMutableSet set];
    NSMutableSet *parentDirs = [NSMutableSet set];
    for (NSString *objectPath in allObjectPaths) {
        [parentDirs addObject:[objectPath stringByDeletingLastPathComponent]];
    }
    NSUInteger listedDirCount = 0;
    [_spinner start:@"checking storage classes"];
    for (NSString *dir in parentDirs) {
        listedDirCount++;
        [_spinner setLabel:[NSString stringWithFormat:@"checking storage classes (%lu of %lu directories)", (unsigned long)listedDirCount, (unsigned long)[parentDirs count]]];
        NSError *myError = nil;
        NSDictionary *itemsByName = [_conn itemsByNameAtPath:dir targetConnectionDelegate:_delegate error:&myError];
        if (itemsByName == nil) {
            HSLogWarn(@"unable to list %@: %@", dir, myError);
            continue;
        }
        for (NSString *name in itemsByName) {
            NSString *itemPath = [dir stringByAppendingPathComponent:name];
            if (![allObjectPaths containsObject:itemPath]) {
                continue;
            }
            NSString *storageClass = [[itemsByName objectForKey:name] storageClass];
            if ([storageClass isEqualToString:@"GLACIER"] || [storageClass isEqualToString:@"DEEP_ARCHIVE"]) {
                [archived addObject:itemPath];
            }
        }
    }
    [_spinner stop];
    _archivedObjectPaths = archived;
    _readyObjectPaths = [NSMutableSet set];

    printf("%lu files to restore; %lu referenced objects, %lu archived in Glacier/Deep Archive\n",
           (unsigned long)[_fileItems count], (unsigned long)[allObjectPaths count], (unsigned long)[archived count]);

    if ([archived count] > 0) {
        NSString *tierName = _glacierRetrievalTier == GLACIER_RETRIEVAL_TIER_BULK ? @"bulk"
                           : (_glacierRetrievalTier == GLACIER_RETRIEVAL_TIER_STANDARD ? @"standard" : @"expedited");
        printf("requesting %s-tier restore of %lu archived objects for %lu days\n",
               [tierName UTF8String], (unsigned long)[archived count], (unsigned long)_glacierRestoreDays);
        unsigned long long requested = 0;
        unsigned long long alreadyInProgress = 0;
        unsigned long long failed = 0;
        [Arq7ThawRequester requestRestoreOfObjectPaths:[archived allObjects]
                                      targetConnection:_conn
                                                  days:_glacierRestoreDays
                                                  tier:_glacierRetrievalTier
                                             requested:&requested
                                     alreadyInProgress:&alreadyInProgress
                                                failed:&failed];
        printf("restore requests: %llu requested or extended, %llu already restoring, %llu failed\n",
               requested, alreadyInProgress, failed);
        _lastExtensionDate = [NSDate date];
    }

    NSDate *startDate = [NSDate date];
    NSUInteger round = 0;
    while (YES) {
        round++;
        NSUInteger restoredThisRound = 0;
        NSUInteger waitingCount = 0;
        NSUInteger permanentFailures = 0;
        NSUInteger processedCount = 0;
        NSUInteger headBudget = HEAD_BUDGET_PER_ROUND;
        NSMutableSet *notReadyThisRound = [NSMutableSet set];

        [_spinner start:[NSString stringWithFormat:@"round %lu: checking files", (unsigned long)round]];
        for (Arq7RestoreWorkItem *item in _fileItems) {
            if (item.restored) {
                continue;
            }
            if (item.attempts >= MAX_FILE_ATTEMPTS) {
                permanentFailures++;
                continue;
            }
            processedCount++;
            if (processedCount % 25 == 0) {
                [_spinner setLabel:[NSString stringWithFormat:@"round %lu: %lu restored, %lu waiting on thaw (checking)",
                                    (unsigned long)round, (unsigned long)restoredThisRound, (unsigned long)waitingCount]];
            }
            @autoreleasepool {
                // Resume support: a file already present with the expected size is considered done.
                unsigned long long expectedSize = [item.node isSparse] ? [item.node sparseLogicalSize] : [item.node itemSize];
                NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:item.destPath error:NULL];
                if (attributes != nil
                    && [[attributes fileType] isEqualToString:NSFileTypeRegular]
                    && [attributes fileSize] == expectedSize) {
                    item.restored = YES;
                    restoredThisRound++;
                    [_spinner printLine:[NSString stringWithFormat:@"already restored %@", item.destPath]];
                    continue;
                }

                BOOL ready = YES;
                for (NSString *objectPath in [self objectPathsForNode:item.node]) {
                    if (![_archivedObjectPaths containsObject:objectPath] || [_readyObjectPaths containsObject:objectPath]) {
                        continue;
                    }
                    if ([notReadyThisRound containsObject:objectPath] || headBudget == 0) {
                        ready = NO;
                        break;
                    }
                    headBudget--;
                    NSError *headError = nil;
                    NSNumber *isRestored = [_conn isObjectRestoredAtPath:objectPath delegate:_delegate error:&headError];
                    if (isRestored == nil) {
                        HSLogWarn(@"restore status check failed for %@: %@", objectPath, headError);
                        [notReadyThisRound addObject:objectPath];
                        ready = NO;
                        break;
                    }
                    if ([isRestored boolValue]) {
                        [_readyObjectPaths addObject:objectPath];
                    } else {
                        [notReadyThisRound addObject:objectPath];
                        ready = NO;
                        break;
                    }
                }
                if (!ready) {
                    waitingCount++;
                    continue;
                }

                NSError *fileError = nil;
                if ([self restoreFile:item.node toPath:item.destPath error:&fileError]) {
                    item.restored = YES;
                    restoredThisRound++;
                } else {
                    item.attempts++;
                    fprintf(stderr, "error restoring %s: %s\n", [item.destPath UTF8String], [[fileError localizedDescription] UTF8String]);
                    if (item.attempts >= MAX_FILE_ATTEMPTS) {
                        fprintf(stderr, "giving up on %s after %d attempts\n", [item.destPath UTF8String], MAX_FILE_ATTEMPTS);
                        permanentFailures++;
                    } else {
                        waitingCount++;
                    }
                }
            }
        }

        [_spinner stop];
        if (waitingCount == 0) {
            if (permanentFailures > 0) {
                [self applyCollectedDirectoryMetadata];
                SETNSERROR([self errorDomain], -1, @"%lu files could not be restored", (unsigned long)permanentFailures);
                return NO;
            }
            break;
        }

        // Keep the restore window of still-needed archived objects alive.
        if (_lastExtensionDate != nil && -[_lastExtensionDate timeIntervalSinceNow] >= EXTENSION_INTERVAL_SECONDS) {
            NSMutableSet *stillNeeded = [NSMutableSet set];
            for (Arq7RestoreWorkItem *item in _fileItems) {
                if (item.restored || item.attempts >= MAX_FILE_ATTEMPTS) {
                    continue;
                }
                for (NSString *objectPath in [self objectPathsForNode:item.node]) {
                    if ([_archivedObjectPaths containsObject:objectPath]) {
                        [stillNeeded addObject:objectPath];
                    }
                }
            }
            printf("extending restore window of %lu still-needed objects\n", (unsigned long)[stillNeeded count]);
            [Arq7ThawRequester requestRestoreOfObjectPaths:[stillNeeded allObjects]
                                          targetConnection:_conn
                                                      days:_glacierRestoreDays
                                                      tier:_glacierRetrievalTier
                                                 requested:NULL
                                         alreadyInProgress:NULL
                                                    failed:NULL];
            _lastExtensionDate = [NSDate date];
        }

        printf("round %lu (%.1f hours elapsed): restored %lu files this round; %lu waiting on thaw; next check in %lu minutes\n",
               (unsigned long)round, -[startDate timeIntervalSinceNow] / 3600.0,
               (unsigned long)restoredThisRound, (unsigned long)waitingCount, (unsigned long)_pollMinutes);
        fflush(stdout);
        NSUInteger secondsRemaining = _pollMinutes * 60;
        [_spinner start:@""];
        while (secondsRemaining > 0) {
            [_spinner setLabel:[NSString stringWithFormat:@"%lu file%s waiting on thaw; next check in %lu:%02lu",
                                (unsigned long)waitingCount, waitingCount == 1 ? "" : "s",
                                (unsigned long)(secondsRemaining / 60), (unsigned long)(secondsRemaining % 60)]];
            [NSThread sleepForTimeInterval:1.0];
            secondsRemaining--;
        }
        [_spinner stop];
    }

    [self applyCollectedDirectoryMetadata];
    return YES;
}

// Applies directory metadata deepest-first so parent mtimes aren't disturbed afterward.
- (void)applyCollectedDirectoryMetadata {
    for (Arq7RestoreWorkItem *dirItem in [_dirItems reverseObjectEnumerator]) {
        NSError *myError = nil;
        if (![self applyMetadata:dirItem.node toPath:dirItem.destPath isDirectory:YES error:&myError]) {
            HSLogError(@"failed to apply metadata to %@: %@", dirItem.destPath, myError);
            // Non-fatal: continue.
        }
    }
}

- (BOOL)restoreFile:(Arq7Node *)theNode toPath:(NSString *)thePath error:(NSError **)error {
    // Assemble file data from dataBlobLocs.
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm createFileAtPath:thePath contents:nil attributes:nil]) {
        // File may already exist; open it for writing.
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:thePath];
    if (fh == nil) {
        // Try creating it.
        if (![[NSData data] writeToFile:thePath options:0 error:error]) {
            return NO;
        }
        fh = [NSFileHandle fileHandleForWritingAtPath:thePath];
    }
    if (fh == nil) {
        SETNSERROR([self errorDomain], -1, @"failed to open %@ for writing", thePath);
        return NO;
    }

    unsigned long long totalStoredBytes = 0;
    for (Arq7BlobLoc *bl in [theNode dataBlobLocs]) {
        totalStoredBytes += [bl length];
    }
    unsigned long long fetchedStoredBytes = 0;
    NSString *displayName = [thePath lastPathComponent];

    BOOL success = YES;
    if ([theNode isSparse]) {
        // Sparse file (Tree version >= 4): the data blobs contain only the non-hole
        // regions; the holes list gives the zero ranges. Seeking past written data
        // leaves zero-filled ranges, which APFS stores sparsely.
        NSArray *holes = [theNode holes];
        NSUInteger holeIndex = 0;
        unsigned long long logicalOffset = 0;
        for (Arq7BlobLoc *blobLoc in [theNode dataBlobLocs]) {
            [_spinner setLabel:[NSString stringWithFormat:@"downloading %@ (%@ of %@)", displayName,
                                [ByteSize descriptionForSize:fetchedStoredBytes], [ByteSize descriptionForSize:totalStoredBytes]]];
            NSData *blobData = [_blobReader dataForBlobLoc:blobLoc error:error];
            if (blobData == nil) {
                success = NO;
                break;
            }
            fetchedStoredBytes += [blobLoc length];
            NSUInteger dataOffset = 0;
            while (dataOffset < [blobData length]) {
                while (holeIndex < [holes count]
                       && [[[holes objectAtIndex:holeIndex] objectAtIndex:0] unsignedLongLongValue] <= logicalOffset) {
                    unsigned long long holeOffset = [[[holes objectAtIndex:holeIndex] objectAtIndex:0] unsignedLongLongValue];
                    unsigned long long holeLength = [[[holes objectAtIndex:holeIndex] objectAtIndex:1] unsignedLongLongValue];
                    if (holeOffset + holeLength > logicalOffset) {
                        logicalOffset = holeOffset + holeLength;
                    }
                    holeIndex++;
                }
                unsigned long long nextBoundary = holeIndex < [holes count]
                    ? [[[holes objectAtIndex:holeIndex] objectAtIndex:0] unsignedLongLongValue]
                    : ULLONG_MAX;
                NSUInteger writeLength = (NSUInteger)MIN((unsigned long long)([blobData length] - dataOffset), nextBoundary - logicalOffset);
                [fh seekToFileOffset:logicalOffset];
                [fh writeData:[blobData subdataWithRange:NSMakeRange(dataOffset, writeLength)]];
                logicalOffset += writeLength;
                dataOffset += writeLength;
            }
        }
        if (success) {
            [fh truncateFileAtOffset:[theNode sparseLogicalSize]];
        }
    } else {
        for (Arq7BlobLoc *blobLoc in [theNode dataBlobLocs]) {
            [_spinner setLabel:[NSString stringWithFormat:@"downloading %@ (%@ of %@)", displayName,
                                [ByteSize descriptionForSize:fetchedStoredBytes], [ByteSize descriptionForSize:totalStoredBytes]]];
            NSData *blobData = [_blobReader dataForBlobLoc:blobLoc error:error];
            if (blobData == nil) {
                success = NO;
                break;
            }
            fetchedStoredBytes += [blobLoc length];
            [fh writeData:blobData];
        }
    }
    [fh closeFile];

    if (!success) {
        return NO;
    }

    // Restore extended attributes.
    for (Arq7BlobLoc *xattrBlobLoc in [theNode xattrsBlobLocs]) {
        NSData *xattrData = [_blobReader dataForBlobLoc:xattrBlobLoc error:error];
        if (xattrData == nil) {
            HSLogError(@"failed to read xattr blob for %@", thePath);
            continue;
        }
        DataInputStream *dis = [[DataInputStream alloc] initWithData:xattrData description:@"xattrs"];
        BufferedInputStream *bis = [[BufferedInputStream alloc] initWithUnderlyingStream:dis];
        NSError *myError = nil;
        XAttrSet *xattrSet = [[XAttrSet alloc] initWithBufferedInputStream:bis error:&myError];
        if (xattrSet != nil) {
            [xattrSet applyToFile:thePath error:&myError];
        }
    }

    // Apply file metadata.
    if (![self applyMetadata:theNode toPath:thePath isDirectory:NO error:error]) {
        HSLogError(@"failed to apply metadata to %@", thePath);
        // Non-fatal.
    }

    [_spinner printLine:[NSString stringWithFormat:@"restored %@", thePath]];
    return YES;
}

- (BOOL)applyMetadata:(Arq7Node *)theNode toPath:(NSString *)thePath isDirectory:(BOOL)isDirectory error:(NSError **)error {
    // Apply Unix permissions.
    if (theNode.mac_st_mode != 0) {
        NSError *myError = nil;
        if (![FileAttributes applyMode:theNode.mac_st_mode toPath:thePath isDirectory:isDirectory error:&myError]) {
            HSLogError(@"applyMode failed for %@: %@", thePath, myError);
        }
    }

    // Apply UID/GID.
    if (theNode.mac_st_uid != 0 || theNode.mac_st_gid != 0) {
        NSError *myError = nil;
        if (![FileAttributes applyUID:theNode.mac_st_uid gid:theNode.mac_st_gid toPath:thePath error:&myError]) {
            HSLogError(@"applyUID:gid: failed for %@: %@", thePath, myError);
        }
    }

    // Apply flags.
    if (theNode.mac_st_flags != 0) {
        NSError *myError = nil;
        if (![FileAttributes applyFlags:theNode.mac_st_flags toPath:thePath error:&myError]) {
            HSLogError(@"applyFlags failed for %@: %@", thePath, myError);
        }
    }

    // Apply mtime.
    if (theNode.modificationTime_sec != 0) {
        NSError *myError = nil;
        if (![FileAttributes applyMTimeSec:theNode.modificationTime_sec
                                 mTimeNSec:theNode.modificationTime_nsec
                                    toPath:thePath
                                     error:&myError]) {
            HSLogError(@"applyMTimeSec failed for %@: %@", thePath, myError);
        }
    }

    return YES;
}
@end
