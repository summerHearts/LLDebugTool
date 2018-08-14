//
//  LLStorageManager.m
//
//  Copyright (c) 2018 LLDebugTool Software Foundation (https://github.com/HDB-Li/LLDebugTool)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

#import "LLStorageManager.h"
#import <FMDB/FMDB.h>
#import "LLNetworkModel.h"
#import "LLCrashModel.h"
#import "LLLogModel.h"
#import "NSObject+LL_Utils.h"

#import "LLTool.h"
#import "LLDebugToolMacros.h"
#import "LLLogHelperEventDefine.h"

static LLStorageManager *_instance = nil;

// Column Name
static NSString *const kObjectDataColumn = @"ObjectData";
static NSString *const kIdentityColumn = @"Identity";
static NSString *const kLaunchDateColumn = @"launchDate";
static NSString *const kDescriptionColumn = @"Desc";

@interface LLStorageManager ()

@property (strong , nonatomic) FMDatabaseQueue * dbQueue;

@property (strong , nonatomic) dispatch_queue_t queue;

@property (strong , nonatomic) NSMutableArray <Class>*registerClass;

@property (copy , nonatomic) NSString *folderPath;

@property (copy , nonatomic) NSString *screenshotFolderPath;

@end

@implementation LLStorageManager

+ (instancetype)sharedManager {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[LLStorageManager alloc] init];
        [_instance initial];
    });
    return _instance;
}

#pragma mark - Public
- (BOOL)registerClass:(Class)cls {
    if (![self isRegisteredClass:cls]) {
        __block BOOL ret = NO;
        [_dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
            NSError *error;
            ret = [db executeUpdate:[self createTableSQLFromClass:cls] values:nil error:&error];
            if (!ret) {
                [self log:[NSString stringWithFormat:@"Create %@ table failed. error = %@",NSStringFromClass(cls),error.description]];
            }
        }];
        if (ret) {
            [self.registerClass addObject:cls];
        }
        return ret;
    }
    return YES;
}

#pragma mark - SAVE
- (void)saveModel:(LLStorageModel *)model complete:(LLStorageManagerBoolBlock)complete {
    [self saveModel:model complete:complete synchronous:NO];
}

- (void)saveModel:(LLStorageModel *)model complete:(LLStorageManagerBoolBlock)complete synchronous:(BOOL)synchronous {
    __block Class cls = model.class;
    
    // Check thread.
    if (!synchronous && [[NSThread currentThread] isMainThread] && model.operationOnMainThread) {
        dispatch_async(_queue, ^{
            [self saveModel:model complete:complete];
        });
        return;
    }
    
    // Check datas.
    if (![self isRegisteredClass:cls]) {
        [self log:[NSString stringWithFormat:@"Save %@ failed, because model is unregister.",NSStringFromClass(cls)]];
        [self performBoolComplete:complete param:@(NO) synchronous:synchronous];
        return;
    }
    
    NSString *launchDate = [NSObject launchDate];
    if (launchDate.length == 0) {
        [self log:[NSString stringWithFormat:@"Save %@ failed, because launchDate is nil.",NSStringFromClass(cls)]];
        [self performBoolComplete:complete param:@(NO) synchronous:synchronous];
        return;
    }
    
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:model];
    if (data.length == 0) {
        [self log:[NSString stringWithFormat:@"Save %@ failed, because model's data is null.",NSStringFromClass(cls)]];
        [self performBoolComplete:complete param:@(NO) synchronous:synchronous];
        return;
    }
    
    NSString *identity = model.storageIdentity;
    if (identity.length == 0) {
        [self log:[NSString stringWithFormat:@"Save %@ failed, because model's identity is nil.",NSStringFromClass(cls)]];
        [self performBoolComplete:complete param:@(NO) synchronous:synchronous];
        return;
    }
    
    __block NSArray *arguments = @[data,launchDate,identity,model.description?:@"None description"];
    __block BOOL ret = NO;
    [_dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        NSError *error;
        ret = [db executeUpdate:[NSString stringWithFormat:@"INSERT INTO %@(%@,%@,%@,%@) VALUES (?,?,?,?);",[self tableNameFromClass:cls],kObjectDataColumn,kLaunchDateColumn,kIdentityColumn,kDescriptionColumn] values:arguments error:&error];
        if (!ret) {
            [self log:[NSString stringWithFormat:@"Save %@ failed, error = %@",NSStringFromClass(cls),error.localizedDescription]];
        }
    }];
    [self performBoolComplete:complete param:@(ret) synchronous:synchronous];
}

#pragma mark - GET
- (void)getModels:(Class)cls complete:(LLStorageManagerArrayBlock)complete {
    NSString *launchDate = [NSObject launchDate];
    [self getModels:cls launchDate:launchDate complete:complete];
}

- (void)getModels:(Class)cls launchDate:(NSString *)launchDate complete:(LLStorageManagerArrayBlock)complete {
    [self getModels:cls launchDate:launchDate storageIdentity:nil complete:complete];
}

- (void)getModels:(Class)cls launchDate:(NSString *)launchDate storageIdentity:(NSString *)storageIdentity complete:(LLStorageManagerArrayBlock)complete {
    [self getModels:cls launchDate:launchDate storageIdentity:storageIdentity complete:complete synchronous:NO];
}

- (void)getModels:(Class)cls launchDate:(NSString *)launchDate storageIdentity:(NSString *)storageIdentity complete:(LLStorageManagerArrayBlock)complete synchronous:(BOOL)synchronous {
    
    // Check thread.
    if (!synchronous && [[NSThread currentThread] isMainThread]) {
        dispatch_async(_queue, ^{
            [self getModels:cls launchDate:launchDate storageIdentity:storageIdentity complete:complete];
        });
        return;
    }
    
    // Check datas.
    if (![self isRegisteredClass:cls]) {
        [self log:[NSString stringWithFormat:@"Get %@ failed, because model is unregister.",NSStringFromClass(cls)]];
        [self performArrayComplete:complete param:@[] synchronous:synchronous];
        return;
    }
    
    __block NSMutableArray *modelArray = [[NSMutableArray alloc] init];
    [_dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        NSError *error;
        NSString *SQL = [NSString stringWithFormat:@"SELECT * FROM %@",[self tableNameFromClass:cls]];
        NSArray *values = @[];
        if (launchDate.length && storageIdentity.length) {
            SQL = [SQL stringByAppendingFormat:@" WHERE %@ = ? AND %@ = ?",kLaunchDateColumn,kIdentityColumn];
            values = @[launchDate,storageIdentity];
        } else if (launchDate.length) {
            SQL = [SQL stringByAppendingFormat:@" WHERE %@ = ?",kLaunchDateColumn];
            values = @[launchDate];
        } else if (storageIdentity.length) {
            SQL = [SQL stringByAppendingFormat:@" WHERE %@ = ?",kIdentityColumn];
            values = @[storageIdentity];
        }
        FMResultSet *set = [db executeQuery:SQL values:values error:&error];
        while ([set next]) {
            NSData *data = [set objectForColumn:kObjectDataColumn];
            id model = [NSKeyedUnarchiver unarchiveObjectWithData:data];
            if (model) {
                [modelArray insertObject:model atIndex:0];
            }
        }
    }];
    
    [self performArrayComplete:complete param:modelArray synchronous:synchronous];
}

#pragma mark - DELETE
- (void)removeModels:(NSArray <LLStorageModel *>*)models complete:(LLStorageManagerBoolBlock)complete {
    [self removeModels:models complete:complete synchronous:NO];
}

- (void)removeModels:(NSArray <LLStorageModel *>*)models complete:(LLStorageManagerBoolBlock)complete synchronous:(BOOL)synchronous {
    
    // Check thread.
    if (!synchronous && [[NSThread currentThread] isMainThread]) {
        dispatch_async(_queue, ^{
            [self removeModels:models complete:complete];
        });
        return;
    }
    
    // In background thread now. Check models.
    if (models.count == 0) {
        [self performBoolComplete:complete param:@(YES) synchronous:synchronous];
        return;
    }
    
    // Check datas.
    __block Class cls = [models.firstObject class];
    if (![self isRegisteredClass:cls]) {
        NSLog(@"Remove model failed, because model is unregister.");
        [self performBoolComplete:complete param:@(NO) synchronous:synchronous];
        return;
    }
    
    __block NSMutableSet *identities = [NSMutableSet set];
    for (LLStorageModel *model in models) {
        if (![model.class isEqual:cls]) {
            [self log:@"Remove %@ failed, because models in array isn't some class."];
            [self performBoolComplete:complete param:@(NO) synchronous:synchronous];
            return;
        }
        [identities addObject:model.storageIdentity];
    }
    
    // Perform database operations.
    __block BOOL ret = NO;

    [_dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        NSError *error;
        NSString *tableName = [self tableNameFromClass:cls];
        ret = [db executeUpdate:[NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ NOT IN %@;",tableName,kIdentityColumn,identities.allObjects] values:nil error:&error];
        if (!ret) {
            [self log:[NSString stringWithFormat:@"Remove %@ failed, error = %@",NSStringFromClass(cls),error]];
        }
    }];
    
    [self performBoolComplete:complete param:@(ret) synchronous:synchronous];
}

#pragma mark - Screenshot
- (void)saveScreenshot:(UIImage *)image name:(NSString *)name complete:(LLStorageManagerBoolBlock)complete {
    if ([[NSThread currentThread] isMainThread]) {
        dispatch_async(_queue, ^{
            [self saveScreenshot:image name:name complete:complete];
        });
        return;
    }
    if (name.length == 0) {
        name = [LLTool staticStringFromDate:[NSDate date]];
    }
    name = [name stringByAppendingPathExtension:@"png"];
    NSString *path = [self.screenshotFolderPath stringByAppendingPathComponent:name];
    BOOL ret = [UIImagePNGRepresentation(image) writeToFile:path atomically:YES];
    [self performBoolComplete:complete param:@(ret) synchronous:NO];
}



#pragma mark - Primary
/**
 Initialize something
 */
- (void)initial {
    BOOL result = [self initDatabase];
    if (!result) {
        [self log:@"Init Database fail"];
    }
    [self reloadLogModelTable];
}

/**
 Init database.
 */
- (BOOL)initDatabase {
    self.queue = dispatch_queue_create("LLDebugTool.LLStorageManager", DISPATCH_QUEUE_CONCURRENT);
    self.registerClass = [[NSMutableArray alloc] init];
    
    self.folderPath = [LLConfig sharedConfig].folderPath;
    [LLTool createDirectoryAtPath:self.folderPath];
    
    self.screenshotFolderPath = [self.folderPath stringByAppendingPathComponent:@"Screenshot"];
    [LLTool createDirectoryAtPath:self.screenshotFolderPath];
    
    NSString *filePath = [self.folderPath stringByAppendingPathComponent:@"LLDebugTool.db"];
    
    _dbQueue = [FMDatabaseQueue databaseQueueWithPath:filePath];
    
    BOOL ret1 = [self registerClass:[LLCrashModel class]];
    BOOL ret2 = [self registerClass:[LLNetworkModel class]];
    BOOL ret3 = [self registerClass:[LLLogModel class]];
    return ret1 && ret2 && ret3;
}

/**
 * Remove unused log models and networks models.
 */
- (void)reloadLogModelTable {
    // Need to remove logs in a global queue.
    if ([[NSThread currentThread] isMainThread]) {
        dispatch_async(_queue, ^{
            [self reloadLogModelTable];
        });
        return;
    }
    NSArray *crashModels = [self getAllCrashModel];
    NSMutableArray *launchDates = [[NSMutableArray alloc] init];
    for (LLCrashModel *model in crashModels) {
        if (model.launchDate.length) {
            [launchDates addObject:model.launchDate];
        }
    }
    [self removeLogModelAndNetworkModelNotIn:launchDates];
    
}

- (BOOL)removeLogModelAndNetworkModelNotIn:(NSArray *)launchDates {
    __block BOOL ret = NO;
    __block BOOL ret2 = NO;
    [_dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        NSError *error;
        NSString *logTableName = [self tableNameFromClass:[LLLogModel class]];
        ret = [db executeUpdate:[NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ NOT IN %@;",logTableName,kLaunchDateColumn,launchDates] values:nil error:&error];
        if (!ret) {
            [self log:[NSString stringWithFormat:@"Remove launch log fail, error = %@",error]];
        }
        
        NSString *networkTableName = [self tableNameFromClass:[LLNetworkModel class]];
        ret2 = [db executeUpdate:[NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ NOT IN %@;",networkTableName,kLaunchDateColumn,launchDates] values:nil error:&error];
        if (!ret2) {
            [self log:[NSString stringWithFormat:@"Remove launch network fail, error = %@",error]];
        }
    }];
    return ret && ret2;
}

- (BOOL)isRegisteredClass:(Class)cls {
    return [self.registerClass containsObject:cls];
}

- (NSString *)tableNameFromClass:(Class)cls {
    return [NSString stringWithFormat:@"%@Table",NSStringFromClass(cls)];
}

- (NSString *)createTableSQLFromClass:(Class)cls {
    return [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@(%@ BLOB NOT NULL,%@ TEXT NOT NULL,%@ TEXT NOT NULL,%@ TEXT NOT NULL);",[self tableNameFromClass:cls],kObjectDataColumn,kIdentityColumn,kLaunchDateColumn,kDescriptionColumn];
}

- (void)performBoolComplete:(LLStorageManagerBoolBlock)complete param:(NSNumber *)param synchronous:(BOOL)synchronous {
    if (complete) {
        if (synchronous || [[NSThread currentThread] isMainThread]) {
            complete(param.boolValue);
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self performBoolComplete:complete param:param synchronous:synchronous];
            });
        }
    }
}

- (void)performArrayComplete:(LLStorageManagerArrayBlock)complete param:(NSArray *)param synchronous:(BOOL)synchronous {
    if (complete) {
        if (synchronous || [[NSThread currentThread] isMainThread]) {
            complete(param);
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self performArrayComplete:complete param:param synchronous:synchronous];
            });
        }
    }
}

- (void)log:(NSString *)message {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        LLog_Alert_Event(kLLLogHelperDebugToolEvent, message);
    });
}

#pragma mark - DEPRECATED
- (BOOL)saveCrashModel:(LLCrashModel *)model {
    __block BOOL ret = YES;
    [self saveModel:model complete:^(BOOL result) {
        ret = result;
    } synchronous:YES];
    return ret;
}

- (NSArray <LLCrashModel *>*)getAllCrashModel {
    __block NSArray *datas = @[];
    [self getModels:[LLCrashModel class] launchDate:nil storageIdentity:nil complete:^(NSArray<LLStorageModel *> *result) {
        datas = result;
    } synchronous:YES];
    return datas;
}

- (BOOL)removeCrashModels:(NSArray <LLCrashModel *>*)models {
    __block BOOL ret = YES;
    [self removeModels:models complete:^(BOOL result) {
        ret = result;
    } synchronous:YES];
    return ret;
}

- (BOOL)saveNetworkModel:(LLNetworkModel *)model {
    __block BOOL ret = YES;
    [self saveModel:model complete:^(BOOL result) {
        ret = result;
    } synchronous:YES];
    return ret;
}

- (NSArray <LLNetworkModel *>*)getAllNetworkModels {
    __block NSArray *datas = @[];
    [self getModels:[LLNetworkModel class] launchDate:[NSObject launchDate] storageIdentity:nil complete:^(NSArray<LLStorageModel *> *result) {
        datas = result;
    } synchronous:YES];
    return datas;
}

- (NSArray <LLNetworkModel *>*)getAllNetworkModelsWithLaunchDate:(NSString *)launchDate {
    __block NSArray *datas = @[];
    [self getModels:[LLNetworkModel class] launchDate:launchDate storageIdentity:nil complete:^(NSArray<LLStorageModel *> *result) {
        datas = result;
    } synchronous:YES];
    return datas;
}

- (BOOL)removeNetworkModels:(NSArray <LLNetworkModel *>*)models {
    __block BOOL ret = YES;
    [self removeModels:models complete:^(BOOL result) {
        ret = result;
    } synchronous:YES];
    return ret;
}

- (BOOL)saveLogModel:(LLLogModel *)model {
    __block BOOL ret = YES;
    [self saveModel:model complete:^(BOOL result) {
        ret = result;
    } synchronous:YES];
    return ret;
}

- (NSArray <LLLogModel *>*)getAllLogModels {
    __block NSArray *datas = @[];
    [self getModels:[LLLogModel class] launchDate:[NSObject launchDate] storageIdentity:nil complete:^(NSArray<LLStorageModel *> *result) {
        datas = result;
    } synchronous:YES];
    return datas;
}

- (NSArray <LLLogModel *>*)getAllLogModelsWithLaunchDate:(NSString *)launchDate {
    __block NSArray *datas = @[];
    [self getModels:[LLLogModel class] launchDate:launchDate storageIdentity:nil complete:^(NSArray<LLStorageModel *> *result) {
        datas = result;
    } synchronous:YES];
    return datas;
}

- (BOOL)removeLogModels:(NSArray <LLLogModel *>*)models {
    __block BOOL ret = YES;
    [self removeModels:models complete:^(BOOL result) {
        ret = result;
    } synchronous:YES];
    return ret;
}

- (BOOL)saveScreenshot:(UIImage *)image name:(NSString *)name {
    [self saveScreenshot:image name:name complete:nil];
    return YES;
}

@end
