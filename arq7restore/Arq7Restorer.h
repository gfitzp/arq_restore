/*
 Arq7Restorer — orchestrates the restore of an Arq 7 backup folder to a local destination.
*/

@class Arq7KeySet;
@class TargetConnection;
@protocol TargetConnectionDelegate;

@interface Arq7Restorer : NSObject

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
                        delegate:(id <TargetConnectionDelegate>)theDelegate;

// Runs the restore synchronously, requesting Glacier/Deep Archive restores of any
// archived objects, downloading files as their objects thaw, and extending the
// restore window of still-needed objects until everything is restored.
// Resumable: files already present at their destination with the expected size
// are skipped. Returns NO on error.
- (BOOL)restore:(NSError **)error;
@end
