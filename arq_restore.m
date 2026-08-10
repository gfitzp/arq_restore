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

#include <libgen.h>
#import <Foundation/Foundation.h>
#import "ArqRestoreCommand.h"

static void printUsage(const char *exeName) {
	fprintf(stderr, "Usage:\n");
    fprintf(stderr, "\t%s [-l loglevel] listtargets\n", exeName);
    fprintf(stderr, "\t%s [-l loglevel] addtarget <nickname> aws <access_key> [bucket_name]\n", exeName);
    fprintf(stderr, "\t\t(bucket_name is required for Arq 6 and Arq 7 backup sets)\n");
    fprintf(stderr, "\t%s [-l loglevel] addtarget <nickname> local <path>\n", exeName);
    fprintf(stderr, "\t%s [-l loglevel] deletetarget <nickname>\n", exeName);
    fprintf(stderr, "\n");
    fprintf(stderr, "\t%s [-l loglevel] listcomputers <target_nickname>\n", exeName);
    fprintf(stderr, "\t%s [-l loglevel] listfolders <target_nickname> <computer_uuid>\n", exeName);
    fprintf(stderr, "\t%s [-l loglevel] printplist <target_nickname> <computer_uuid> <folder_uuid>\n", exeName);
    fprintf(stderr, "\t%s [-l loglevel] listtree [-record id] <target_nickname> <computer_uuid> <folder_uuid> [relative_path]\n", exeName);
    fprintf(stderr, "\t%s [-l loglevel] listbackups <target_nickname> <computer_uuid> <folder_uuid>\n", exeName);
    fprintf(stderr, "\t%s [-l loglevel] restore [-record id] [-tier bulk|standard|expedited] [-days n] [-poll n] <target_nickname> <computer_uuid> <folder_uuid> [relative_path]\n", exeName);
    fprintf(stderr, "\t%s [-l loglevel] thaw [-record id] [-tier bulk|standard|expedited] [-days n] [-status] [-replan] <target_nickname> <computer_uuid> <folder_uuid> [relative_path]\n", exeName);
    fprintf(stderr, "\t%s [-l loglevel] clearcache <target_nickname>\n", exeName);
    fprintf(stderr, "\n");
    fprintf(stderr, "listbackups shows the record_id and date of every backup snapshot; pass\n");
    fprintf(stderr, "-record <record_id> to restore or thaw a specific snapshot instead of the latest.\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "restore automatically requests Glacier/Deep Archive restores of archived objects\n");
    fprintf(stderr, "(default: bulk tier, 2 days), downloads files as their objects thaw (checking\n");
    fprintf(stderr, "every -poll minutes, default 30), and keeps extending the restore window of\n");
    fprintf(stderr, "objects it still needs. It can be interrupted and re-run; files already restored\n");
    fprintf(stderr, "are skipped. thaw issues the same restore requests without downloading anything\n");
    fprintf(stderr, "(useful for pre-warming); -status samples thaw progress.\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "log levels: none, error, warn, info, and debug\n");
    fprintf(stderr, "log output: ~/Library/Logs/arq_restorer\n");
}
int main (int argc, const char **argv) {
    char *exePath = strdup(argv[0]);
    char *exeName = basename(exePath);
    int ret = 0;
    @autoreleasepool {
        ArqRestoreCommand *cmd = [[ArqRestoreCommand alloc] init];
        if (argc == 2 && !strcmp(argv[1], "-h")) {
            printUsage(exeName);
        } else {
            NSError *myError = nil;
            if (![cmd executeWithArgc:argc argv:argv error:&myError]) {
                fprintf(stderr, "%s: %s\n", exeName, [[myError localizedDescription] UTF8String]);

                if ([myError isErrorWithDomain:[cmd errorDomain] code:ERROR_USAGE]) {
                    printUsage(exeName);
                }
                ret = 1;
            }
        }
    }
    free(exePath);
    return ret;
}
