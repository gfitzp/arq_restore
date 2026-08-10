/*
 Copyright (c) 2009-2026, Haystack Software LLC https://www.arqbackup.com
 
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 
 * Neither the names of PhotoMinds LLC or Haystack Software, nor the names of
 their contributors may be used to endorse or promote products derived from
 this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <termios.h>
#import "ArqRestoreCommand.h"
#import "Target.h"
#import "AWSRegion.h"
#import "BackupSet.h"
#import "S3Service.h"
#import "UserAndComputer.h"
#import "Bucket.h"
#import "Repo.h"
#import "StandardRestorerParamSet.h"
#import "Tree.h"
#import "Commit.h"
#import "Node.h"
#import "BlobKey.h"
#import "StandardRestorer.h"
#import "S3GlacierRestorerParamSet.h"
#import "S3GlacierRestorer.h"
#import "GlacierRestorerParamSet.h"
#import "GlacierRestorer.h"
#import "S3AuthorizationProvider.h"
#import "S3AuthorizationProviderFactory.h"
#import "NSString_extra.h"
#import "TargetFactory.h"
#import "BackupSet.h"
#import "ExePath.h"
#import "AWSRegion.h"
#import "Arq7BackupSet.h"
#import "Arq7EncryptedObjectDecryptor.h"
#import "Arq7BackupFolder.h"
#import "Arq7KeySet.h"
#import "Arq7BackupRecord.h"
#import "Arq7BlobReader.h"
#import "Arq7Tree.h"
#import "Arq7Node.h"
#import "Arq7Restorer.h"
#import "Arq6Snapshot.h"
#import "Arq6SnapshotVolume.h"
#import "Arq6Restorer.h"
#import "Arq7ThawPlanner.h"
#import "Item.h"
#import "ByteSize.h"
#import "UserLibrary_Arq.h"
#import "TargetConnection.h"

#define BUFSIZE (65536)
#define DEFAULT_GLACIER_RESTORE_DAYS (2)
#define DEFAULT_THAW_POLL_MINUTES (30)
#define THAW_STATUS_SAMPLE_SIZE (500)

@implementation ArqRestoreCommand
- (NSString *)errorDomain {
    return @"ArqRestoreCommandErrorDomain";
}

- (BOOL)executeWithArgc:(int)argc argv:(const char **)argv error:(NSError **)error {
    NSMutableArray *args = [NSMutableArray array];
    for (int i = 0; i < argc; i++) {
        [args addObject:[[NSString alloc] initWithBytes:argv[i] length:strlen(argv[i]) encoding:NSUTF8StringEncoding]];
    }
    
    if ([args count] < 2) {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"missing arguments");
        return NO;
    }
    
    if ([args count] > 3 && [[args objectAtIndex:1] isEqualToString:@"-l"]) {
        [[HSLog sharedHSLog] setHSLogLevel:[HSLog hsLogLevelForName:[args objectAtIndex:2]]];
        args = [NSMutableArray arrayWithArray:[args subarrayWithRange:NSMakeRange(2, [args count] - 2)]];
    }
    
    NSString *cmd = [args objectAtIndex:1];
    
    if ([cmd isEqualToString:@"listtargets"]) {
        return [self listTargets:error];
    } else if ([cmd isEqualToString:@"addtarget"]) {
        return [self addTarget:args error:error];
    } else if ([cmd isEqualToString:@"deletetarget"]) {
        return [self deleteTarget:args error:error];
    } else if ([cmd isEqualToString:@"listcomputers"]) {
        return [self listComputers:args error:error];
    } else if ([cmd isEqualToString:@"listfolders"]) {
        return [self listFolders:args error:error];
    } else if ([cmd isEqualToString:@"printplist"]) {
        return [self printPlist:args error:error];
    } else if ([cmd isEqualToString:@"listtree"]) {
        return [self listTree:args error:error];
    } else if ([cmd isEqualToString:@"restore"]) {
        return [self restore:args error:error];
    } else if ([cmd isEqualToString:@"thaw"]) {
        return [self thaw:args error:error];
    } else if ([cmd isEqualToString:@"listbackups"]) {
        return [self listBackups:args error:error];
    } else if ([cmd isEqualToString:@"clearcache"]) {
        return [self clearCache:args error:error];
    } else {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"unknown command: %@", cmd);
        return NO;
    }
    
    return YES;
}

#pragma mark internal
- (BOOL)listTargets:(NSError **)error {
    printf("%-20s %s\n", "nickname:", "url:");
    for (Target *target in [[TargetFactory sharedTargetFactory] sortedTargets]) {
        printf("%-20s %s\n", [[target nickname] UTF8String], [[[target endpoint] description] UTF8String]);
    }
    return YES;
}

- (BOOL)addTarget:(NSArray *)args error:(NSError **)error {
    if ([args count] < 5) {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"missing arguments");
        return NO;
    }
    NSString *targetUUID = [NSString stringWithRandomUUID];
    NSString *targetNickname = [args objectAtIndex:2];
    NSString *targetType = [args objectAtIndex:3];
    
    NSURL *endpoint = nil;
    NSString *secret = nil;
    NSString *passphrase = nil;
    NSString *oAuth2ClientId = nil;
    NSString *oAuth2ClientSecret = nil;
    NSString *oAuth2RedirectURI = nil;
    
    if ([targetType isEqualToString:@"aws"]) {
        if ([args count] != 5) {
            SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid arguments");
            return NO;
        }
        
        NSString *accessKeyId = [args objectAtIndex:4];
        AWSRegion *usEast1 = [AWSRegion usEast1];
        NSString *urlString = [NSString stringWithFormat:@"https://%@@%@/any_bucket", accessKeyId, [[usEast1 s3EndpointWithSSL:NO] host]];
        
        endpoint = [NSURL URLWithString:urlString];
        secret = [self readPasswordWithPrompt:@"enter AWS secret key:" error:error];
        if (secret == nil) {
            return NO;
        }
        
    } else if ([targetType isEqualToString:@"local"]) {
        if ([args count] != 5) {
            SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid arguments");
            return NO;
        }
        
        endpoint = [NSURL fileURLWithPath:[args objectAtIndex:4]];
        secret = @"unused";
    } else {
        SETNSERROR([self errorDomain], -1, @"unknown target type: %@", targetType);
        return NO;
    }
    
    Target *target = [[Target alloc] initWithUUID:targetUUID nickname:targetNickname endpoint:endpoint awsRequestSignatureVersion:4];
    [target setOAuth2ClientId:oAuth2ClientId];
    [target setOAuth2RedirectURI:oAuth2RedirectURI];
    if (![[TargetFactory sharedTargetFactory] saveTarget:target error:error]) {
        return NO;
    }
    if (![target setSecret:secret trustedAppPaths:[NSArray arrayWithObject:[ExePath exePath]] error:error]) {
        return NO;
    }
    if (passphrase != nil) {
        if (![target setPassphrase:passphrase trustedAppPaths:[NSArray arrayWithObject:[ExePath exePath]] error:error]) {
            return NO;
        }
    }
    if (oAuth2ClientSecret != nil) {
        if (![target setOAuth2ClientSecret:oAuth2ClientSecret trustedAppPaths:[NSArray arrayWithObject:[ExePath exePath]] error:error]) {
            return NO;
        }
    }
    
    return YES;
}
- (BOOL)deleteTarget:(NSArray *)args error:(NSError **)error {
    if ([args count] != 3) {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid arguments");
        return NO;
    }
    Target *target = [[TargetFactory sharedTargetFactory] targetWithNickname:[args objectAtIndex:2]];
    if (target == nil) {
        SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"target not found");
        return NO;
    }
    TargetConnection *conn = [target newConnection:error];
    if (conn == nil) {
        return NO;
    }
    if (![conn clearAllCachedData:error]) {
        return NO;
    }

    return [[TargetFactory sharedTargetFactory] deleteTarget:target error:error];
}

- (BOOL)listComputers:(NSArray *)args error:(NSError **)error {
    if ([args count] != 3) {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid arguments");
        return NO;
    }
    Target *target = [[TargetFactory sharedTargetFactory] targetWithNickname:[args objectAtIndex:2]];
    if (target == nil) {
        SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"target not found");
        return NO;
    }
    NSArray *expandedTargetList = [self expandedTargetListForTarget:target error:error];
    if (expandedTargetList == nil) {
        return NO;
    }
    
    for (Target *theTarget in expandedTargetList) {
        NSError *myError = nil;
        HSLogDebug(@"getting backup sets for %@", theTarget);
        
        NSArray *backupSets = [BackupSet allBackupSetsForTarget:theTarget targetConnectionDelegate:nil activityListener:nil error:&myError];
        if (backupSets == nil) {
            if ([myError isErrorWithDomain:[S3Service errorDomain] code:S3SERVICE_ERROR_AMAZON_ERROR] && [[[myError userInfo] objectForKey:@"HTTPStatusCode"] intValue] == 403) {
                HSLogError(@"access denied getting backup sets for %@", theTarget);
            } else {
                HSLogError(@"error getting backup sets for %@: %@", theTarget, myError);
                SETERRORFROMMYERROR;
                return NO;
            }
        } else {
            // Build a set of Arq6/7 plan UUIDs so we can skip them in the Arq5 section.
            NSError *arq7Error = nil;
            TargetConnection *listConn = [theTarget newConnection:&arq7Error];
            NSArray *arq7BackupSets = [Arq7BackupSet allBackupSetsForTarget:theTarget delegate:nil error:&arq7Error];
            NSMutableSet *newFormatUUIDs = [NSMutableSet set];
            if (arq7BackupSets != nil) {
                for (Arq7BackupSet *bs in arq7BackupSets) {
                    [newFormatUUIDs addObject:[bs planUUID]];
                }
            }

            printf("target: %s\n", [[theTarget endpointDisplayName] UTF8String]);

            // Arq5 entries — skip any UUID that belongs to an Arq6/7 plan.
            for (BackupSet *backupSet in backupSets) {
                if ([newFormatUUIDs containsObject:[backupSet computerUUID]]) {
                    continue;
                }
                printf("\t[arq5] computer %s\n", [[backupSet computerUUID] UTF8String]);
                printf("\t\t%s (%s)\n", [[[backupSet userAndComputer] computerName] UTF8String], [[[backupSet userAndComputer] userName] UTF8String]);
            }

            // Arq6/7 entries.
            if (arq7BackupSets == nil) {
                HSLogError(@"error getting Arq7/Arq6 backup sets for %@: %@", theTarget, arq7Error);
            } else {
                for (Arq7BackupSet *bs in arq7BackupSets) {
                    BOOL isArq6 = (listConn != nil) && [Arq6Snapshot isArq6PlanUUID:[bs planUUID]
                                                                    targetConnection:listConn
                                                                            delegate:nil];
                    printf("\t[%s] plan %s\n", isArq6 ? "arq6" : "arq7", [[bs planUUID] UTF8String]);
                    NSString *cn = [bs computerName] ?: @"";
                    NSString *bn = [bs backupName] ?: @"";
                    printf("\t\t%s - %s%s\n", [cn UTF8String], [bn UTF8String],
                           [bs isEncrypted] ? " (encrypted)" : "");
                }
            }
        }
    }
    return YES;
}

- (BOOL)listFolders:(NSArray *)args error:(NSError **)error {
    if ([args count] != 4) {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid arguments");
        return NO;
    }
    Target *target = [[TargetFactory sharedTargetFactory] targetWithNickname:[args objectAtIndex:2]];
    if (target == nil) {
        SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"target not found");
        return NO;
    }

    NSString *theUUID = [args objectAtIndex:3];

    // Detect Arq7 by checking for backupconfig.json.
    TargetConnection *conn = [target newConnection:error];
    if (conn == nil) {
        return NO;
    }
    NSString *configPath = [NSString stringWithFormat:@"%@/%@/backupconfig.json", [conn pathPrefix], theUUID];
    NSNumber *isArq7 = [conn fileExistsAtPath:configPath dataSize:NULL delegate:nil error:error];
    if (isArq7 == nil) {
        return NO;
    }

    if ([isArq7 boolValue]) {
        Arq7BackupSet *bs = [Arq7BackupSet backupSetWithPlanUUID:theUUID targetConnection:conn delegate:nil error:error];
        if (bs == nil) {
            return NO;
        }

        Arq7KeySet *keySet = nil;
        if ([bs isEncrypted]) {
            NSString *theEncryptionPassword = [self readPasswordWithPrompt:@"enter encryption password:" error:error];
            if (theEncryptionPassword == nil) {
                return NO;
            }
            printf("\n");
            NSString *keysetPath = [NSString stringWithFormat:@"%@/%@/encryptedkeyset.dat", [conn pathPrefix], theUUID];
            NSData *keysetData = [conn contentsOfFileAtPath:keysetPath delegate:nil error:error];
            if (keysetData == nil) {
                return NO;
            }
            keySet = [[Arq7KeySet alloc] initWithEncryptedData:keysetData encryptionPassword:theEncryptionPassword error:error];
            if (keySet == nil) {
                return NO;
            }
        }

        // Arq7 path: try backupfolders first.
        NSArray *folders = [Arq7BackupFolder backupFoldersForPlanUUID:theUUID targetConnection:conn keySet:keySet delegate:nil error:error];
        if (folders != nil && [folders count] > 0) {
            printf("target   %s\n", [[target endpointDisplayName] UTF8String]);
            printf("plan     %s\n", [theUUID UTF8String]);
            for (Arq7BackupFolder *folder in folders) {
                printf("\tfolder %s\n", [[folder localPath] UTF8String]);
                printf("\t\tuuid %s\n", [[folder folderUUID] UTF8String]);
            }
            return YES;
        }

        // Arq6 path: list volumes from most recent snapshot.
        Arq6Snapshot *snapshot = [Arq6Snapshot mostRecentSnapshotForPlanUUID:theUUID
                                                             targetConnection:conn
                                                                       keySet:keySet
                                                                     delegate:nil
                                                                        error:error];
        if (snapshot == nil) {
            return NO;
        }
        printf("target   %s\n", [[target endpointDisplayName] UTF8String]);
        printf("plan     %s\n", [theUUID UTF8String]);
        for (NSString *diskIdentifier in [[snapshot.volumesByDiskIdentifier allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            Arq6SnapshotVolume *vol = [snapshot.volumesByDiskIdentifier objectForKey:diskIdentifier];
            printf("\tvolume %s\n", [[vol name] UTF8String]);
            printf("\t\tmountpoint %s\n", [[vol mountPoint] UTF8String]);
            printf("\t\tuuid %s\n", [diskIdentifier UTF8String]);
        }
        return YES;
    }

    // Arq5 path (unchanged).
    NSString *theEncryptionPassword = [self readPasswordWithPrompt:@"enter encryption password:" error:error];
    if (theEncryptionPassword == nil) {
        return NO;
    }
    printf("\n");
    BackupSet *backupSet = [self backupSetForTarget:target computerUUID:theUUID error:error];
    if (backupSet == nil) {
        return NO;
    }

    // Reset Target:
    target = [backupSet target];

    NSArray *buckets = [Bucket bucketsWithTarget:target computerUUID:theUUID encryptionPassword:theEncryptionPassword targetConnectionDelegate:nil error:error];
    if (buckets == nil) {
        return NO;
    }

    printf("target   %s\n", [[target endpointDisplayName] UTF8String]);
    printf("computer %s\n", [theUUID UTF8String]);

    for (Bucket *bucket in buckets) {
        printf("\tfolder %s\n", [[bucket localPath] UTF8String]);
        printf("\t\tuuid %s\n", [[bucket bucketUUID] UTF8String]);
    }
    return YES;
}
- (BOOL)printPlist:(NSArray *)args error:(NSError **)error {
    if ([args count] != 5) {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid arguments");
        return NO;
    }
    Target *target = [[TargetFactory sharedTargetFactory] targetWithNickname:[args objectAtIndex:2]];
    if (target == nil) {
        SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"target not found");
        return NO;
    }

    NSString *theUUID = [args objectAtIndex:3];
    NSString *theFolderUUID = [args objectAtIndex:4];

    TargetConnection *conn = [target newConnection:error];
    if (conn == nil) {
        return NO;
    }
    NSString *configPath = [NSString stringWithFormat:@"%@/%@/backupconfig.json", [conn pathPrefix], theUUID];
    NSNumber *isArq7 = [conn fileExistsAtPath:configPath dataSize:NULL delegate:nil error:error];
    if (isArq7 == nil) {
        return NO;
    }

    if ([isArq7 boolValue]) {
        Arq7BackupSet *bs = [Arq7BackupSet backupSetWithPlanUUID:theUUID targetConnection:conn delegate:nil error:error];
        if (bs == nil) {
            return NO;
        }

        Arq7KeySet *keySet = nil;
        if ([bs isEncrypted]) {
            NSString *theEncryptionPassword = [self readPasswordWithPrompt:@"enter encryption password:" error:error];
            if (theEncryptionPassword == nil) {
                return NO;
            }
            printf("\n");
            NSString *keysetPath = [NSString stringWithFormat:@"%@/%@/encryptedkeyset.dat", [conn pathPrefix], theUUID];
            NSData *keysetData = [conn contentsOfFileAtPath:keysetPath delegate:nil error:error];
            if (keysetData == nil) {
                return NO;
            }
            keySet = [[Arq7KeySet alloc] initWithEncryptedData:keysetData encryptionPassword:theEncryptionPassword error:error];
            if (keySet == nil) {
                return NO;
            }
        }

        // Arq7 path: try backupfolders first.
        NSArray *folders = [Arq7BackupFolder backupFoldersForPlanUUID:theUUID targetConnection:conn keySet:keySet delegate:nil error:error];
        if (folders != nil && [folders count] > 0) {
            Arq7BackupFolder *matchingFolder = nil;
            for (Arq7BackupFolder *folder in folders) {
                if ([[folder folderUUID] isEqualToString:theFolderUUID]) {
                    matchingFolder = folder;
                    break;
                }
            }
            if (matchingFolder == nil) {
                SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"folder %@ not found", theFolderUUID);
                return NO;
            }
            NSDictionary *json = @{
                @"uuid": matchingFolder.folderUUID ?: @"",
                @"localPath": matchingFolder.localPath ?: @"",
                @"name": matchingFolder.name ?: @"",
                @"storageClass": matchingFolder.storageClass ?: @"",
            };
            NSData *prettyData = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:error];
            if (prettyData == nil) {
                return NO;
            }
            printf("target   %s\n", [[target endpointDisplayName] UTF8String]);
            printf("plan     %s\n", [theUUID UTF8String]);
            printf("folder   %s\n", [theFolderUUID UTF8String]);
            printf("%s\n", [[NSString alloc] initWithData:prettyData encoding:NSUTF8StringEncoding].UTF8String);
            return YES;
        }

        // Arq6 path: print volume info from most recent snapshot.
        Arq6Snapshot *snapshot = [Arq6Snapshot mostRecentSnapshotForPlanUUID:theUUID
                                                             targetConnection:conn
                                                                       keySet:keySet
                                                                     delegate:nil
                                                                        error:error];
        if (snapshot == nil) {
            return NO;
        }
        Arq6SnapshotVolume *volume = [snapshot.volumesByDiskIdentifier objectForKey:theFolderUUID];
        if (volume == nil) {
            SETNSERROR([self errorDomain], ERROR_NOT_FOUND,
                       @"disk identifier %@ not found in snapshot; available: %@",
                       theFolderUUID, [[snapshot.volumesByDiskIdentifier allKeys] componentsJoinedByString:@", "]);
            return NO;
        }
        NSDictionary *info = @{
            @"diskIdentifier": volume.diskIdentifier,
            @"name": volume.name ?: @"",
            @"mountPoint": volume.mountPoint ?: @"",
            @"snapshotCreationDate": @([snapshot.creationDate timeIntervalSince1970]),
            @"planUUID": snapshot.planUUID ?: @"",
        };
        NSData *prettyData = [NSJSONSerialization dataWithJSONObject:info options:NSJSONWritingPrettyPrinted error:error];
        if (prettyData == nil) {
            return NO;
        }
        printf("target   %s\n", [[target endpointDisplayName] UTF8String]);
        printf("plan     %s\n", [theUUID UTF8String]);
        printf("volume   %s\n", [theFolderUUID UTF8String]);
        printf("%s\n", [[NSString alloc] initWithData:prettyData encoding:NSUTF8StringEncoding].UTF8String);
        return YES;
    }

    // Arq5 path.
    NSString *theEncryptionPassword = [self readPasswordWithPrompt:@"enter encryption password:" error:error];
    if (theEncryptionPassword == nil) {
        return NO;
    }
    printf("\n");

    BackupSet *backupSet = [self backupSetForTarget:target computerUUID:theUUID error:error];
    if (backupSet == nil) {
        return NO;
    }

    // Reset Target:
    target = [backupSet target];

    NSArray *buckets = [Bucket bucketsWithTarget:target computerUUID:theUUID encryptionPassword:theEncryptionPassword targetConnectionDelegate:nil error:error];
    if (buckets == nil) {
        return NO;
    }
    Bucket *matchingBucket = nil;
    for (Bucket *bucket in buckets) {
        if ([[bucket bucketUUID] isEqualToString:theFolderUUID]) {
            matchingBucket = bucket;
            break;
        }
    }
    if (matchingBucket == nil) {
        SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"folder %@ not found", theFolderUUID);
        return NO;
    }

    printf("target   %s\n", [[target endpointDisplayName] UTF8String]);
    printf("computer %s\n", [theUUID UTF8String]);
    printf("folder   %s\n", [theFolderUUID UTF8String]);

    NSData *xmlData = [matchingBucket toXMLData];
    NSString *xmlString = [[NSString alloc] initWithData:xmlData encoding:NSUTF8StringEncoding];
    printf("%s\n", [xmlString UTF8String]);
    return YES;
}
- (BOOL)listTree:(NSArray *)args error:(NSError **)error {
    NSString *backupRecordId = nil;
    args = [self argsByStrippingGlacierOptions:args tier:NULL days:NULL pollMinutes:NULL recordId:&backupRecordId replan:NULL statusOnly:NULL error:error];
    if (args == nil) {
        return NO;
    }
    if ([args count] != 5) {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid arguments");
        return NO;
    }
    Target *target = [[TargetFactory sharedTargetFactory] targetWithNickname:[args objectAtIndex:2]];
    if (target == nil) {
        SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"target not found");
        return NO;
    }

    NSString *theUUID = [args objectAtIndex:3];
    NSString *theFolderUUID = [args objectAtIndex:4];

    // Detect Arq7.
    TargetConnection *conn = [target newConnection:error];
    if (conn == nil) {
        return NO;
    }
    NSString *configPath = [NSString stringWithFormat:@"%@/%@/backupconfig.json", [conn pathPrefix], theUUID];
    NSNumber *isArq7 = [conn fileExistsAtPath:configPath dataSize:NULL delegate:nil error:error];
    if (isArq7 == nil) {
        return NO;
    }
    if (backupRecordId != nil && ![isArq7 boolValue]) {
        SETNSERROR([self errorDomain], -1, @"-record is currently supported only for Arq 7 format backup sets");
        return NO;
    }

    if ([isArq7 boolValue]) {
        Arq7BackupSet *bs = [Arq7BackupSet backupSetWithPlanUUID:theUUID targetConnection:conn delegate:nil error:error];
        if (bs == nil) {
            return NO;
        }

        Arq7KeySet *keySet = nil;
        if (![self loadArq7KeySet:&keySet forBackupSet:bs targetConnection:conn planUUID:theUUID error:error]) {
            return NO;
        }

        // Arq7 path: try backup record first.
        NSError *myError = nil;
        Arq7BackupRecord *record = nil;
        if (backupRecordId != nil) {
            record = [Arq7BackupRecord backupRecordWithId:backupRecordId
                                              forPlanUUID:theUUID
                                               folderUUID:theFolderUUID
                                         targetConnection:conn
                                                   keySet:keySet
                                                 delegate:nil
                                                    error:error];
            if (record == nil) {
                return NO;
            }
            if (!record.isComplete) {
                fprintf(stderr, "warning: backup record %s is incomplete (the backup did not finish); the listing may be missing files\n",
                        [backupRecordId UTF8String]);
            }
        } else {
            record = [Arq7BackupRecord mostRecentBackupRecordForPlanUUID:theUUID
                                                              folderUUID:theFolderUUID
                                                        targetConnection:conn
                                                                  keySet:keySet
                                                                delegate:nil
                                                                   error:&myError];
        }
        if (record != nil) {
            if (record.node == nil) {
                SETNSERROR([self errorDomain], -1, @"backup record has no node (version %d)", record.version);
                return NO;
            }

            printf("target   %s\n", [[target endpointDisplayName] UTF8String]);
            printf("plan     %s\n", [theUUID UTF8String]);
            printf("folder   %s\n", [theFolderUUID UTF8String]);
            printf("backup   %s\n", [[record.creationDate description] UTF8String]);

            Arq7BlobReader *blobReader = [[Arq7BlobReader alloc] initWithPlanUUID:theUUID
                                                                 targetConnection:conn
                                                                           keySet:keySet
                                                                         delegate:nil];
            Arq7Tree *rootTree = [blobReader treeForBlobLoc:record.node.treeBlobLoc error:error];
            if (rootTree == nil) {
                return NO;
            }
            return [self printArq7Tree:rootTree blobReader:blobReader relativePath:@"" error:error];
        }

        // Arq6 path: theFolderUUID is the diskIdentifier.
        Arq6Snapshot *snapshot = [Arq6Snapshot mostRecentSnapshotForPlanUUID:theUUID
                                                             targetConnection:conn
                                                                       keySet:keySet
                                                                     delegate:nil
                                                                        error:error];
        if (snapshot == nil) {
            return NO;
        }
        Arq6SnapshotVolume *volume = [snapshot.volumesByDiskIdentifier objectForKey:theFolderUUID];
        if (volume == nil) {
            SETNSERROR([self errorDomain], ERROR_NOT_FOUND,
                       @"disk identifier %@ not found in snapshot", theFolderUUID);
            return NO;
        }
        printf("target   %s\n", [[target endpointDisplayName] UTF8String]);
        printf("plan     %s\n", [theUUID UTF8String]);
        printf("volume   %s\n", [theFolderUUID UTF8String]);

        Arq7BlobReader *blobReader = [[Arq7BlobReader alloc] initWithPlanUUID:theUUID
                                                             targetConnection:conn
                                                                       keySet:keySet
                                                                     delegate:nil];
        Arq7Tree *rootTree = [blobReader treeForBlobLoc:volume.node.treeBlobLoc error:error];
        if (rootTree == nil) {
            return NO;
        }
        return [self printArq7Tree:rootTree blobReader:blobReader relativePath:@"" error:error];
    }

    // Arq5 path (unchanged).
    NSString *theEncryptionPassword = [self readPasswordWithPrompt:@"enter encryption password:" error:error];
    if (theEncryptionPassword == nil) {
        return NO;
    }

    BackupSet *backupSet = [self backupSetForTarget:target computerUUID:theUUID error:error];
    if (backupSet == nil) {
        return NO;
    }

    // Reset Target:
    target = [backupSet target];

    NSArray *buckets = [Bucket bucketsWithTarget:target computerUUID:theUUID encryptionPassword:theEncryptionPassword targetConnectionDelegate:nil error:error];
    if (buckets == nil) {
        return NO;
    }
    Bucket *matchingBucket = nil;
    for (Bucket *bucket in buckets) {
        if ([[bucket bucketUUID] isEqualToString:theFolderUUID]) {
            matchingBucket = bucket;
            break;
        }
    }
    if (matchingBucket == nil) {
        SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"folder %@ not found", theFolderUUID);
        return NO;
    }

    printf("target   %s\n", [[target endpointDisplayName] UTF8String]);
    printf("computer %s\n", [theUUID UTF8String]);
    printf("folder   %s\n", [theFolderUUID UTF8String]);

    Repo *repo = [[Repo alloc] initWithBucket:matchingBucket encryptionPassword:theEncryptionPassword targetConnectionDelegate:nil repoDelegate:nil activityListener:nil error:error];
    if (repo == nil) {
        return NO;
    }
    BlobKey *headBlobKey = [repo headBlobKey:error];
    if (headBlobKey == nil) {
        return NO;
    }
    Commit *head = [repo commitForBlobKey:headBlobKey error:error];
    if (head == nil) {
        return NO;
    }
    Tree *rootTree = [repo treeForBlobKey:[head treeBlobKey] error:error];
    if (rootTree == nil) {
        return NO;
    }
    return [self printTree:rootTree repo:repo relativePath:@"" error:error];
}
- (BOOL)printArq7Tree:(Arq7Tree *)theTree blobReader:(Arq7BlobReader *)theBlobReader relativePath:(NSString *)theRelativePath error:(NSError **)error {
    for (NSString *childName in [theTree childNodeNames]) {
        NSString *childRelativePath = [theRelativePath stringByAppendingFormat:@"/%@", childName];
        Arq7Node *childNode = [theTree childNodeWithName:childName];
        if ([childNode isTree]) {
            printf("%s:\n", [childRelativePath UTF8String]);
            Arq7Tree *childTree = [theBlobReader treeForBlobLoc:[childNode treeBlobLoc] error:error];
            if (childTree == nil) {
                return NO;
            }
            if (![self printArq7Tree:childTree blobReader:theBlobReader relativePath:childRelativePath error:error]) {
                return NO;
            }
        } else {
            printf("%s\n", [childRelativePath UTF8String]);
        }
    }
    return YES;
}

- (BOOL)printTree:(Tree *)theTree repo:(Repo *)theRepo relativePath:(NSString *)theRelativePath error:(NSError **)error {
    for (NSString *childName in [theTree childNodeNames]) {
        NSString *childRelativePath = [theRelativePath stringByAppendingFormat:@"/%@", childName];
        Node *childNode = [theTree childNodeWithName:childName];
        if ([childNode isTree]) {
            printf("%s:\n", [childRelativePath UTF8String]);
            Tree *childTree = [theRepo treeForBlobKey:[childNode treeBlobKey] error:error];
            if (childTree == nil) {
                return NO;
            }
            if (![self printTree:childTree
                            repo:theRepo
                    relativePath:childRelativePath
                           error:error]) {
                return NO;
            }
        } else {
            printf("%s\n", [childRelativePath UTF8String]);
        }
    }
    return YES;
}

// Strips -tier <bulk|standard|expedited>, -days <n>, -poll <minutes>, -record <id>,
// -replan and -status from theArgs, returning the remaining positional arguments.
// Pass NULL for options a command doesn't accept.
- (NSArray *)argsByStrippingGlacierOptions:(NSArray *)theArgs tier:(int *)outTier days:(NSUInteger *)outDays pollMinutes:(NSUInteger *)outPollMinutes recordId:(NSString **)outRecordId replan:(BOOL *)outReplan statusOnly:(BOOL *)outStatusOnly error:(NSError **)error {
    NSMutableArray *ret = [NSMutableArray array];
    NSUInteger i = 0;
    while (i < [theArgs count]) {
        NSString *arg = [theArgs objectAtIndex:i];
        if ([arg isEqualToString:@"-record"]) {
            if (outRecordId == NULL) {
                SETNSERROR([self errorDomain], ERROR_USAGE, @"%@ is not valid for this command", arg);
                return nil;
            }
            if (i + 1 >= [theArgs count]) {
                SETNSERROR([self errorDomain], ERROR_USAGE, @"missing value for %@", arg);
                return nil;
            }
            *outRecordId = [theArgs objectAtIndex:i + 1];
            i += 2;
        } else if ([arg isEqualToString:@"-poll"]) {
            if (outPollMinutes == NULL) {
                SETNSERROR([self errorDomain], ERROR_USAGE, @"%@ is not valid for this command", arg);
                return nil;
            }
            if (i + 1 >= [theArgs count]) {
                SETNSERROR([self errorDomain], ERROR_USAGE, @"missing value for %@", arg);
                return nil;
            }
            NSInteger minutes = [[theArgs objectAtIndex:i + 1] integerValue];
            if (minutes < 1 || minutes > 720) {
                SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid -poll value '%@' (expected 1 to 720 minutes)", [theArgs objectAtIndex:i + 1]);
                return nil;
            }
            *outPollMinutes = (NSUInteger)minutes;
            i += 2;
        } else if ([arg isEqualToString:@"-tier"] || [arg isEqualToString:@"-days"]) {
            if (([arg isEqualToString:@"-tier"] && outTier == NULL) || ([arg isEqualToString:@"-days"] && outDays == NULL)) {
                SETNSERROR([self errorDomain], ERROR_USAGE, @"%@ is not valid for this command", arg);
                return nil;
            }
            if (i + 1 >= [theArgs count]) {
                SETNSERROR([self errorDomain], ERROR_USAGE, @"missing value for %@", arg);
                return nil;
            }
            NSString *value = [theArgs objectAtIndex:i + 1];
            if ([arg isEqualToString:@"-tier"]) {
                if ([value caseInsensitiveCompare:@"bulk"] == NSOrderedSame) {
                    *outTier = GLACIER_RETRIEVAL_TIER_BULK;
                } else if ([value caseInsensitiveCompare:@"standard"] == NSOrderedSame) {
                    *outTier = GLACIER_RETRIEVAL_TIER_STANDARD;
                } else if ([value caseInsensitiveCompare:@"expedited"] == NSOrderedSame) {
                    *outTier = GLACIER_RETRIEVAL_TIER_EXPEDITED;
                } else {
                    SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid -tier value '%@' (expected bulk, standard or expedited)", value);
                    return nil;
                }
            } else {
                NSInteger days = [value integerValue];
                if (days < 1 || days > 30) {
                    SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid -days value '%@' (expected 1 to 30)", value);
                    return nil;
                }
                *outDays = (NSUInteger)days;
            }
            i += 2;
        } else if ([arg isEqualToString:@"-replan"] || [arg isEqualToString:@"-status"]) {
            BOOL *flag = [arg isEqualToString:@"-replan"] ? outReplan : outStatusOnly;
            if (flag == NULL) {
                SETNSERROR([self errorDomain], ERROR_USAGE, @"%@ is not valid for this command", arg);
                return nil;
            }
            *flag = YES;
            i++;
        } else {
            [ret addObject:arg];
            i++;
        }
    }
    return ret;
}

- (BOOL)loadArq7KeySet:(Arq7KeySet **)outKeySet forBackupSet:(Arq7BackupSet *)theBackupSet targetConnection:(TargetConnection *)theConn planUUID:(NSString *)theUUID error:(NSError **)error {
    *outKeySet = nil;
    if (![theBackupSet isEncrypted]) {
        return YES;
    }
    NSString *theEncryptionPassword = [self readPasswordWithPrompt:@"enter encryption password:" error:error];
    if (theEncryptionPassword == nil) {
        return NO;
    }
    printf("\n");
    NSString *keysetPath = [NSString stringWithFormat:@"%@/%@/encryptedkeyset.dat", [theConn pathPrefix], theUUID];
    NSData *keysetData = [theConn contentsOfFileAtPath:keysetPath delegate:nil error:error];
    if (keysetData == nil) {
        return NO;
    }
    Arq7KeySet *keySet = [[Arq7KeySet alloc] initWithEncryptedData:keysetData encryptionPassword:theEncryptionPassword error:error];
    if (keySet == nil) {
        return NO;
    }
    *outKeySet = keySet;
    return YES;
}

- (NSString *)thawPlanCachePathForPlanUUID:(NSString *)theUUID folderUUID:(NSString *)theFolderUUID relativePath:(NSString *)theRelativePath recordId:(NSString *)theRecordId {
    NSString *cacheDir = [[UserLibrary arqCachePath] stringByAppendingPathComponent:@"thawplans"];
    NSString *cacheKey = [NSString stringWithFormat:@"%@-%@", theUUID, theFolderUUID];
    if (theRecordId != nil) {
        cacheKey = [cacheKey stringByAppendingFormat:@"-r%@", [theRecordId stringByReplacingOccurrencesOfString:@"/" withString:@"_"]];
    }
    if (theRelativePath != nil) {
        cacheKey = [cacheKey stringByAppendingFormat:@"-%08lx", (unsigned long)[theRelativePath hash]];
    }
    return [[cacheDir stringByAppendingPathComponent:cacheKey] stringByAppendingPathExtension:@"thawplan"];
}

- (BOOL)writeThawPlan:(NSDictionary *)theItems toPath:(NSString *)thePath {
    NSMutableData *data = [NSMutableData data];
    [data appendData:[@"# arq_restore thawplan v1\n" dataUsingEncoding:NSUTF8StringEncoding]];
    for (NSString *objectPath in theItems) {
        Arq7ThawPlanItem *item = [theItems objectForKey:objectPath];
        NSString *line = [NSString stringWithFormat:@"%d\t%llu\t%lu\t%@\n",
                          [item isPacked] ? 1 : 0,
                          [item referencedBytes],
                          (unsigned long)[item referencedBlobCount],
                          objectPath];
        [data appendData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    }
    NSError *myError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:[thePath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:&myError]
        || ![data writeToFile:thePath options:NSDataWritingAtomic error:&myError]) {
        HSLogError(@"failed to cache thaw plan at %@: %@", thePath, myError);
        return NO;
    }
    return YES;
}

- (NSDictionary *)readThawPlanAtPath:(NSString *)thePath {
    NSString *contents = [NSString stringWithContentsOfFile:thePath encoding:NSUTF8StringEncoding error:NULL];
    if (contents == nil) {
        return nil;
    }
    NSMutableDictionary *ret = [NSMutableDictionary dictionary];
    __block BOOL corrupt = NO;
    [contents enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        if ([line length] == 0 || [line hasPrefix:@"#"]) {
            return;
        }
        NSArray *fields = [line componentsSeparatedByString:@"\t"];
        if ([fields count] != 4) {
            corrupt = YES;
            *stop = YES;
            return;
        }
        NSString *objectPath = [fields objectAtIndex:3];
        Arq7ThawPlanItem *item = [[Arq7ThawPlanItem alloc] initWithObjectPath:objectPath
                                                                     isPacked:[[fields objectAtIndex:0] intValue] != 0
                                                              referencedBytes:strtoull([[fields objectAtIndex:1] UTF8String], NULL, 10)
                                                          referencedBlobCount:(NSUInteger)[[fields objectAtIndex:2] integerValue]];
        [ret setObject:item forKey:objectPath];
    }];
    if (corrupt || [ret count] == 0) {
        return nil;
    }
    return ret;
}

- (NSDictionary *)thawPlanItemsForPlanUUID:(NSString *)theUUID folderUUID:(NSString *)theFolderUUID targetConnection:(TargetConnection *)theConn keySet:(Arq7KeySet *)theKeySet relativePath:(NSString *)theRelativePath recordId:(NSString *)theRecordId replan:(BOOL)theReplan error:(NSError **)error {
    NSString *cachePath = [self thawPlanCachePathForPlanUUID:theUUID folderUUID:theFolderUUID relativePath:theRelativePath recordId:theRecordId];
    if (!theReplan && [[NSFileManager defaultManager] fileExistsAtPath:cachePath]) {
        NSDictionary *cached = [self readThawPlanAtPath:cachePath];
        if (cached != nil) {
            printf("loaded cached thaw plan of %lu objects (use -replan to rebuild)\n", (unsigned long)[cached count]);
            return cached;
        }
        HSLogWarn(@"ignoring unreadable thaw plan cache at %@", cachePath);
    }
    Arq7ThawPlanner *planner = [[Arq7ThawPlanner alloc] initWithPlanUUID:theUUID
                                                              folderUUID:theFolderUUID
                                                        targetConnection:theConn
                                                                  keySet:theKeySet
                                                            relativePath:theRelativePath
                                                          backupRecordId:theRecordId
                                                                delegate:nil];
    NSDictionary *items = [planner planItemsByObjectPath:error];
    if (items == nil) {
        return nil;
    }
    [self writeThawPlan:items toPath:cachePath];
    return items;
}

- (BOOL)listBackups:(NSArray *)args error:(NSError **)error {
    if ([args count] != 5) {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid arguments");
        return NO;
    }
    Target *target = [[TargetFactory sharedTargetFactory] targetWithNickname:[args objectAtIndex:2]];
    if (target == nil) {
        SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"target not found");
        return NO;
    }
    NSString *theUUID = [args objectAtIndex:3];
    NSString *theFolderUUID = [args objectAtIndex:4];

    TargetConnection *conn = [target newConnection:error];
    if (conn == nil) {
        return NO;
    }
    NSString *configPath = [NSString stringWithFormat:@"%@/%@/backupconfig.json", [conn pathPrefix], theUUID];
    NSNumber *isArq7 = [conn fileExistsAtPath:configPath dataSize:NULL delegate:nil error:error];
    if (isArq7 == nil) {
        return NO;
    }
    if (![isArq7 boolValue]) {
        SETNSERROR([self errorDomain], -1, @"the listbackups command currently supports only Arq 7 format backup sets");
        return NO;
    }

    NSArray *recordPaths = [Arq7BackupRecord backupRecordPathsForPlanUUID:theUUID
                                                               folderUUID:theFolderUUID
                                                         targetConnection:conn
                                                                 delegate:nil
                                                                    error:error];
    if (recordPaths == nil) {
        return NO;
    }
    if ([recordPaths count] == 0) {
        printf("no backup records found\n");
        return YES;
    }

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss Z"];
    printf("%-14s  %s\n", "record_id", "backup date");
    for (NSString *recordPath in recordPaths) {
        NSNumber *epoch = [Arq7BackupRecord epochOfBackupRecordPath:recordPath];
        if (epoch != nil) {
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)[epoch unsignedLongLongValue]];
            printf("%-14llu  %s%s\n", [epoch unsignedLongLongValue],
                   [[formatter stringFromDate:date] UTF8String],
                   recordPath == [recordPaths lastObject] ? "  (latest)" : "");
        } else {
            printf("%-14s  %s\n", "?", [recordPath UTF8String]);
        }
    }
    printf("\nrestore a specific backup with: restore -record <record_id> ...\n");
    return YES;
}

- (BOOL)thaw:(NSArray *)args error:(NSError **)error {
    int glacierRetrievalTier = GLACIER_RETRIEVAL_TIER_BULK;
    NSUInteger glacierRestoreDays = DEFAULT_GLACIER_RESTORE_DAYS;
    BOOL replan = NO;
    BOOL statusOnly = NO;
    NSString *backupRecordId = nil;
    args = [self argsByStrippingGlacierOptions:args tier:&glacierRetrievalTier days:&glacierRestoreDays pollMinutes:NULL recordId:&backupRecordId replan:&replan statusOnly:&statusOnly error:error];
    if (args == nil) {
        return NO;
    }
    if ([args count] != 5 && [args count] != 6) {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid arguments");
        return NO;
    }
    Target *target = [[TargetFactory sharedTargetFactory] targetWithNickname:[args objectAtIndex:2]];
    if (target == nil) {
        SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"target not found");
        return NO;
    }
    NSString *theUUID = [args objectAtIndex:3];
    NSString *theFolderUUID = [args objectAtIndex:4];
    NSString *theRelativePath = ([args count] == 6) ? [args objectAtIndex:5] : nil;

    TargetConnection *conn = [target newConnection:error];
    if (conn == nil) {
        return NO;
    }
    NSString *configPath = [NSString stringWithFormat:@"%@/%@/backupconfig.json", [conn pathPrefix], theUUID];
    NSNumber *isArq7 = [conn fileExistsAtPath:configPath dataSize:NULL delegate:nil error:error];
    if (isArq7 == nil) {
        return NO;
    }
    if (![isArq7 boolValue]) {
        SETNSERROR([self errorDomain], -1, @"the thaw command currently supports only Arq 7 format backup sets");
        return NO;
    }
    Arq7BackupSet *bs = [Arq7BackupSet backupSetWithPlanUUID:theUUID targetConnection:conn delegate:nil error:error];
    if (bs == nil) {
        return NO;
    }
    Arq7KeySet *keySet = nil;
    if (![self loadArq7KeySet:&keySet forBackupSet:bs targetConnection:conn planUUID:theUUID error:error]) {
        return NO;
    }

    NSDictionary *planItems = [self thawPlanItemsForPlanUUID:theUUID folderUUID:theFolderUUID targetConnection:conn keySet:keySet relativePath:theRelativePath recordId:backupRecordId replan:replan error:error];
    if (planItems == nil) {
        return NO;
    }
    unsigned long long referencedBytes = 0;
    for (Arq7ThawPlanItem *item in [planItems allValues]) {
        referencedBytes += [item referencedBytes];
    }
    printf("%lu unique objects referenced (%s of stored data)\n",
           (unsigned long)[planItems count], [[ByteSize descriptionForSize:referencedBytes] UTF8String]);

    // Determine storage class and size of each referenced object from directory listings.
    NSMutableSet *parentDirs = [NSMutableSet set];
    for (NSString *objectPath in planItems) {
        [parentDirs addObject:[objectPath stringByDeletingLastPathComponent]];
    }
    printf("checking storage classes (listing %lu directories)\n", (unsigned long)[parentDirs count]);
    NSMutableDictionary *targetItemsByObjectPath = [NSMutableDictionary dictionary];
    for (NSString *dir in parentDirs) {
        NSError *myError = nil;
        NSDictionary *itemsByName = [conn itemsByNameAtPath:dir targetConnectionDelegate:nil error:&myError];
        if (itemsByName == nil) {
            HSLogWarn(@"unable to list %@: %@", dir, myError);
            continue;
        }
        for (NSString *name in itemsByName) {
            NSString *itemPath = [dir stringByAppendingPathComponent:name];
            if ([planItems objectForKey:itemPath] != nil) {
                [targetItemsByObjectPath setObject:[itemsByName objectForKey:name] forKey:itemPath];
            }
        }
    }

    NSMutableArray *archivedPaths = [NSMutableArray array];
    unsigned long long archivedBytes = 0;
    NSUInteger missing = 0;
    NSMutableDictionary *objectCountsByStorageClass = [NSMutableDictionary dictionary];
    for (NSString *objectPath in planItems) {
        Item *item = [targetItemsByObjectPath objectForKey:objectPath];
        if (item == nil) {
            missing++;
            if (missing <= 5) {
                fprintf(stderr, "warning: referenced object not found in target: %s\n", [objectPath UTF8String]);
            }
            continue;
        }
        NSString *storageClass = [item storageClass] != nil ? [item storageClass] : @"STANDARD";
        NSNumber *count = [objectCountsByStorageClass objectForKey:storageClass];
        [objectCountsByStorageClass setObject:[NSNumber numberWithUnsignedInteger:[count unsignedIntegerValue] + 1] forKey:storageClass];
        if ([storageClass isEqualToString:@"GLACIER"] || [storageClass isEqualToString:@"DEEP_ARCHIVE"]) {
            [archivedPaths addObject:objectPath];
            archivedBytes += [item fileSize];
        }
    }
    for (NSString *storageClass in objectCountsByStorageClass) {
        printf("  %s: %lu objects\n", [storageClass UTF8String], (unsigned long)[[objectCountsByStorageClass objectForKey:storageClass] unsignedIntegerValue]);
    }
    if (missing > 0) {
        fprintf(stderr, "warning: %lu referenced objects were not found in the target\n", (unsigned long)missing);
    }
    if ([archivedPaths count] == 0) {
        printf("no objects require thawing\n");
        return YES;
    }
    printf("%lu archived objects (%s) require thawing\n",
           (unsigned long)[archivedPaths count], [[ByteSize descriptionForSize:archivedBytes] UTF8String]);

    if (statusOnly) {
        // Sample restore status. Note: an archived object that has never had a restore
        // requested reports as restored here (no x-amz-restore header), so -status is
        // only meaningful after a request sweep has been issued.
        NSUInteger sampleStride = [archivedPaths count] / THAW_STATUS_SAMPLE_SIZE;
        if (sampleStride == 0) {
            sampleStride = 1;
        }
        NSUInteger checked = 0;
        NSUInteger restored = 0;
        for (NSUInteger i = 0; i < [archivedPaths count]; i += sampleStride) {
            NSError *myError = nil;
            NSNumber *isRestored = [conn isObjectRestoredAtPath:[archivedPaths objectAtIndex:i] delegate:nil error:&myError];
            if (isRestored == nil) {
                HSLogWarn(@"restore status check failed for %@: %@", [archivedPaths objectAtIndex:i], myError);
                continue;
            }
            checked++;
            if ([isRestored boolValue]) {
                restored++;
            }
        }
        if (checked == 0) {
            SETNSERROR([self errorDomain], -1, @"unable to check restore status of any sampled object");
            return NO;
        }
        printf("sampled %lu of %lu archived objects: %lu restored (%.0f%%)\n",
               (unsigned long)checked, (unsigned long)[archivedPaths count], (unsigned long)restored,
               100.0 * (double)restored / (double)checked);
        return YES;
    }

    NSString *tierName = glacierRetrievalTier == GLACIER_RETRIEVAL_TIER_BULK ? @"bulk"
                       : (glacierRetrievalTier == GLACIER_RETRIEVAL_TIER_STANDARD ? @"standard" : @"expedited");
    printf("requesting %s-tier restore of %lu objects for %lu days\n",
           [tierName UTF8String], (unsigned long)[archivedPaths count], (unsigned long)glacierRestoreDays);

    unsigned long long requestedCount = 0;
    unsigned long long alreadyInProgressCount = 0;
    unsigned long long failedCount = 0;
    [Arq7ThawRequester requestRestoreOfObjectPaths:archivedPaths
                                  targetConnection:conn
                                              days:glacierRestoreDays
                                              tier:glacierRetrievalTier
                                         requested:&requestedCount
                                 alreadyInProgress:&alreadyInProgressCount
                                            failed:&failedCount];

    printf("\nrequested or extended: %llu\nalready restoring: %llu\nfailed: %llu\n",
           requestedCount, alreadyInProgressCount, failedCount);
    printf("\nbulk restores from Deep Archive complete within 48 hours.\n");
    printf("check readiness with the -status flag; re-run this thaw command daily to extend\n");
    printf("the restore window of objects you still need (extensions are billed as GET requests).\n");
    if (failedCount > 0) {
        SETNSERROR([self errorDomain], -1, @"%llu restore requests failed; re-run thaw to retry", failedCount);
        return NO;
    }
    return YES;
}

- (BOOL)restore:(NSArray *)args error:(NSError **)error {
    int glacierRetrievalTier = GLACIER_RETRIEVAL_TIER_BULK;
    NSUInteger glacierRestoreDays = DEFAULT_GLACIER_RESTORE_DAYS;
    NSUInteger pollMinutes = DEFAULT_THAW_POLL_MINUTES;
    NSString *backupRecordId = nil;
    args = [self argsByStrippingGlacierOptions:args tier:&glacierRetrievalTier days:&glacierRestoreDays pollMinutes:&pollMinutes recordId:&backupRecordId replan:NULL statusOnly:NULL error:error];
    if (args == nil) {
        return NO;
    }
    if ([args count] != 5 && [args count] != 6) {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid arguments");
        return NO;
    }
    Target *target = [[TargetFactory sharedTargetFactory] targetWithNickname:[args objectAtIndex:2]];
    if (target == nil) {
        SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"target not found");
        return NO;
    }

    NSString *theUUID = [args objectAtIndex:3];
    NSString *theFolderUUID = [args objectAtIndex:4];
    NSString *theRelativePath = ([args count] == 6) ? [args objectAtIndex:5] : nil;

    // Detect Arq7.
    TargetConnection *conn = [target newConnection:error];
    if (conn == nil) {
        return NO;
    }
    NSString *configPath = [NSString stringWithFormat:@"%@/%@/backupconfig.json", [conn pathPrefix], theUUID];
    NSNumber *isArq7 = [conn fileExistsAtPath:configPath dataSize:NULL delegate:nil error:error];
    if (isArq7 == nil) {
        return NO;
    }

    if ([isArq7 boolValue]) {
        Arq7BackupSet *bs = [Arq7BackupSet backupSetWithPlanUUID:theUUID targetConnection:conn delegate:nil error:error];
        if (bs == nil) {
            return NO;
        }

        Arq7KeySet *keySet = nil;
        if (![self loadArq7KeySet:&keySet forBackupSet:bs targetConnection:conn planUUID:theUUID error:error]) {
            return NO;
        }

        // Arq7 restore path: try backupfolders first.
        NSString *folderPath = [NSString stringWithFormat:@"%@/%@/backupfolders/%@", [conn pathPrefix], theUUID, theFolderUUID];
        NSNumber *hasFolderDir = [conn fileExistsAtPath:folderPath dataSize:NULL delegate:nil error:error];
        if (hasFolderDir != nil && [hasFolderDir boolValue]) {
            NSString *restoreName = theRelativePath ? [theRelativePath lastPathComponent] : theFolderUUID;
            NSString *destinationPath = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:restoreName];
            BOOL isDirectory = NO;
            if ([[NSFileManager defaultManager] fileExistsAtPath:destinationPath isDirectory:&isDirectory]) {
                // Allow resuming a multi-day (thaw-waiting) restore into an existing directory;
                // files already present with the expected size are skipped.
                if (!isDirectory) {
                    SETNSERROR([self errorDomain], -1, @"%@ already exists", destinationPath);
                    return NO;
                }
                printf("destination exists; resuming restore into it\n");
            }

            printf("target   %s\n", [[target endpointDisplayName] UTF8String]);
            printf("plan     %s\n", [theUUID UTF8String]);
            printf("folder   %s\n", [theFolderUUID UTF8String]);
            printf("\nrestoring to %s\n\n", [destinationPath UTF8String]);

            Arq7Restorer *restorer = [[Arq7Restorer alloc] initWithPlanUUID:theUUID
                                                                 folderUUID:theFolderUUID
                                                           targetConnection:conn
                                                                     keySet:keySet
                                                               relativePath:theRelativePath
                                                            destinationPath:destinationPath
                                                             backupRecordId:backupRecordId
                                                       glacierRetrievalTier:glacierRetrievalTier
                                                         glacierRestoreDays:glacierRestoreDays
                                                                pollMinutes:pollMinutes
                                                                   delegate:nil];
            return [restorer restore:error];
        }

        // Arq6 restore path: theFolderUUID is the diskIdentifier.
        NSString *restoreName = theRelativePath ? [theRelativePath lastPathComponent]
                                                : [theFolderUUID stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        NSString *destinationPath = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:restoreName];
        if ([[NSFileManager defaultManager] fileExistsAtPath:destinationPath]) {
            SETNSERROR([self errorDomain], -1, @"%@ already exists", destinationPath);
            return NO;
        }
        printf("target   %s\n", [[target endpointDisplayName] UTF8String]);
        printf("plan     %s\n", [theUUID UTF8String]);
        printf("volume   %s\n", [theFolderUUID UTF8String]);
        printf("\nrestoring to %s\n\n", [destinationPath UTF8String]);

        Arq6Restorer *restorer = [[Arq6Restorer alloc] initWithPlanUUID:theUUID
                                                         diskIdentifier:theFolderUUID
                                                       targetConnection:conn
                                                                 keySet:keySet
                                                           relativePath:theRelativePath
                                                        destinationPath:destinationPath
                                                               delegate:nil];
        return [restorer restore:error];
    }

    // Arq5 path (unchanged).
    NSString *theComputerUUID = theUUID;
    NSString *theBucketUUID = theFolderUUID;

    NSString *theEncryptionPassword = [self readPasswordWithPrompt:@"enter encryption password:" error:error];
    if (theEncryptionPassword == nil) {
        return NO;
    }

    BackupSet *backupSet = [self backupSetForTarget:target computerUUID:theComputerUUID error:error];
    if (backupSet == nil) {
        return NO;
    }

    // Reset Target:
    target = [backupSet target];
    
    NSArray *buckets = [Bucket bucketsWithTarget:target computerUUID:theComputerUUID encryptionPassword:theEncryptionPassword targetConnectionDelegate:nil error:error];
    if (buckets == nil) {
        return NO;
    }
    Bucket *matchingBucket = nil;
    for (Bucket *bucket in buckets) {
        if ([[bucket bucketUUID] isEqualToString:theBucketUUID]) {
            matchingBucket = bucket;
            break;
        }
    }
    if (matchingBucket == nil) {
        SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"folder %@ not found", theBucketUUID);
        return NO;
    }
    
    printf("target   %s\n", [[target endpointDisplayName] UTF8String]);
    printf("computer %s\n", [theComputerUUID UTF8String]);
    printf("folder   %s\n", [theBucketUUID UTF8String]);
    
    Repo *repo = [[Repo alloc] initWithBucket:matchingBucket encryptionPassword:theEncryptionPassword targetConnectionDelegate:nil repoDelegate:nil activityListener:nil error:error];
    if (repo == nil) {
        return NO;
    }
    BlobKey *commitBlobKey = [repo headBlobKey:error];
    if (commitBlobKey == nil) {
        return NO;
    }
    Commit *commit = [repo commitForBlobKey:commitBlobKey error:error];
    if (commit == nil) {
        return NO;
    }

    BlobKey *treeBlobKey = [commit treeBlobKey];
    NSString *nodeName = nil;
    if ([args count] == 6) {
        NSString *path = [args objectAtIndex:5];
        if ([path hasPrefix:@"/"]) {
            path = [path substringFromIndex:1];
        }
        NSArray *pathComponents = [path pathComponents];
        for (NSUInteger index = 0; index < [pathComponents count]; index++) {
            NSString *component = [pathComponents objectAtIndex:index];
            Tree *childTree = [repo treeForBlobKey:treeBlobKey error:error];
            if (childTree == nil) {
                return NO;
            }
            Node *childNode = [childTree childNodeWithName:component];
            if (childNode == nil) {
                SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"path component '%@' not found", component);
                return NO;
            }
            if (![childNode isTree] && index < ([pathComponents count] - 1)) {
                // If it's a directory and we're not at the end of the path, fail.
                SETNSERROR([self errorDomain], -1, @"'%@' is not a directory", component);
                return NO;
            }
            if ([childNode isTree]) {
                treeBlobKey = [childNode treeBlobKey];
            } else {
                nodeName = component;
            }
        }
    } else {
        Tree *rootTree = [repo treeForBlobKey:[commit treeBlobKey] error:error];
        if (rootTree == nil) {
            return NO;
        }
        if ([[rootTree childNodeNames] isEqualToArray:[NSArray arrayWithObject:@"."]]) {
            // Single-file case.
            nodeName = [[commit location] lastPathComponent];
        }
    }

    NSString *restoreFileName = [args count] == 6 ? [[args objectAtIndex:5] lastPathComponent] : [[matchingBucket localPath] lastPathComponent];
    NSString *destinationPath = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:restoreFileName];
    if ([[NSFileManager defaultManager] fileExistsAtPath:destinationPath]) {
        SETNSERROR([self errorDomain], -1, @"%@ already exists", destinationPath);
        return NO;
    }
    
    
    printf("\nrestoring folder %s to %s\n\n", [[matchingBucket localPath] UTF8String], [destinationPath UTF8String]);
    
    int bytesPerSecond = 500000;
    
    AWSRegion *region = [AWSRegion regionWithS3Endpoint:[target endpoint]];
    BOOL isGlacierDestination = [region supportsGlacier];
    if ([matchingBucket storageType] == StorageTypeGlacier && isGlacierDestination) {
        GlacierRestorerParamSet *paramSet = [[GlacierRestorerParamSet alloc] initWithBucket:matchingBucket
                                                                          encryptionPassword:theEncryptionPassword
                                                                      downloadBytesPerSecond:bytesPerSecond
                                                                        glacierRetrievalTier:glacierRetrievalTier
                                                                               commitBlobKey:commitBlobKey
                                                                                rootItemName:[[matchingBucket localPath] lastPathComponent]
                                                                                 treeVersion:CURRENT_TREE_VERSION
                                                                                 treeBlobKey:treeBlobKey
                                                                                    nodeName:nodeName
                                                                                   targetUID:getuid()
                                                                                   targetGID:getgid()
                                                                          useTargetUIDAndGID:YES
                                                                             destinationPath:destinationPath
                                                                                    logLevel:[[HSLog sharedHSLog] hsLogLevel]];
        (void)[[GlacierRestorer alloc] initWithGlacierRestorerParamSet:paramSet delegate:self];
        
    } else if ([matchingBucket storageType] == StorageTypeS3Glacier && isGlacierDestination) {
        S3GlacierRestorerParamSet *paramSet = [[S3GlacierRestorerParamSet alloc] initWithBucket:matchingBucket
                                                                              encryptionPassword:theEncryptionPassword
                                                                          downloadBytesPerSecond:bytesPerSecond
                                                                            glacierRetrievalTier:glacierRetrievalTier
                                                                                   commitBlobKey:commitBlobKey
                                                                                    rootItemName:[[matchingBucket localPath] lastPathComponent]
                                                                                     treeVersion:CURRENT_TREE_VERSION
                                                                                     treeBlobKey:treeBlobKey
                                                                                        nodeName:nodeName
                                                                                       targetUID:getuid()
                                                                                       targetGID:getgid()
                                                                              useTargetUIDAndGID:YES
                                                                                 destinationPath:destinationPath
                                                                                        logLevel:[[HSLog sharedHSLog] hsLogLevel]];
        S3GlacierRestorer *restorer = [[S3GlacierRestorer alloc] initWithS3GlacierRestorerParamSet:paramSet delegate:self];
        [restorer run];
    } else {
        StandardRestorerParamSet *paramSet = [[StandardRestorerParamSet alloc] initWithBucket:matchingBucket
                                                                            encryptionPassword:theEncryptionPassword
                                                                                 commitBlobKey:commitBlobKey
                                                                                  rootItemName:[[matchingBucket localPath] lastPathComponent]
                                                                                   treeVersion:CURRENT_TREE_VERSION
                                                                                   treeBlobKey:treeBlobKey
                                                                                      nodeName:nodeName
                                                                                     targetUID:getuid()
                                                                                     targetGID:getgid()
                                                                            useTargetUIDAndGID:YES
                                                                               destinationPath:destinationPath
                                                                                      logLevel:[[HSLog sharedHSLog] hsLogLevel]];
        (void)[[StandardRestorer alloc] initWithParamSet:paramSet delegate:self];
    }
    
    return YES;
}
- (BOOL)clearCache:(NSArray *)args error:(NSError **)error {
    if ([args count] != 3) {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid arguments");
        return NO;
    }
    Target *target = [[TargetFactory sharedTargetFactory] targetWithNickname:[args objectAtIndex:2]];
    if (target == nil) {
        SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"target not found");
        return NO;
    }
    TargetConnection *conn = [target newConnection:error];
    if (conn == nil) {
        return NO;
    }
    return [conn clearAllCachedData:error];
}

- (BackupSet *)backupSetForTarget:(Target *)theInitialTarget computerUUID:(NSString *)theComputerUUID error:(NSError **)error {
    NSArray *expandedTargetList = [self expandedTargetListForTarget:theInitialTarget error:error];
    if (expandedTargetList == nil) {
        return nil;
    }
    
    for (Target *theTarget in expandedTargetList) {
        NSError *myError = nil;
        NSArray *backupSets = [BackupSet allBackupSetsForTarget:theTarget targetConnectionDelegate:nil activityListener:nil error:&myError];
        if (backupSets == nil) {
            if ([myError isErrorWithDomain:[S3Service errorDomain] code:S3SERVICE_ERROR_AMAZON_ERROR] && [[[myError userInfo] objectForKey:@"HTTPStatusCode"] intValue] == 403) {
                HSLogError(@"access denied getting backup sets for %@", theTarget);
            } else {
                HSLogError(@"error getting backup sets for %@: %@", theTarget, myError);
                SETERRORFROMMYERROR;
                return nil;
            }
        } else {
            for (BackupSet *backupSet in backupSets) {
                if ([[backupSet computerUUID] isEqualToString:theComputerUUID]) {
                    return backupSet;
                }
            }
        }
    }
    SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"backup set %@ not found at target\n", theComputerUUID);
    return nil;
}

- (NSArray *)expandedTargetListForTarget:(Target *)theTarget error:(NSError **)error {
    NSArray *targets = nil;
    
    if ([theTarget targetType] == kTargetAWS) {
        targets = [self expandedTargetsForS3Target:theTarget error:error];
    } else {
        targets = [NSArray arrayWithObject:theTarget];
    }
    return targets;
}
- (NSArray *)expandedTargetsForS3Target:(Target *)theTarget error:(NSError **)error {
    NSString *theSecretKey = [theTarget secret:error];
    if (theSecretKey == nil) {
        return nil;
    }
    S3Service *s3 = nil;
    if ([AWSRegion regionWithS3Endpoint:[theTarget endpoint]] != nil) {
        // It's S3. Get bucket name list from us-east-1 region.
        NSURL *usEast1Endpoint = [[AWSRegion usEast1] s3EndpointWithSSL:YES];
        id <S3AuthorizationProvider> sap = [[S3AuthorizationProviderFactory sharedS3AuthorizationProviderFactory] providerForEndpoint:usEast1Endpoint
                                                                                                                            accessKey:[[theTarget endpoint] user]
                                                                                                                            secretKey:theSecretKey
                                                                                                                     signatureVersion:4
                                                                                                                            awsRegion:[AWSRegion usEast1]];
        s3 = [[S3Service alloc] initWithS3AuthorizationProvider:sap endpoint:usEast1Endpoint];
    } else {
        s3 = [theTarget s3:error];
        if (s3 == nil) {
            return nil;
        }
    }
    NSArray *s3BucketNames = [s3 s3BucketNamesWithTargetConnectionDelegate:nil error:error];
    if (s3BucketNames == nil) {
        return nil;
    }
    HSLogDebug(@"s3BucketNames for %@: %@", theTarget, s3BucketNames);
    
    NSURL *originalEndpoint = [theTarget endpoint];
    NSMutableArray *ret = [NSMutableArray array];
    
    // WARNING: This is a hack! We're creating this Target using the same UUID so that the keychain lookups work!
    NSString *targetUUID = [theTarget targetUUID];
    
    for (NSString *s3BucketName in s3BucketNames) {
        NSURL *endpoint = nil;
        if ([theTarget targetType] == kTargetAWS) {
            NSError *myError = nil;
            NSString *location = [s3 locationOfS3Bucket:s3BucketName targetConnectionDelegate:nil error:&myError];
            if (location == nil) {
                HSLogError(@"failed to get location of %@: %@", s3BucketName, myError);
            } else {
                AWSRegion *awsRegion = [AWSRegion regionWithLocation:location];
                if (awsRegion == nil) {
                    SETNSERROR([self errorDomain], -1, @"unknown location: %@", location);
                    return nil;
                }
                HSLogDebug(@"awsRegion for s3BucketName %@: %@", s3BucketName, location);
                
                NSURL *s3Endpoint = [awsRegion s3EndpointWithSSL:YES];
                HSLogDebug(@"s3Endpoint: %@", s3Endpoint);
                endpoint = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@@%@/%@", [originalEndpoint user], [s3Endpoint host], s3BucketName]];
            }
        } else {
            NSNumber *originalPort = [originalEndpoint port];
            NSString *portString = (originalPort == nil) ? @"" : [NSString stringWithFormat:@":%d", [originalPort intValue]];
            endpoint = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@@%@%@/%@", [originalEndpoint scheme], [originalEndpoint user], [originalEndpoint host], portString, s3BucketName]];
        }
        
        if (endpoint != nil) {
            HSLogDebug(@"endpoint: %@", endpoint);
            
            Target *target = [[Target alloc] initWithUUID:targetUUID
                                                  nickname:s3BucketName
                                                  endpoint:endpoint
                                awsRequestSignatureVersion:[theTarget awsRequestSignatureVersion]];
            [ret addObject:target];
        }
    }
    return ret;
}

#pragma mark StandardRestorerDelegate
// Methods return YES if cancel is requested.

- (BOOL)standardRestorerMessageDidChange:(NSString *)message {
    printf("status: %s\n", [message UTF8String]);
    return NO;
}
- (BOOL)standardRestorerFileBytesRestoredDidChange:(NSNumber *)theTransferred {
    return NO;
}
- (BOOL)standardRestorerTotalFileBytesToRestoreDidChange:(NSNumber *)theTotal {
    return NO;
}
- (BOOL)standardRestorerErrorMessage:(NSString *)theErrorMessage didOccurForPath:(NSString *)thePath {
    printf("%s error: %s\n", [thePath UTF8String], [theErrorMessage UTF8String]);
    return NO;
}
- (BOOL)standardRestorerDidSucceed {
    return NO;
}
- (BOOL)standardRestorerDidFail:(NSError *)error {
    printf("failed: %s\n", [[error localizedDescription] UTF8String]);
    return NO;
}

#pragma mark S3GlacierRestorerDelegate
- (BOOL)s3GlacierRestorerMessageDidChange:(NSString *)message {
    printf("status: %s\n", [message UTF8String]);
    return NO;
}
- (BOOL)s3GlacierRestorerBytesRequestedDidChange:(NSNumber *)theRequested {
    printf("requested %qu of %qu\n", [theRequested unsignedLongLongValue], maxRequested);
    return NO;
}
- (BOOL)s3GlacierRestorerTotalBytesToRequestDidChange:(NSNumber *)theMaxRequested {
    maxRequested = [theMaxRequested unsignedLongLongValue];
    return NO;
}
- (BOOL)s3GlacierRestorerDidFinishRequesting {
    return NO;
}
- (BOOL)s3GlacierRestorerBytesTransferredDidChange:(NSNumber *)theTransferred {
    printf("restored %qu of %qu\n", [theTransferred unsignedLongLongValue], maxTransfer);
    return NO;
}
- (BOOL)s3GlacierRestorerTotalBytesToTransferDidChange:(NSNumber *)theTotal {
    maxTransfer = [theTotal unsignedLongLongValue];
    return NO;
}
- (BOOL)s3GlacierRestorerErrorMessage:(NSString *)theErrorMessage didOccurForPath:(NSString *)thePath {
    printf("%s error: %s\n", [thePath UTF8String], [theErrorMessage UTF8String]);
    return NO;
}
- (void)s3GlacierRestorerDidSucceed {
    printf("restore finished.\n");
}
- (void)s3GlacierRestorerDidFail:(NSError *)error {
    printf("failed: %s\n", [[error localizedDescription] UTF8String]);
}

#pragma mark GlacierRestorerDelegate
- (BOOL)glacierRestorerMessageDidChange:(NSString *)message {
    printf("status: %s\n", [message UTF8String]);
    return NO;
}
- (BOOL)glacierRestorerBytesRequestedDidChange:(NSNumber *)theRequested {
    return NO;
}
- (BOOL)glacierRestorerTotalBytesToRequestDidChange:(NSNumber *)theMaxRequested {
    return NO;
}
- (BOOL)glacierRestorerDidFinishRequesting {
    return NO;
}
- (BOOL)glacierRestorerBytesTransferredDidChange:(NSNumber *)theTransferred {
    return NO;
}
- (BOOL)glacierRestorerTotalBytesToTransferDidChange:(NSNumber *)theTotal {
    return NO;
}
- (BOOL)glacierRestorerErrorMessage:(NSString *)theErrorMessage didOccurForPath:(NSString *)thePath {
    printf("%s error: %s\n", [thePath UTF8String], [theErrorMessage UTF8String]);
    return NO;
}
- (BOOL)glacierRestorerDidSucceed {
    return NO;
}
- (BOOL)glacierRestorerDidFail:(NSError *)error {
    printf("failed: %s\n", [[error localizedDescription] UTF8String]);
    return NO;
}

#pragma mark internal
- (NSString *)readPasswordWithPrompt:(NSString *)thePrompt error:(NSError **)error {
    fprintf(stderr, "%s ", [thePrompt UTF8String]);
    fflush(stderr);
    
    struct termios oldTermios;
    struct termios newTermios;
    
    if (tcgetattr(STDIN_FILENO, &oldTermios) != 0) {
        int errnum = errno;
        HSLogError(@"tcgetattr error %d: %s", errnum, strerror(errnum));
        SETNSERROR(@"UnixErrorDomain", errnum, @"%s", strerror(errnum));
        return nil;
    }
    newTermios = oldTermios;
    newTermios.c_lflag &= ~(ICANON | ECHO);
    tcsetattr(STDIN_FILENO, TCSANOW, &newTermios);
    size_t bufsize = BUFSIZE;
    char *buf = malloc(bufsize);
    ssize_t len = getline(&buf, &bufsize, stdin);
    tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios);

    if (len > 0 && buf[len - 1] == '\n') {
        --len;
    }

    NSString *ret = [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
    free(buf);
    return ret;
}
@end
