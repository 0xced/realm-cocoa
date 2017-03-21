////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMTestCase.h"

#import "RLMObjectSchema_Private.hpp"
#import "RLMRealmConfiguration_Private.hpp"
#import "RLMRealm_Dynamic.h"
#import "RLMSchema_Private.h"

#import <mach/mach_init.h>
#import <mach/vm_map.h>
#import <sys/resource.h>
#import <thread>

#import <realm/util/file.hpp>

@interface RLMRealm ()
+ (BOOL)isCoreDebug;
- (BOOL)compact;
@end

@interface RLMObjectSchema (Private)
+ (instancetype)schemaForObjectClass:(Class)objectClass;

@property (nonatomic, readwrite, assign) Class objectClass;
@end

@interface RLMSchema (Private)
@property (nonatomic, readwrite, copy) NSArray *objectSchema;
@end

@interface RealmTests : RLMTestCase
@end

@implementation RealmTests

- (void)deleteFiles {
    [super deleteFiles];

    for (NSString *realmPath in self.pathsFor100Realms) {
        [self deleteRealmFileAtURL:[NSURL fileURLWithPath:realmPath]];
    }
}

#pragma mark - Opening Realms

- (void)testOpeningInvalidPathThrows {
    RLMRealmConfiguration *config = [RLMRealmConfiguration defaultConfiguration];
    config.fileURL = [NSURL fileURLWithPath:@"/dev/null/foo"];
    RLMAssertThrowsWithCodeMatching([RLMRealm realmWithConfiguration:config error:nil], RLMErrorFileAccess);
}

- (void)testPathCannotBeBothInMemoryAndRegularDurability {
    RLMRealmConfiguration *config = [RLMRealmConfiguration defaultConfiguration];
    config.inMemoryIdentifier = @"identifier";
    RLMRealm *inMemoryRealm = [RLMRealm realmWithConfiguration:config error:nil];

    // make sure we can't open disk-realm at same path
    config.fileURL = [NSURL fileURLWithPath:@(inMemoryRealm.configuration.config.path.c_str())];
    NSError *error; // passing in a reference to assert that this error can't be catched!
    RLMAssertThrowsWithReasonMatching([RLMRealm realmWithConfiguration:config error:&error], @"Realm at path '.*' already opened with different inMemory settings");
}

- (void)testRealmWithPathUsesDefaultConfiguration {
    RLMRealmConfiguration *originalDefaultConfiguration = [RLMRealmConfiguration defaultConfiguration];
    RLMRealmConfiguration *newDefaultConfiguration = [originalDefaultConfiguration copy];
    newDefaultConfiguration.objectClasses = @[];
    [RLMRealmConfiguration setDefaultConfiguration:newDefaultConfiguration];
    XCTAssertEqual([[[[RLMRealm realmWithURL:RLMTestRealmURL()] configuration] objectClasses] count], 0U);
    [RLMRealmConfiguration setDefaultConfiguration:originalDefaultConfiguration];
}

- (void)testReadOnlyFile {
    @autoreleasepool {
        RLMRealm *realm = self.realmWithTestPath;
        [realm beginWriteTransaction];
        [StringObject createInRealm:realm withValue:@[@"a"]];
        [realm commitWriteTransaction];
    }

    [NSFileManager.defaultManager setAttributes:@{NSFileImmutable: @YES} ofItemAtPath:RLMTestRealmURL().path error:nil];

    // Should not be able to open read-write
    RLMAssertThrowsWithCodeMatching([self realmWithTestPath], RLMErrorFileAccess);

    RLMRealm *realm;
    XCTAssertNoThrow(realm = [self readOnlyRealmWithURL:RLMTestRealmURL() error:nil]);
    XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm].count);

    [NSFileManager.defaultManager setAttributes:@{NSFileImmutable: @NO} ofItemAtPath:RLMTestRealmURL().path error:nil];
}

- (void)testReadOnlyFileInImmutableDirectory {
    @autoreleasepool {
        RLMRealm *realm = self.realmWithTestPath;
        [realm beginWriteTransaction];
        [StringObject createInRealm:realm withValue:@[@"a"]];
        [realm commitWriteTransaction];
    }

    // Delete '*.lock' and '.note' files to simulate opening Realm in an app bundle
    [[NSFileManager defaultManager] removeItemAtURL:[RLMTestRealmURL() URLByAppendingPathExtension:@"lock"] error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:[RLMTestRealmURL() URLByAppendingPathExtension:@"note"] error:nil];

    // Make parent directory immutable to simulate opening Realm in an app bundle
    NSURL *parentDirectoryOfTestRealmURL = [RLMTestRealmURL() URLByDeletingLastPathComponent];
    [NSFileManager.defaultManager setAttributes:@{NSFileImmutable: @YES} ofItemAtPath:parentDirectoryOfTestRealmURL.path error:nil];

    RLMRealm *realm;
    // Read-only Realm should be opened even in immutable directory
    XCTAssertNoThrow(realm = [self readOnlyRealmWithURL:RLMTestRealmURL() error:nil]);

    [self dispatchAsyncAndWait:^{ XCTAssertNoThrow([self readOnlyRealmWithURL:RLMTestRealmURL() error:nil]); }];

    [NSFileManager.defaultManager setAttributes:@{NSFileImmutable: @NO} ofItemAtPath:parentDirectoryOfTestRealmURL.path error:nil];
}

- (void)testReadOnlyRealmMustExist {
   RLMAssertThrowsWithCodeMatching([self readOnlyRealmWithURL:RLMTestRealmURL() error:nil], RLMErrorFileNotFound);
}

- (void)testCannotHaveReadOnlyAndReadWriteRealmsAtSamePathAtSameTime {
    NSString *exceptionReason = @"Realm at path '.*' already opened with different read permissions";
    @autoreleasepool {
        XCTAssertNoThrow([self realmWithTestPath]);
        RLMAssertThrowsWithReasonMatching([self readOnlyRealmWithURL:RLMTestRealmURL() error:nil], exceptionReason);
    }

    @autoreleasepool {
        XCTAssertNoThrow([self readOnlyRealmWithURL:RLMTestRealmURL() error:nil]);
        RLMAssertThrowsWithReasonMatching([self realmWithTestPath], exceptionReason);
    }

    [self dispatchAsyncAndWait:^{
        XCTAssertNoThrow([self readOnlyRealmWithURL:RLMTestRealmURL() error:nil]);
        RLMAssertThrowsWithReasonMatching([self realmWithTestPath], exceptionReason);
    }];
}

- (void)testCanOpenReadOnlyOnMulitpleThreadsAtOnce {
    @autoreleasepool {
        RLMRealm *realm = self.realmWithTestPath;
        [realm beginWriteTransaction];
        [StringObject createInRealm:realm withValue:@[@"a"]];
        [realm commitWriteTransaction];
    }

    RLMRealm *realm = [self readOnlyRealmWithURL:RLMTestRealmURL() error:nil];
    XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm].count);

    [self dispatchAsyncAndWait:^{
        RLMRealm *realm = [self readOnlyRealmWithURL:RLMTestRealmURL() error:nil];
        XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm].count);
    }];

    // Verify that closing the other RLMRealm didn't manage to break anything
    XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm].count);
}

- (void)testFilePermissionDenied {
    @autoreleasepool {
        XCTAssertNoThrow([self realmWithTestPath]);
    }

    // Make Realm at test path temporarily unreadable
    NSError *error;
    NSNumber *permissions = [NSFileManager.defaultManager attributesOfItemAtPath:RLMTestRealmURL().path error:&error][NSFilePosixPermissions];
    assert(!error);
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @(0000)} ofItemAtPath:RLMTestRealmURL().path error:&error];
    assert(!error);

    RLMAssertThrowsWithCodeMatching([self realmWithTestPath], RLMErrorFilePermissionDenied);

    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: permissions} ofItemAtPath:RLMTestRealmURL().path error:&error];
    assert(!error);
}

// Check that the data for file was left unchanged when opened with upgrading
// disabled, but allow expanding the file to the page size
#define AssertFileUnmodified(oldURL, newURL) do { \
    NSData *oldData = [NSData dataWithContentsOfURL:oldURL]; \
    NSData *newData = [NSData dataWithContentsOfURL:newURL]; \
    if (oldData.length < realm::util::page_size()) { \
        XCTAssertEqual(newData.length, realm::util::page_size()); \
        XCTAssertNotEqual(([newData rangeOfData:oldData options:0 range:{0, oldData.length}]).location, NSNotFound); \
    } \
    else \
        XCTAssertEqualObjects(oldData, newData); \
} while (0)

- (void)testFileFormatUpgradeRequiredDeleteRealmIfNeeded {
    RLMRealmConfiguration *config = [RLMRealmConfiguration defaultConfiguration];
    config.deleteRealmIfMigrationNeeded = YES;

    NSURL *bundledRealmURL = [[NSBundle bundleForClass:[RealmTests class]] URLForResource:@"fileformat-pre-null" withExtension:@"realm"];
    [NSFileManager.defaultManager copyItemAtURL:bundledRealmURL toURL:config.fileURL error:nil];

    @autoreleasepool {
        XCTAssertTrue([[RLMRealm realmWithConfiguration:config error:nil] isEmpty]);
    }

    bundledRealmURL = [[NSBundle bundleForClass:[RealmTests class]] URLForResource:@"fileformat-old-date" withExtension:@"realm"];
    [NSFileManager.defaultManager removeItemAtURL:config.fileURL error:nil];
    [NSFileManager.defaultManager copyItemAtURL:bundledRealmURL toURL:config.fileURL error:nil];

    @autoreleasepool {
        XCTAssertTrue([[RLMRealm realmWithConfiguration:config error:nil] isEmpty]);
    }
}

- (void)testFileFormatUpgradeRequiredButDisabled {
    RLMRealmConfiguration *config = [RLMRealmConfiguration defaultConfiguration];
    config.disableFormatUpgrade = true;

    NSURL *bundledRealmURL = [[NSBundle bundleForClass:[RealmTests class]] URLForResource:@"fileformat-pre-null" withExtension:@"realm"];
    [NSFileManager.defaultManager copyItemAtURL:bundledRealmURL toURL:config.fileURL error:nil];

    RLMAssertThrowsWithCodeMatching([RLMRealm realmWithConfiguration:config error:nil],
                                    RLMErrorFileFormatUpgradeRequired);
    AssertFileUnmodified(bundledRealmURL, config.fileURL);

    bundledRealmURL = [[NSBundle bundleForClass:[RealmTests class]] URLForResource:@"fileformat-old-date" withExtension:@"realm"];
    [NSFileManager.defaultManager removeItemAtURL:config.fileURL error:nil];
    [NSFileManager.defaultManager copyItemAtURL:bundledRealmURL toURL:config.fileURL error:nil];

    RLMAssertThrowsWithCodeMatching([RLMRealm realmWithConfiguration:config error:nil],
                                    RLMErrorFileFormatUpgradeRequired);
    AssertFileUnmodified(bundledRealmURL, config.fileURL);
}

- (void)testFileFormatUpgradeRequiredButReadOnly {
    RLMRealmConfiguration *config = [RLMRealmConfiguration defaultConfiguration];
    config.readOnly = true;

    NSURL *bundledRealmURL = [[NSBundle bundleForClass:[RealmTests class]] URLForResource:@"fileformat-pre-null" withExtension:@"realm"];
    [NSFileManager.defaultManager copyItemAtURL:bundledRealmURL toURL:config.fileURL error:nil];

    RLMAssertThrowsWithCodeMatching([RLMRealm realmWithConfiguration:config error:nil], RLMErrorFileAccess);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:bundledRealmURL],
                          [NSData dataWithContentsOfURL:config.fileURL]);

    bundledRealmURL = [[NSBundle bundleForClass:[RealmTests class]] URLForResource:@"fileformat-old-date" withExtension:@"realm"];
    [NSFileManager.defaultManager removeItemAtURL:config.fileURL error:nil];
    [NSFileManager.defaultManager copyItemAtURL:bundledRealmURL toURL:config.fileURL error:nil];

    RLMAssertThrowsWithCodeMatching([RLMRealm realmWithConfiguration:config error:nil], RLMErrorFileAccess);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:bundledRealmURL],
                          [NSData dataWithContentsOfURL:config.fileURL]);
}

#if TARGET_OS_IPHONE && (!TARGET_IPHONE_SIMULATOR || !TARGET_RT_64_BIT)
- (void)testExceedingVirtualAddressSpace {
    RLMRealmConfiguration *config = [RLMRealmConfiguration defaultConfiguration];

    const NSUInteger stringLength = 1024 * 1024;
    void *mem = calloc(stringLength, '1');
    NSString *largeString = [[NSString alloc] initWithBytesNoCopy:mem
                                                           length:stringLength
                                                         encoding:NSUTF8StringEncoding
                                                     freeWhenDone:YES];

    @autoreleasepool {
        RLMRealm *realm = [RLMRealm realmWithConfiguration:config error:nil];
        [realm beginWriteTransaction];
        StringObject *stringObj = [StringObject new];
        stringObj.stringCol = largeString;
        [realm addObject:stringObj];
        [realm commitWriteTransaction];
    }

    struct VirtualMemoryChunk {
        vm_address_t address;
        vm_size_t size;
    };

    std::vector<VirtualMemoryChunk> allocatedChunks;
    NSUInteger size = 1024 * 1024 * 1024;
    while (size >= stringLength) {
        VirtualMemoryChunk chunk { .size = size };
        kern_return_t ret = vm_allocate(mach_task_self(), &chunk.address, chunk.size,
                                        VM_FLAGS_ANYWHERE);
        if (ret == KERN_NO_SPACE) {
            size /= 2;
        } else {
            allocatedChunks.push_back(chunk);
        }
    }

    @autoreleasepool {
        RLMAssertThrowsWithCodeMatching([RLMRealm realmWithConfiguration:config error:nil], RLMErrorAddressSpaceExhausted);
    }

    for (auto chunk : allocatedChunks) {
        kern_return_t ret = vm_deallocate(mach_task_self(), chunk.address, chunk.size);
        assert(ret == KERN_SUCCESS);
    }

    @autoreleasepool {
        XCTAssertNoThrow([RLMRealm realmWithConfiguration:config error:nil]);
    }
}
#endif

#pragma mark - Adding and Removing Objects

- (void)testRealmAddAndRemoveObjects {
    RLMRealm *realm = [self realmWithTestPath];
    [realm beginWriteTransaction];
    [StringObject createInRealm:realm withValue:@[@"a"]];
    [StringObject createInRealm:realm withValue:@[@"b"]];
    [StringObject createInRealm:realm withValue:@[@"c"]];
    XCTAssertEqual([StringObject objectsInRealm:realm withPredicate:nil].count, 3U, @"Expecting 3 objects");
    [realm commitWriteTransaction];

    // test again after write transaction
    RLMResults *objects = [StringObject allObjectsInRealm:realm];
    XCTAssertEqual(objects.count, 3U, @"Expecting 3 objects");
    XCTAssertEqualObjects([objects.firstObject stringCol], @"a", @"Expecting column to be 'a'");

    [realm beginWriteTransaction];
    [realm deleteObject:objects[2]];
    [realm deleteObject:objects[0]];
    XCTAssertEqual([StringObject objectsInRealm:realm withPredicate:nil].count, 1U, @"Expecting 1 object");
    [realm commitWriteTransaction];

    objects = [StringObject allObjectsInRealm:realm];
    XCTAssertEqual(objects.count, 1U, @"Expecting 1 object");
    XCTAssertEqualObjects([objects.firstObject stringCol], @"b", @"Expecting column to be 'b'");
}

- (void)testRemoveUnmanagedObject {
    RLMRealm *realm = [self realmWithTestPath];
    StringObject *obj = [[StringObject alloc] initWithValue:@[@"a"]];

    [realm beginWriteTransaction];
    XCTAssertThrows([realm deleteObject:obj]);
    obj = [StringObject createInRealm:realm withValue:@[@"b"]];
    [realm commitWriteTransaction];

    [self waitForNotification:RLMRealmDidChangeNotification realm:realm block:^{
        RLMRealm *realm = [self realmWithTestPath];
        RLMObject *obj = [[StringObject allObjectsInRealm:realm] firstObject];
        [realm beginWriteTransaction];
        [realm deleteObject:obj];
        XCTAssertThrows([realm deleteObject:obj]);
        [realm commitWriteTransaction];
    }];

    [realm beginWriteTransaction];
    [realm deleteObject:obj];
    [realm commitWriteTransaction];
}

- (void)testRealmBatchRemoveObjects {
    RLMRealm *realm = [self realmWithTestPath];
    [realm beginWriteTransaction];
    StringObject *strObj = [StringObject createInRealm:realm withValue:@[@"a"]];
    [StringObject createInRealm:realm withValue:@[@"b"]];
    [StringObject createInRealm:realm withValue:@[@"c"]];
    [realm commitWriteTransaction];

    // delete objects
    RLMResults *objects = [StringObject allObjectsInRealm:realm];
    XCTAssertEqual(objects.count, 3U, @"Expecting 3 objects");
    [realm beginWriteTransaction];
    [realm deleteObjects:[StringObject objectsInRealm:realm where:@"stringCol != 'a'"]];
    XCTAssertEqual([[StringObject allObjectsInRealm:realm] count], 1U, @"Expecting 0 objects");
    [realm deleteObjects:objects];
    XCTAssertEqual([[StringObject allObjectsInRealm:realm] count], 0U, @"Expecting 0 objects");
    [realm commitWriteTransaction];

    XCTAssertEqual([[StringObject allObjectsInRealm:realm] count], 0U, @"Expecting 0 objects");
    XCTAssertThrows(strObj.stringCol, @"Object should be invalidated");

    // add objects to linkView
    [realm beginWriteTransaction];
    ArrayPropertyObject *obj = [ArrayPropertyObject createInRealm:realm withValue:@[@"name", @[@[@"a"], @[@"b"], @[@"c"]], @[]]];
    [StringObject createInRealm:realm withValue:@[@"d"]];
    [realm commitWriteTransaction];

    XCTAssertEqual([[StringObject allObjectsInRealm:realm] count], 4U, @"Expecting 4 objects");

    // remove from linkView
    [realm beginWriteTransaction];
    [realm deleteObjects:obj.array];
    [realm commitWriteTransaction];

    XCTAssertEqual([[StringObject allObjectsInRealm:realm] count], 1U, @"Expecting 1 object");
    XCTAssertEqual(obj.array.count, 0U, @"Expecting 0 objects");

    // remove NSArray
    NSArray *arrayOfLastObject = @[[[StringObject allObjectsInRealm:realm] lastObject]];
    [realm beginWriteTransaction];
    [realm deleteObjects:arrayOfLastObject];
    [realm commitWriteTransaction];
    XCTAssertEqual(objects.count, 0U, @"Expecting 0 objects");

    // add objects to linkView
    [realm beginWriteTransaction];
    [obj.array addObject:[StringObject createInRealm:realm withValue:@[@"a"]]];
    [obj.array addObject:[[StringObject alloc] initWithValue:@[@"b"]]];
    [realm commitWriteTransaction];

    // remove objects from realm
    XCTAssertEqual(obj.array.count, 2U, @"Expecting 2 objects");
    [realm beginWriteTransaction];
    [realm deleteObjects:[StringObject allObjectsInRealm:realm]];
    [realm commitWriteTransaction];
    XCTAssertEqual(obj.array.count, 0U, @"Expecting 0 objects");
}

- (void)testAddManagedObjectToOtherRealm {
    RLMRealm *realm1 = [self realmWithTestPath];
    RLMRealm *realm2 = [RLMRealm defaultRealm];

    CircleObject *co1 = [[CircleObject alloc] init];
    co1.data = @"1";

    CircleObject *co2 = [[CircleObject alloc] init];
    co2.data = @"2";
    co2.next = co1;

    CircleArrayObject *cao = [[CircleArrayObject alloc] init];
    [cao.circles addObject:co1];

    [realm1 transactionWithBlock:^{ [realm1 addObject:co1]; }];

    [realm2 beginWriteTransaction];
    XCTAssertThrows([realm2 addObject:co1], @"should reject already-managed object");
    XCTAssertThrows([realm2 addObject:co2], @"should reject linked managed object");
    XCTAssertThrows([realm2 addObject:cao], @"should reject array containing managed object");
    [realm2 commitWriteTransaction];

    // The objects are left in an odd state if validation fails (since the
    // exception isn't supposed to be recoverable), so make new objects
    co2 = [[CircleObject alloc] init];
    co2.data = @"2";
    co2.next = co1;

    cao = [[CircleArrayObject alloc] init];
    [cao.circles addObject:co1];

    [realm1 beginWriteTransaction];
    XCTAssertNoThrow([realm1 addObject:co2],
                     @"should be able to add object which links to object managed by target Realm");
    XCTAssertNoThrow([realm1 addObject:cao],
                     @"should be able to add object with an array containing an object managed by target Realm");
    [realm1 commitWriteTransaction];
}

- (void)testCopyObjectsBetweenRealms {
    RLMRealm *realm1 = [self realmWithTestPath];
    RLMRealm *realm2 = [RLMRealm defaultRealm];

    StringObject *so = [[StringObject alloc] init];
    so.stringCol = @"value";

    [realm1 beginWriteTransaction];
    [realm1 addObject:so];
    [realm1 commitWriteTransaction];

    XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm1].count);
    XCTAssertEqual(0U, [StringObject allObjectsInRealm:realm2].count);
    XCTAssertEqualObjects(so.stringCol, @"value");

    [realm2 beginWriteTransaction];
    StringObject *so2 = [StringObject createInRealm:realm2 withValue:so];
    [realm2 commitWriteTransaction];

    XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm1].count);
    XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm2].count);
    XCTAssertEqualObjects(so2.stringCol, @"value");
}

- (void)testCopyArrayPropertyBetweenRealms {
    RLMRealm *realm1 = [self realmWithTestPath];
    RLMRealm *realm2 = [RLMRealm defaultRealm];

    EmployeeObject *eo = [[EmployeeObject alloc] init];
    eo.name = @"name";
    eo.age = 50;
    eo.hired = YES;

    CompanyObject *co = [[CompanyObject alloc] init];
    co.name = @"company name";
    [co.employees addObject:eo];

    [realm1 beginWriteTransaction];
    [realm1 addObject:co];
    [realm1 commitWriteTransaction];

    XCTAssertEqual(1U, [EmployeeObject allObjectsInRealm:realm1].count);
    XCTAssertEqual(1U, [CompanyObject allObjectsInRealm:realm1].count);

    [realm2 beginWriteTransaction];
    CompanyObject *co2 = [CompanyObject createInRealm:realm2 withValue:co];
    [realm2 commitWriteTransaction];

    XCTAssertEqual(1U, [EmployeeObject allObjectsInRealm:realm1].count);
    XCTAssertEqual(1U, [CompanyObject allObjectsInRealm:realm1].count);
    XCTAssertEqual(1U, [EmployeeObject allObjectsInRealm:realm2].count);
    XCTAssertEqual(1U, [CompanyObject allObjectsInRealm:realm2].count);

    XCTAssertEqualObjects(@"name", [co2.employees.firstObject name]);
}

- (void)testCopyLinksBetweenRealms {
    RLMRealm *realm1 = [self realmWithTestPath];
    RLMRealm *realm2 = [RLMRealm defaultRealm];

    CircleObject *c = [[CircleObject alloc] init];
    c.data = @"1";
    c.next = [[CircleObject alloc] init];
    c.next.data = @"2";

    [realm1 beginWriteTransaction];
    [realm1 addObject:c];
    [realm1 commitWriteTransaction];

    XCTAssertEqual(realm1, c.realm);
    XCTAssertEqual(realm1, c.next.realm);
    XCTAssertEqual(2U, [CircleObject allObjectsInRealm:realm1].count);

    [realm2 beginWriteTransaction];
    CircleObject *c2 = [CircleObject createInRealm:realm2 withValue:c];
    [realm2 commitWriteTransaction];

    XCTAssertEqualObjects(c2.data, @"1");
    XCTAssertEqualObjects(c2.next.data, @"2");

    XCTAssertEqual(2U, [CircleObject allObjectsInRealm:realm1].count);
    XCTAssertEqual(2U, [CircleObject allObjectsInRealm:realm2].count);
}

- (void)testCopyObjectsInArrayLiteral {
    RLMRealm *realm1 = [self realmWithTestPath];
    RLMRealm *realm2 = [RLMRealm defaultRealm];

    CircleObject *c = [[CircleObject alloc] init];
    c.data = @"1";

    [realm1 beginWriteTransaction];
    [realm1 addObject:c];
    [realm1 commitWriteTransaction];

    [realm2 beginWriteTransaction];
    CircleObject *c2 = [CircleObject createInRealm:realm2 withValue:@[@"3", @[@"2", c]]];
    [realm2 commitWriteTransaction];

    XCTAssertEqual(1U, [CircleObject allObjectsInRealm:realm1].count);
    XCTAssertEqual(3U, [CircleObject allObjectsInRealm:realm2].count);
    XCTAssertEqual(realm1, c.realm);
    XCTAssertEqual(realm2, c2.realm);

    XCTAssertEqualObjects(@"1", c.data);
    XCTAssertEqualObjects(@"3", c2.data);
    XCTAssertEqualObjects(@"2", c2.next.data);
    XCTAssertEqualObjects(@"1", c2.next.next.data);
}

- (void)testAddOrUpdate {
    RLMRealm *realm = [RLMRealm defaultRealm];
    [realm beginWriteTransaction];

    PrimaryStringObject *obj = [[PrimaryStringObject alloc] initWithValue:@[@"string", @1]];
    [realm addOrUpdateObject:obj];
    RLMResults *objects = [PrimaryStringObject allObjects];
    XCTAssertEqual([objects count], 1U, @"Should have 1 object");
    XCTAssertEqual([(PrimaryStringObject *)objects[0] intCol], 1, @"Value should be 1");

    PrimaryStringObject *obj2 = [[PrimaryStringObject alloc] initWithValue:@[@"string2", @2]];
    [realm addOrUpdateObject:obj2];
    XCTAssertEqual([objects count], 2U, @"Should have 2 objects");

    // upsert with new secondary property
    PrimaryStringObject *obj3 = [[PrimaryStringObject alloc] initWithValue:@[@"string", @3]];
    [realm addOrUpdateObject:obj3];
    XCTAssertEqual([objects count], 2U, @"Should have 2 objects");
    XCTAssertEqual([(PrimaryStringObject *)objects[0] intCol], 3, @"Value should be 3");

    // upsert on non-primary key object should throw
    XCTAssertThrows([realm addOrUpdateObject:[[StringObject alloc] initWithValue:@[@"string"]]]);

    [realm commitWriteTransaction];
}

- (void)testAddOrUpdateObjectsFromArray {
    RLMRealm *realm = [RLMRealm defaultRealm];
    [realm beginWriteTransaction];

    PrimaryStringObject *obj = [[PrimaryStringObject alloc] initWithValue:@[@"string1", @1]];
    [realm addObject:obj];

    PrimaryStringObject *obj2 = [[PrimaryStringObject alloc] initWithValue:@[@"string2", @2]];
    [realm addObject:obj2];

    PrimaryStringObject *obj3 = [[PrimaryStringObject alloc] initWithValue:@[@"string3", @3]];
    [realm addObject:obj3];

    RLMResults *objects = [PrimaryStringObject allObjects];
    XCTAssertEqual([objects count], 3U, @"Should have 3 object");
    XCTAssertEqual([(PrimaryStringObject *)objects[0] intCol], 1, @"Value should be 1");
    XCTAssertEqual([(PrimaryStringObject *)objects[1] intCol], 2, @"Value should be 2");
    XCTAssertEqual([(PrimaryStringObject *)objects[2] intCol], 3, @"Value should be 3");

    // upsert with array of 2 objects. One is to update the existing value, another is added
    NSArray *array = @[[[PrimaryStringObject alloc] initWithValue:@[@"string2", @4]],
                       [[PrimaryStringObject alloc] initWithValue:@[@"string4", @5]]];
    [realm addOrUpdateObjectsFromArray:array];
    XCTAssertEqual([objects count], 4U, @"Should have 4 objects");
    XCTAssertEqual([(PrimaryStringObject *)objects[0] intCol], 1, @"Value should be 1");
    XCTAssertEqual([(PrimaryStringObject *)objects[1] intCol], 4, @"Value should be 4");
    XCTAssertEqual([(PrimaryStringObject *)objects[2] intCol], 3, @"Value should be 3");
    XCTAssertEqual([(PrimaryStringObject *)objects[3] intCol], 5, @"Value should be 5");

    [realm commitWriteTransaction];
}

- (void)testDelete {
    RLMRealm *realm = [RLMRealm defaultRealm];

    [realm beginWriteTransaction];
    OwnerObject *obj = [OwnerObject createInDefaultRealmWithValue:@[@"deeter", @[@"barney", @2]]];
    [realm commitWriteTransaction];

    XCTAssertEqual(1U, OwnerObject.allObjects.count);
    XCTAssertEqual(NO, obj.invalidated);

    XCTAssertThrows([realm deleteObject:obj]);

    RLMRealm *testRealm = [self realmWithTestPath];
    [testRealm transactionWithBlock:^{
        XCTAssertThrows([testRealm deleteObject:[[OwnerObject alloc] init]]);
        [realm transactionWithBlock:^{
            XCTAssertThrows([testRealm deleteObject:obj]);
        }];
    }];

    [realm transactionWithBlock:^{
        [realm deleteObject:obj];
        XCTAssertEqual(YES, obj.invalidated);
    }];

    XCTAssertEqual(0U, OwnerObject.allObjects.count);
}

- (void)testDeleteObjects {
    RLMRealm *realm = [RLMRealm defaultRealm];

    [realm beginWriteTransaction];
    CompanyObject *obj = [CompanyObject createInDefaultRealmWithValue:@[@"deeter", @[@[@"barney", @2, @YES]]]];
    NSArray *objects = @[obj];
    [realm commitWriteTransaction];

    XCTAssertEqual(1U, CompanyObject.allObjects.count);

    XCTAssertThrows([realm deleteObjects:objects]);
    XCTAssertThrows([realm deleteObjects:[CompanyObject allObjectsInRealm:realm]]);
    XCTAssertThrows([realm deleteObjects:obj.employees]);

    RLMRealm *testRealm = [self realmWithTestPath];
    [testRealm transactionWithBlock:^{
        [realm transactionWithBlock:^{
            XCTAssertThrows([testRealm deleteObjects:objects]);
            XCTAssertThrows([testRealm deleteObjects:[CompanyObject allObjectsInRealm:realm]]);
            XCTAssertThrows([testRealm deleteObjects:obj.employees]);
        }];
    }];

    XCTAssertEqual(1U, CompanyObject.allObjects.count);
}

- (void)testDeleteAllObjects {
    RLMRealm *realm = [RLMRealm defaultRealm];

    [realm beginWriteTransaction];
    OwnerObject *obj = [OwnerObject createInDefaultRealmWithValue:@[@"deeter", @[@"barney", @2]]];
    [realm commitWriteTransaction];

    XCTAssertEqual(1U, OwnerObject.allObjects.count);
    XCTAssertEqual(1U, DogObject.allObjects.count);
    XCTAssertEqual(NO, obj.invalidated);

    XCTAssertThrows([realm deleteAllObjects]);

    [realm transactionWithBlock:^{
        [realm deleteAllObjects];
        XCTAssertEqual(YES, obj.invalidated);
    }];

    XCTAssertEqual(0U, OwnerObject.allObjects.count);
    XCTAssertEqual(0U, DogObject.allObjects.count);
}

- (void)testAddObjectsFromArray
{
    RLMRealm *realm = [self realmWithTestPath];

    [realm beginWriteTransaction];
    XCTAssertThrows(([realm addObjects:@[@[@"Rex", @10]]]),
                    @"should reject non-RLMObject in array");

    DogObject *dog = [DogObject new];
    dog.dogName = @"Rex";
    dog.age = 10;
    XCTAssertNoThrow([realm addObjects:@[dog]], @"should allow RLMObject in array");
    XCTAssertEqual(1U, [[DogObject allObjectsInRealm:realm] count]);
    [realm cancelWriteTransaction];
}

#pragma mark - Transactions

- (void)testRealmTransactionBlock {
    RLMRealm *realm = [self realmWithTestPath];
    [realm transactionWithBlock:^{
        [StringObject createInRealm:realm withValue:@[@"b"]];
    }];
    RLMResults *objects = [StringObject allObjectsInRealm:realm];
    XCTAssertEqual(objects.count, 1U, @"Expecting 1 object");
    XCTAssertEqualObjects([objects.firstObject stringCol], @"b", @"Expecting column to be 'b'");
}

- (void)testInWriteTransaction {
    RLMRealm *realm = [self realmWithTestPath];
    XCTAssertFalse(realm.inWriteTransaction);
    [realm beginWriteTransaction];
    XCTAssertTrue(realm.inWriteTransaction);
    [realm cancelWriteTransaction];
    [realm transactionWithBlock:^{
        XCTAssertTrue(realm.inWriteTransaction);
        [realm cancelWriteTransaction];
        XCTAssertFalse(realm.inWriteTransaction);
    }];

    [realm beginWriteTransaction];
    [realm invalidate];
    XCTAssertFalse(realm.inWriteTransaction);
}

- (void)testAutorefreshAfterBackgroundUpdate {
    RLMRealm *realm = [self realmWithTestPath];

    XCTAssertEqual(0U, [StringObject allObjectsInRealm:realm].count);

    [self waitForNotification:RLMRealmDidChangeNotification realm:realm block:^{
        RLMRealm *realm = [self realmWithTestPath];
        [realm beginWriteTransaction];
        [StringObject createInRealm:realm withValue:@[@"string"]];
        [realm commitWriteTransaction];
    }];

    XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm].count);
}

- (void)testBackgroundUpdateWithoutAutorefresh {
    RLMRealm *realm = [self realmWithTestPath];
    realm.autorefresh = NO;

    XCTAssertEqual(0U, [StringObject allObjectsInRealm:realm].count);

    [self waitForNotification:RLMRealmRefreshRequiredNotification realm:realm block:^{
        RLMRealm *realm = [self realmWithTestPath];
        [realm beginWriteTransaction];
        [StringObject createInRealm:realm withValue:@[@"string"]];
        [realm commitWriteTransaction];

        XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm].count);
    }];

    XCTAssertEqual(0U, [StringObject allObjectsInRealm:realm].count);

    [realm refresh];
    XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm].count);
}

- (void)testBeginWriteTransactionsNotifiesWithUpdatedObjects {
    RLMRealm *realm = [self realmWithTestPath];
    realm.autorefresh = NO;

    XCTAssertEqual(0U, [StringObject allObjectsInRealm:realm].count);

    // Create an object in a background thread and wait for that to complete,
    // without refreshing the main thread realm
    [self waitForNotification:RLMRealmRefreshRequiredNotification realm:realm block:^{
        RLMRealm *realm = [self realmWithTestPath];
        [realm beginWriteTransaction];
        [StringObject createInRealm:realm withValue:@[@"string"]];
        [realm commitWriteTransaction];

        XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm].count);
    }];

    // Verify that the main thread realm still doesn't have any objects
    XCTAssertEqual(0U, [StringObject allObjectsInRealm:realm].count);

    // Verify that the local notification sent by the beginWriteTransaction
    // below when it advances the realm to the latest version occurs *after*
    // the advance
    __block bool notificationFired = false;
    RLMNotificationToken *token = [realm addNotificationBlock:^(__unused NSString *note, RLMRealm *realm) {
        XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm].count);
        notificationFired = true;
    }];

    [realm beginWriteTransaction];
    [realm commitWriteTransaction];

    [token stop];
    XCTAssertTrue(notificationFired);
}

- (void)testBeginWriteTransactionsRefreshesRealm {
    // auto refresh on by default
    RLMRealm *realm = [self realmWithTestPath];

    // Set up notification which will be triggered when calling beginWriteTransaction
    __block bool notificationFired = false;
    RLMNotificationToken *token = [realm addNotificationBlock:^(__unused NSString *note, RLMRealm *realm) {
        XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm].count);
        XCTAssertThrows([realm beginWriteTransaction], @"We should already be in a write transaction");
        notificationFired = true;
    }];

    // dispatch to background syncronously
    [self dispatchAsyncAndWait:^{
        RLMRealm *realm = [self realmWithTestPath];
        [realm beginWriteTransaction];
        [StringObject createInRealm:realm withValue:@[@"string"]];
        [realm commitWriteTransaction];
    }];

    // notification shouldnt have fired
    XCTAssertFalse(notificationFired);

    [realm beginWriteTransaction];

    // notification should have fired
    XCTAssertTrue(notificationFired);

    [realm cancelWriteTransaction];
    [token stop];
}

- (void)testBeginWriteTransactionFromWithinRefreshRequiredNotification {
    RLMRealm *realm = [RLMRealm defaultRealm];
    realm.autorefresh = NO;

    auto expectation = [self expectationWithDescription:@""];
    RLMNotificationToken *token = [realm addNotificationBlock:^(NSString *note, RLMRealm *realm) {
        XCTAssertEqual(RLMRealmRefreshRequiredNotification, note);
        XCTAssertEqual(0U, [StringObject allObjectsInRealm:realm].count);
        [realm beginWriteTransaction];
        XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm].count);
        [realm cancelWriteTransaction];
        [expectation fulfill]; // note that this will throw if the notification is incorrectly called twice
    }];

    [self dispatchAsyncAndWait:^{
        RLMRealm *realm = [RLMRealm defaultRealm];
        [realm beginWriteTransaction];
        [StringObject createInRealm:realm withValue:@[@"string"]];
        [realm commitWriteTransaction];
    }];

    [self waitForExpectationsWithTimeout:2.0 handler:nil];
    [token stop];
}

- (void)testBeginWriteTransactionFromWithinRealmChangedNotification {
    RLMRealm *realm = [RLMRealm defaultRealm];

    auto createObject = ^{
        [self dispatchAsyncAndWait:^{
            RLMRealm *realm = [RLMRealm defaultRealm];
            [realm beginWriteTransaction];
            [StringObject createInRealm:realm withValue:@[@"string"]];
            [realm commitWriteTransaction];
        }];
    };

    // Test with the triggering transaction on a different thread
    auto expectation = [self expectationWithDescription:@""];
    RLMNotificationToken *token = [realm addNotificationBlock:^(NSString *note, RLMRealm *realm) {
        XCTAssertEqual(RLMRealmDidChangeNotification, note);

        // We're in DidChange, so the first object is already present
        XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm].count);
        createObject();

        // Haven't refreshed yet, so still one
        XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm].count);

        // Refreshes without sending notifications since we're within a notification
        [realm beginWriteTransaction];
        XCTAssertEqual(2U, [StringObject allObjectsInRealm:realm].count);
        [realm cancelWriteTransaction];
        [expectation fulfill]; // note that this will throw if the notification is incorrectly called twice
    }];

    createObject();

    [self waitForExpectationsWithTimeout:2.0 handler:nil];
    [token stop];

    // Test with the triggering transaction on the same thread
    __block bool first = true;
    token = [realm addNotificationBlock:^(NSString *note, RLMRealm *realm) {
        XCTAssertTrue(first);
        XCTAssertEqual(RLMRealmDidChangeNotification, note);
        XCTAssertEqual(3U, [StringObject allObjectsInRealm:realm].count);
        first = false;

        [realm beginWriteTransaction]; // should not trigger a notification
        [StringObject createInRealm:realm withValue:@[@"string"]];
        [realm commitWriteTransaction]; // also should not trigger a notification
    }];

    [realm beginWriteTransaction];
    [StringObject createInRealm:realm withValue:@[@"string"]];
    [realm commitWriteTransaction];
}

- (void)testBeginWriteTransactionFromWithinCollectionChangedNotification {
    RLMRealm *realm = [RLMRealm defaultRealm];

    auto createObject = ^{
        [self dispatchAsyncAndWait:^{
            RLMRealm *realm = [RLMRealm defaultRealm];
            [realm beginWriteTransaction];
            [StringObject createInRealm:realm withValue:@[@"string"]];
            [realm commitWriteTransaction];
        }];
    };

    __block auto expectation = [self expectationWithDescription:@""];
    __block RLMNotificationToken *token;
    auto block = ^(RLMResults *results, RLMCollectionChange *changes, NSError *) {
        if (!changes) {
            [expectation fulfill];
            return;
        }

        XCTAssertEqual(1U, results.count);
        createObject();
        XCTAssertEqual(1U, results.count);
        [realm beginWriteTransaction];
        XCTAssertEqual(2U, results.count);
        [realm cancelWriteTransaction];
        [expectation fulfill];
        [token stop];
    };
    token = [StringObject.allObjects addNotificationBlock:block];
    [self waitForExpectationsWithTimeout:2.0 handler:nil];

    createObject();
    expectation = [self expectationWithDescription:@""];
    [self waitForExpectationsWithTimeout:2.0 handler:nil];
}

- (void)testReadOnlyRealmIsImmutable
{
    @autoreleasepool { [self realmWithTestPath]; }

    RLMRealm *realm = [self readOnlyRealmWithURL:RLMTestRealmURL() error:nil];
    XCTAssertThrows([realm beginWriteTransaction]);
    XCTAssertThrows([realm refresh]);
}

- (void)testRollbackInsert
{
    RLMRealm *realm = [self realmWithTestPath];

    [realm beginWriteTransaction];
    IntObject *createdObject = [IntObject createInRealm:realm withValue:@[@0]];
    [realm cancelWriteTransaction];

    XCTAssertTrue(createdObject.isInvalidated);
    XCTAssertEqual(0U, [IntObject allObjectsInRealm:realm].count);
}

- (void)testRollbackDelete
{
    RLMRealm *realm = [self realmWithTestPath];

    [realm beginWriteTransaction];
    IntObject *objectToDelete = [IntObject createInRealm:realm withValue:@[@0]];
    [realm commitWriteTransaction];

    [realm beginWriteTransaction];
    [realm deleteObject:objectToDelete];
    [realm cancelWriteTransaction];

    XCTAssertTrue(objectToDelete.isInvalidated);
    XCTAssertEqual(1U, [IntObject allObjectsInRealm:realm].count);
}

- (void)testRollbackModify
{
    RLMRealm *realm = [self realmWithTestPath];

    [realm beginWriteTransaction];
    IntObject *objectToModify = [IntObject createInRealm:realm withValue:@[@0]];
    [realm commitWriteTransaction];

    [realm beginWriteTransaction];
    objectToModify.intCol = 1;
    [realm cancelWriteTransaction];

    XCTAssertEqual(0, objectToModify.intCol);
}

- (void)testRollbackLink
{
    RLMRealm *realm = [self realmWithTestPath];

    [realm beginWriteTransaction];
    CircleObject *obj1 = [CircleObject createInRealm:realm withValue:@[@"1", NSNull.null]];
    CircleObject *obj2 = [CircleObject createInRealm:realm withValue:@[@"2", NSNull.null]];
    [realm commitWriteTransaction];

    // Link to existing managed
    [realm beginWriteTransaction];
    obj1.next = obj2;
    [realm cancelWriteTransaction];

    XCTAssertNil(obj1.next);

    // Link to unmanaged
    [realm beginWriteTransaction];
    CircleObject *obj3 = [[CircleObject alloc] init];
    obj3.data = @"3";
    obj1.next = obj3;
    [realm cancelWriteTransaction];

    XCTAssertNil(obj1.next);
    XCTAssertEqual(2U, [CircleObject allObjectsInRealm:realm].count);

    // Remove link
    [realm beginWriteTransaction];
    obj1.next = obj2;
    [realm commitWriteTransaction];

    [realm beginWriteTransaction];
    obj1.next = nil;
    [realm cancelWriteTransaction];

    XCTAssertTrue([obj1.next isEqualToObject:obj2]);

    // Modify link
    [realm beginWriteTransaction];
    CircleObject *obj4 = [CircleObject createInRealm:realm withValue:@[@"4", NSNull.null]];
    [realm commitWriteTransaction];

    [realm beginWriteTransaction];
    obj1.next = obj4;
    [realm cancelWriteTransaction];

    XCTAssertTrue([obj1.next isEqualToObject:obj2]);
}

- (void)testRollbackLinkList
{
    RLMRealm *realm = [self realmWithTestPath];

    [realm beginWriteTransaction];
    IntObject *obj1 = [IntObject createInRealm:realm withValue:@[@0]];
    IntObject *obj2 = [IntObject createInRealm:realm withValue:@[@1]];
    ArrayPropertyObject *array = [ArrayPropertyObject createInRealm:realm withValue:@[@"", @[], @[obj1]]];
    [realm commitWriteTransaction];

    // Add existing managed object
    [realm beginWriteTransaction];
    [array.intArray addObject:obj2];
    [realm cancelWriteTransaction];

    XCTAssertEqual(1U, array.intArray.count);

    // Add unmanaged object
    [realm beginWriteTransaction];
    [array.intArray addObject:[[IntObject alloc] init]];
    [realm cancelWriteTransaction];

    XCTAssertEqual(1U, array.intArray.count);
    XCTAssertEqual(2U, [IntObject allObjectsInRealm:realm].count);

    // Remove
    [realm beginWriteTransaction];
    [array.intArray removeObjectAtIndex:0];
    [realm cancelWriteTransaction];

    XCTAssertEqual(1U, array.intArray.count);

    // Modify
    [realm beginWriteTransaction];
    array.intArray[0] = obj2;
    [realm cancelWriteTransaction];

    XCTAssertEqual(1U, array.intArray.count);
    XCTAssertTrue([array.intArray[0] isEqualToObject:obj1]);
}

- (void)testRollbackTransactionWithBlock
{
    RLMRealm *realm = [self realmWithTestPath];
    [realm transactionWithBlock:^{
        [IntObject createInRealm:realm withValue:@[@0]];
        [realm cancelWriteTransaction];
    }];

    XCTAssertEqual(0U, [IntObject allObjectsInRealm:realm].count);
}

- (void)testRollbackTransactionWithoutExplicitCommitOrCancel
{
    @autoreleasepool {
        RLMRealm *realm = [self realmWithTestPath];
        [realm beginWriteTransaction];
        [IntObject createInRealm:realm withValue:@[@0]];
    }

    XCTAssertEqual(0U, [IntObject allObjectsInRealm:[self realmWithTestPath]].count);
}

- (void)testCanRestartReadTransactionAfterInvalidate
{
    RLMRealm *realm = [RLMRealm defaultRealm];
    [realm transactionWithBlock:^{
        [IntObject createInRealm:realm withValue:@[@1]];
    }];

    [realm invalidate];
    IntObject *obj = [IntObject allObjectsInRealm:realm].firstObject;
    XCTAssertEqual(obj.intCol, 1);
}

- (void)testInvalidateDetachesAccessors
{
    RLMRealm *realm = [RLMRealm defaultRealm];
    __block IntObject *obj;
    [realm transactionWithBlock:^{
        obj = [IntObject createInRealm:realm withValue:@[@0]];
    }];

    [realm invalidate];
    XCTAssertTrue(obj.isInvalidated);
    XCTAssertThrows([obj intCol]);
}

- (void)testInvalidateInvalidatesResults
{
    RLMRealm *realm = [RLMRealm defaultRealm];
    [realm transactionWithBlock:^{
        [IntObject createInRealm:realm withValue:@[@1]];
    }];

    RLMResults *results = [IntObject objectsInRealm:realm where:@"intCol = 1"];
    XCTAssertEqual([results.firstObject intCol], 1);

    [realm invalidate];
    XCTAssertThrows([results count]);
    XCTAssertThrows([results firstObject]);
}

- (void)testInvalidateInvalidatesArrays
{
    RLMRealm *realm = [RLMRealm defaultRealm];
    __block ArrayPropertyObject *arrayObject;
    [realm transactionWithBlock:^{
        arrayObject = [ArrayPropertyObject createInRealm:realm withValue:@[@"", @[], @[@[@1]]]];
    }];

    RLMArray *array = arrayObject.intArray;
    XCTAssertEqual(1U, array.count);

    [realm invalidate];
    XCTAssertThrows([array count]);
}

- (void)testInvalidateOnReadOnlyRealmIsError
{
    @autoreleasepool {
        // Create the file
        [self realmWithTestPath];
    }
    RLMRealm *realm = [self readOnlyRealmWithURL:RLMTestRealmURL() error:nil];
    XCTAssertThrows([realm invalidate]);
}

- (void)testInvalidateBeforeReadDoesNotAssert
{
    RLMRealm *realm = [RLMRealm defaultRealm];
    [realm invalidate];
}

- (void)testInvalidateDuringWriteRollsBack
{
    RLMRealm *realm = [RLMRealm defaultRealm];
    [realm beginWriteTransaction];
    @autoreleasepool {
        [IntObject createInRealm:realm withValue:@[@1]];
    }
    [realm invalidate];

    XCTAssertEqual(0U, [IntObject allObjectsInRealm:realm].count);
}

- (void)testRefreshCreatesAReadTransaction
{
    RLMRealm *realm = [RLMRealm defaultRealm];

    [self dispatchAsyncAndWait:^{
        [RLMRealm.defaultRealm transactionWithBlock:^{
            [IntObject createInDefaultRealmWithValue:@[@1]];
        }];
    }];

    XCTAssertTrue([realm refresh]);

    [self dispatchAsyncAndWait:^{
        [RLMRealm.defaultRealm transactionWithBlock:^{
            [IntObject createInDefaultRealmWithValue:@[@1]];
        }];
    }];

    // refresh above should have created a read transaction, so realm should
    // still only see one object
    XCTAssertEqual(1U, [IntObject allObjects].count);

    // Just a sanity check
    XCTAssertTrue([realm refresh]);
    XCTAssertEqual(2U, [IntObject allObjects].count);
}

- (void)testInWriteTransactionInNotificationFromBeginWrite {
    RLMRealm *realm = RLMRealm.defaultRealm;
    realm.autorefresh = NO;

    __block bool called = false;
    RLMNotificationToken *token = [realm addNotificationBlock:^(NSString *note, RLMRealm *realm) {
        if (note == RLMRealmDidChangeNotification) {
            called = true;
            XCTAssertTrue(realm.inWriteTransaction);
        }
    }];

    [self waitForNotification:RLMRealmRefreshRequiredNotification realm:realm block:^{
        [RLMRealm.defaultRealm transactionWithBlock:^{ }];
    }];

    [realm beginWriteTransaction];
    XCTAssertTrue(called);
    [realm cancelWriteTransaction];
    [token stop];
}

- (void)testThrowingFromDidChangeNotificationFromBeginWriteCancelsTransaction {
    RLMRealm *realm = RLMRealm.defaultRealm;
    realm.autorefresh = NO;

    RLMNotificationToken *token = [realm addNotificationBlock:^(NSString *note, RLMRealm *) {
        if (note == RLMRealmDidChangeNotification) {
            throw 0;
        }
    }];

    [self waitForNotification:RLMRealmRefreshRequiredNotification realm:realm block:^{
        [RLMRealm.defaultRealm transactionWithBlock:^{ }];
    }];

    try {
        [realm beginWriteTransaction];
        XCTFail(@"should have thrown");
    }
    catch (int) { }
    [token stop];

    XCTAssertFalse(realm.inWriteTransaction);
    XCTAssertNoThrow([realm beginWriteTransaction]);
    [realm cancelWriteTransaction];
}

- (void)testThrowingFromDidChangeNotificationAfterLocalCommit {
    RLMRealm *realm = RLMRealm.defaultRealm;
    realm.autorefresh = NO;

    RLMNotificationToken *token = [realm addNotificationBlock:^(NSString *note, RLMRealm *) {
        if (note == RLMRealmDidChangeNotification) {
            throw 0;
        }
    }];

    [realm beginWriteTransaction];
    try {
        [realm commitWriteTransaction];
        XCTFail(@"should have thrown");
    }
    catch (int) { }
    [token stop];

    XCTAssertFalse(realm.inWriteTransaction);
    XCTAssertNoThrow([realm beginWriteTransaction]);
    [realm cancelWriteTransaction];
}

- (void)testNotificationsFireEvenWithoutReadTransaction {
    RLMRealm *realm = RLMRealm.defaultRealm;

    XCTestExpectation *notificationFired = [self expectationWithDescription:@"notification fired"];
    RLMNotificationToken *token = [realm addNotificationBlock:^(NSString *note, RLMRealm *) {
        if (note == RLMRealmDidChangeNotification) {
            [notificationFired fulfill];
        }
    }];

    [realm invalidate];
    [self dispatchAsync:^{
        [RLMRealm.defaultRealm transactionWithBlock:^{ }];
    }];
    [self waitForExpectationsWithTimeout:2.0 handler:nil];
    [token stop];
}

- (void)testNotificationBlockMustNotBeNil {
    RLMRealm *realm = RLMRealm.defaultRealm;
    XCTAssertThrows([realm addNotificationBlock:self.nonLiteralNil]);
}

- (void)testRefreshInWriteTransactionReturnsFalse {
    RLMRealm *realm = RLMRealm.defaultRealm;
    [realm beginWriteTransaction];
    [IntObject createInRealm:realm withValue:@[@0]];
    XCTAssertFalse([realm refresh]);
    [realm cancelWriteTransaction];
}

- (void)testCancelWriteWhenNotInWrite {
    XCTAssertThrows([RLMRealm.defaultRealm cancelWriteTransaction]);
}

#pragma mark - Threads

- (void)testCrossThreadAccess
{
    RLMRealm *realm = RLMRealm.defaultRealm;

    [self dispatchAsyncAndWait:^{
        XCTAssertThrows([realm beginWriteTransaction]);
        XCTAssertThrows([IntObject allObjectsInRealm:realm]);
        XCTAssertThrows([IntObject objectsInRealm:realm where:@"intCol = 0"]);
    }];
}

- (void)testHoldRealmAfterSourceThreadIsDestroyed {
    RLMRealm *realm;

    // Explicitly create a thread so that we can ensure the thread (and thus
    // runloop) is actually destroyed
    std::thread([&] { realm = [RLMRealm defaultRealm]; }).join();

    [realm.configuration fileURL]; // ensure ARC releases the object after the thread has finished
}

- (void)testBackgroundRealmIsNotified {
    RLMRealm *realm = [self realmWithTestPath];

    XCTestExpectation *bgReady = [self expectationWithDescription:@"background queue waiting for commit"];
    __block XCTestExpectation *bgDone = nil;

    [self dispatchAsync:^{
        RLMRealm *realm = [self realmWithTestPath];
        __block bool fulfilled = false;

        CFRunLoopPerformBlock(CFRunLoopGetCurrent(), kCFRunLoopDefaultMode, ^{
            __block RLMNotificationToken *token = [realm addNotificationBlock:^(NSString *note, RLMRealm *realm) {
                XCTAssertNotNil(realm, @"Realm should not be nil");
                XCTAssertEqual(note, RLMRealmDidChangeNotification);
                XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm].count);
                fulfilled = true;
                [token stop];
            }];

            // notify main thread that we're ready for it to commit
            [bgReady fulfill];
        });

        // run for two seconds or until we receive notification
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:5.0];
        while (!fulfilled) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:end];
        }
        XCTAssertTrue(fulfilled, @"Notification should have been received");

        [bgDone fulfill];
    }];

    // wait for background realm to be created
    [self waitForExpectationsWithTimeout:2.0 handler:nil];
    bgDone = [self expectationWithDescription:@"background queue done"];;

    [realm beginWriteTransaction];
    [StringObject createInRealm:realm withValue:@[@"string"]];
    [realm commitWriteTransaction];

    [self waitForExpectationsWithTimeout:2.0 handler:nil];
}

- (void)testAddingNotificationOutsideOfRunLoopIsAnError {
    [self dispatchAsyncAndWait:^{
        RLMRealm *realm = RLMRealm.defaultRealm;
        XCTAssertThrows([realm addNotificationBlock:^(NSString *, RLMRealm *) { }]);

        CFRunLoopPerformBlock(CFRunLoopGetCurrent(), kCFRunLoopDefaultMode, ^{
            RLMNotificationToken *token;
            XCTAssertNoThrow(token = [realm addNotificationBlock:^(NSString *, RLMRealm *) { }]);
            [token stop];
            CFRunLoopStop(CFRunLoopGetCurrent());
        });

        CFRunLoopRun();
    }];
}

#pragma mark - In-memory Realms

- (void)testInMemoryRealm {
    @autoreleasepool {
        RLMRealm *inMemoryRealm = [self inMemoryRealmWithIdentifier:@"identifier"];

        [self waitForNotification:RLMRealmDidChangeNotification realm:inMemoryRealm block:^{
            RLMRealm *inMemoryRealm = [self inMemoryRealmWithIdentifier:@"identifier"];
            [inMemoryRealm beginWriteTransaction];
            [StringObject createInRealm:inMemoryRealm withValue:@[@"a"]];
            [StringObject createInRealm:inMemoryRealm withValue:@[@"b"]];
            [StringObject createInRealm:inMemoryRealm withValue:@[@"c"]];
            XCTAssertEqual(3U, [StringObject allObjectsInRealm:inMemoryRealm].count);
            [inMemoryRealm commitWriteTransaction];
        }];

        XCTAssertEqual(3U, [StringObject allObjectsInRealm:inMemoryRealm].count);

        // make sure we can have another
        RLMRealm *anotherInMemoryRealm = [self inMemoryRealmWithIdentifier:@"identifier2"];
        XCTAssertEqual(0U, [StringObject allObjectsInRealm:anotherInMemoryRealm].count);
    }

    // Should now be empty
    RLMRealm *inMemoryRealm = [self inMemoryRealmWithIdentifier:@"identifier"];
    XCTAssertEqual(0U, [StringObject allObjectsInRealm:inMemoryRealm].count);
}

#pragma mark - Read-only Realms

- (void)testReadOnlyRealmWithMissingTables
{
    // create a realm with only a StringObject table
    @autoreleasepool {
        RLMObjectSchema *objectSchema = [RLMObjectSchema schemaForObjectClass:StringObject.class];
        objectSchema.objectClass = RLMObject.class;

        RLMSchema *schema = [[RLMSchema alloc] init];
        schema.objectSchema = @[objectSchema];
        RLMRealm *realm = [self realmWithTestPathAndSchema:schema];

        [realm beginWriteTransaction];
        [realm createObject:StringObject.className withValue:@[@"a"]];
        [realm commitWriteTransaction];
    }

    RLMRealm *realm = [self readOnlyRealmWithURL:RLMTestRealmURL() error:nil];
    XCTAssertEqual(1U, [StringObject allObjectsInRealm:realm].count);

    // verify that reading a missing table gives an empty array rather than
    // crashing
    RLMResults *results = [IntObject allObjectsInRealm:realm];
    XCTAssertEqual(0U, results.count);
    XCTAssertEqual(results, [results objectsWhere:@"intCol = 5"]);
    XCTAssertEqual(results, [results sortedResultsUsingKeyPath:@"intCol" ascending:YES]);
    XCTAssertThrows([results objectAtIndex:0]);
    XCTAssertEqual(NSNotFound, [results indexOfObject:self.nonLiteralNil]);
    XCTAssertEqual(NSNotFound, [results indexOfObjectWhere:@"intCol = 5"]);
    XCTAssertNoThrow([realm deleteObjects:results]);
    XCTAssertNil([results maxOfProperty:@"intCol"]);
    XCTAssertNil([results minOfProperty:@"intCol"]);
    XCTAssertNil([results averageOfProperty:@"intCol"]);
    XCTAssertEqualObjects(@0, [results sumOfProperty:@"intCol"]);
    XCTAssertNil([results firstObject]);
    XCTAssertNil([results lastObject]);
    for (__unused id obj in results) {
        XCTFail(@"Got an item in empty results");
    }
}

- (void)testReadOnlyRealmWithMissingColumns
{
    // create a realm with only a zero-column StringObject table
    @autoreleasepool {
        RLMObjectSchema *objectSchema = [RLMObjectSchema schemaForObjectClass:StringObject.class];
        objectSchema.objectClass = RLMObject.class;
        objectSchema.properties = @[];

        RLMSchema *schema = [[RLMSchema alloc] init];
        schema.objectSchema = @[objectSchema];
        [self realmWithTestPathAndSchema:schema];
    }

    XCTAssertThrows([self readOnlyRealmWithURL:RLMTestRealmURL() error:nil],
                    @"should reject table missing column");
}
#pragma mark - Write Copy to Path

- (void)testWriteCopyOfRealm
{
    RLMRealm *realm = [RLMRealm defaultRealm];
    [realm transactionWithBlock:^{
        [IntObject createInRealm:realm withValue:@[@0]];
    }];

    NSError *writeError;
    XCTAssertTrue([realm writeCopyToURL:RLMTestRealmURL() encryptionKey:nil error:&writeError]);
    XCTAssertNil(writeError);
    RLMRealm *copy = [self realmWithTestPath];
    XCTAssertEqual(1U, [IntObject allObjectsInRealm:copy].count);
}

- (void)testCannotOverwriteWithWriteCopy
{
    RLMRealm *realm = [self realmWithTestPath];
    [realm transactionWithBlock:^{
        [IntObject createInRealm:realm withValue:@[@0]];
    }];

    NSError *writeError;
    // Does not throw when given a nil error out param
    XCTAssertFalse([realm writeCopyToURL:RLMTestRealmURL() encryptionKey:nil error:nil]);

    NSString *expectedError = [NSString stringWithFormat:@"File at path '%@' already exists.", RLMTestRealmURL().path];
    NSString *expectedUnderlying = [NSString stringWithFormat:@"open(\"%@\") failed: file exists", RLMTestRealmURL().path];
    XCTAssertFalse([realm writeCopyToURL:RLMTestRealmURL() encryptionKey:nil error:&writeError]);
    RLMValidateRealmError(writeError, RLMErrorFileExists, expectedError, expectedUnderlying);
}

- (void)testCannotWriteInNonExistentDirectory
{
    RLMRealm *realm = [self realmWithTestPath];
    [realm transactionWithBlock:^{
        [IntObject createInRealm:realm withValue:@[@0]];
    }];

    NSString *badPath = @"/tmp/RLMTestDirMayNotExist/foo";

    NSString *expectedError = [NSString stringWithFormat:@"Directory at path '%@' does not exist.", badPath];
    NSString *expectedUnderlying = [NSString stringWithFormat:@"open(\"%@\") failed: no such file or directory", badPath];
    NSError *writeError;
    XCTAssertFalse([realm writeCopyToURL:[NSURL fileURLWithPath:badPath] encryptionKey:nil error:&writeError]);
    RLMValidateRealmError(writeError, RLMErrorFileNotFound, expectedError, expectedUnderlying);
}

- (void)testWriteToReadOnlyDirectory
{
    RLMRealm *realm = [RLMRealm defaultRealm];

    // Make the parent directory temporarily read-only
    NSString *directory = RLMTestRealmURL().URLByDeletingLastPathComponent.path;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSNumber *oldPermissions = [fm attributesOfItemAtPath:directory error:nil][NSFilePosixPermissions];
    [fm setAttributes:@{NSFilePosixPermissions: @(0100)} ofItemAtPath:directory error:nil];

    NSString *expectedError = [NSString stringWithFormat:@"Unable to open a Realm at path '%@'. Please use a path where your app has read-write permissions.", RLMTestRealmURL().path];
    NSString *expectedUnderlying = [NSString stringWithFormat:@"open(\"%@\") failed: permission denied", RLMTestRealmURL().path];
    NSError *writeError;
    XCTAssertFalse([realm writeCopyToURL:RLMTestRealmURL() encryptionKey:nil error:&writeError]);
    RLMValidateRealmError(writeError, RLMErrorFilePermissionDenied, expectedError, expectedUnderlying);

    // Restore old permissions
    [fm setAttributes:@{NSFilePosixPermissions: oldPermissions} ofItemAtPath:directory error:nil];
}

- (void)testWriteWithNonSpecialCasedError
{
    // Testing an open() error which doesn't have its own exception type and
    // just uses the generic "something failed" error
    RLMRealm *realm = [RLMRealm defaultRealm];

    // Set the max open files to zero so that opening new files will fail
    rlimit oldrl;
    getrlimit(RLIMIT_NOFILE, &oldrl);
    rlimit rl = oldrl;
    rl.rlim_cur = 0;
    setrlimit(RLIMIT_NOFILE, &rl);

    NSString *expectedError = [NSString stringWithFormat:@"Unable to open a Realm at path '%@': open() failed: too many open files",
                               RLMTestRealmURL().path];
    NSString *expectedUnderlying = [NSString stringWithFormat:@"open(\"%@\") failed: too many open files", RLMTestRealmURL().path];
    NSError *writeError;
    XCTAssertFalse([realm writeCopyToURL:RLMTestRealmURL() encryptionKey:nil error:&writeError]);
    RLMValidateRealmError(writeError, RLMErrorFileAccess, expectedError, expectedUnderlying);

    // Restore the old open file limit
    setrlimit(RLIMIT_NOFILE, &oldrl);
}

- (void)testWritingCopyUsesWriteTransactionInProgress
{
    RLMRealm *realm = [RLMRealm defaultRealm];
    [realm transactionWithBlock:^{
        [IntObject createInRealm:realm withValue:@[@0]];

        NSError *writeError;
        XCTAssertTrue([realm writeCopyToURL:RLMTestRealmURL() encryptionKey:nil error:&writeError]);
        XCTAssertNil(writeError);
        RLMRealm *copy = [self realmWithTestPath];
        XCTAssertEqual(1U, [IntObject allObjectsInRealm:copy].count);
    }];
}

#pragma mark - Assorted tests

- (void)testCoreDebug {
#if DEBUG
    XCTAssertTrue([RLMRealm isCoreDebug], @"Debug version of Realm should use librealm{-ios}-dbg");
#else
    XCTAssertFalse([RLMRealm isCoreDebug], @"Release version of Realm should use librealm{-ios}");
#endif
}

- (void)testIsEmpty {
    RLMRealm *realm = [RLMRealm defaultRealm];
    XCTAssertTrue(realm.isEmpty, @"Realm should be empty on creation.");

    [realm beginWriteTransaction];
    [StringObject createInRealm:realm withValue:@[@"a"]];
    XCTAssertFalse(realm.isEmpty, @"Realm should not be empty within a write transaction after adding an object.");
    [realm cancelWriteTransaction];

    XCTAssertTrue(realm.isEmpty, @"Realm should be empty after canceling a write transaction that added an object.");

    [realm beginWriteTransaction];
    [StringObject createInRealm:realm withValue:@[@"a"]];
    [realm commitWriteTransaction];
    XCTAssertFalse(realm.isEmpty, @"Realm should not be empty after committing a write transaction that added an object.");
}

- (void)testRealmFileAccessNilPath {
    RLMAssertThrowsWithReasonMatching([RLMRealm realmWithURL:self.nonLiteralNil],
                                      @"Realm path must not be empty", @"nil path");
}

- (void)testRealmFileAccessNoExistingFile
{
    NSURL *fileURL = [NSURL fileURLWithPath:RLMRealmPathForFile(@"filename.realm")];
    [[NSFileManager defaultManager] removeItemAtPath:fileURL.path error:nil];
    assert(![[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]);

    NSError *error;
    RLMRealmConfiguration *configuration = [RLMRealmConfiguration defaultConfiguration];
    configuration.fileURL = fileURL;
    XCTAssertNotNil([RLMRealm realmWithConfiguration:configuration error:&error],
                    @"Database should have been created");
    XCTAssertNil(error);
}

- (void)testRealmFileAccessInvalidFile
{
    NSString *content = @"Some content";
    NSData *fileContents = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *fileURL = [NSURL fileURLWithPath:RLMRealmPathForFile(@"filename.realm")];
    [[NSFileManager defaultManager] removeItemAtPath:fileURL.path error:nil];
    assert(![[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]);
    [[NSFileManager defaultManager] createFileAtPath:fileURL.path contents:fileContents attributes:nil];

    NSError *error;
    RLMRealmConfiguration *configuration = [RLMRealmConfiguration defaultConfiguration];
    configuration.fileURL = fileURL;
    XCTAssertNil([RLMRealm realmWithConfiguration:configuration error:&error], @"Invalid database");
    RLMValidateRealmError(error, RLMErrorFileAccess, @"Unable to open a realm at path", @"Realm file has bad size");
}

- (void)testRealmFileAccessFileIsDirectory
{
    NSURL *testURL = RLMTestRealmURL();
    [[NSFileManager defaultManager] createDirectoryAtPath:testURL.path
                              withIntermediateDirectories:NO
                                               attributes:nil
                                                    error:nil];
    NSError *error;
    RLMRealmConfiguration *configuration = [RLMRealmConfiguration defaultConfiguration];
    configuration.fileURL = testURL;
    XCTAssertNil([RLMRealm realmWithConfiguration:configuration error:&error], @"Invalid database");
    RLMValidateRealmError(error, RLMErrorFileAccess, @"Unable to open a realm at path", @"Is a directory");
}

#if TARGET_OS_TV
#else
- (void)testRealmFifoError
{
    NSFileManager *manager = [NSFileManager defaultManager];
    NSURL *testURL = RLMTestRealmURL();
    RLMRealmConfiguration *configuration = [RLMRealmConfiguration defaultConfiguration];
    configuration.fileURL = testURL;

    // Create the expected fifo URL and create a directory.
    // Note that creating a file when a directory with the same name exists produces a different errno, which is good.
    NSURL *fifoURL = [[testURL URLByDeletingPathExtension] URLByAppendingPathExtension:@"realm.note"];
    assert(![manager fileExistsAtPath:fifoURL.path]);
    [manager createDirectoryAtPath:fifoURL.path withIntermediateDirectories:YES attributes:nil error:nil];

    NSError *error;
    XCTAssertNil([RLMRealm realmWithConfiguration:configuration error:&error], @"Should not have been able to open FIFO");
    XCTAssertNotNil(error);
    RLMValidateRealmError(error, RLMErrorFileAccess, @"Is a directory", nil);
}
#endif

- (void)testMultipleRealms
{
    // Create one StringObject in two different realms
    RLMRealm *defaultRealm = [RLMRealm defaultRealm];
    RLMRealm *testRealm = self.realmWithTestPath;
    [defaultRealm beginWriteTransaction];
    [testRealm beginWriteTransaction];
    [StringObject createInRealm:defaultRealm withValue:@[@"a"]];
    [StringObject createInRealm:testRealm withValue:@[@"b"]];
    [testRealm commitWriteTransaction];
    [defaultRealm commitWriteTransaction];

    // Confirm that objects were added to the correct realms
    RLMResults *defaultObjects = [StringObject allObjectsInRealm:defaultRealm];
    RLMResults *testObjects = [StringObject allObjectsInRealm:testRealm];
    XCTAssertEqual(defaultObjects.count, 1U, @"Expecting 1 object");
    XCTAssertEqual(testObjects.count, 1U, @"Expecting 1 object");
    XCTAssertEqualObjects([defaultObjects.firstObject stringCol], @"a", @"Expecting column to be 'a'");
    XCTAssertEqualObjects([testObjects.firstObject stringCol], @"b", @"Expecting column to be 'b'");
}


- (void)testInvalidLockFile
{
    // Create the realm file and lock file
    @autoreleasepool { [RLMRealm defaultRealm]; }

    int fd = open([RLMRealmConfiguration.defaultConfiguration.fileURL.path stringByAppendingString:@".lock"].UTF8String, O_RDWR);
    XCTAssertNotEqual(-1, fd);

    // Change the value of the mutex size field in the shared info header
    uint8_t value = 255;
    pwrite(fd, &value, 1, 1);

    // Ensure that SharedGroup can't get an exclusive lock on the lock file so
    // that it can't just recreate it
    int ret = flock(fd, LOCK_SH);
    XCTAssertEqual(0, ret);

    NSError *error;
    RLMRealm *realm = [RLMRealm realmWithConfiguration:RLMRealmConfiguration.defaultConfiguration error:&error];
    XCTAssertNil(realm);
    RLMValidateRealmError(error, RLMErrorIncompatibleLockFile, @"Realm file is currently open in another process", nil);

    flock(fd, LOCK_UN);
    close(fd);
}

- (void)testCannotMigrateRealmWhenRealmIsOpen {
    RLMRealm *realm = [self realmWithTestPath];

    RLMRealmConfiguration *configuration = [RLMRealmConfiguration defaultConfiguration];
    configuration.fileURL = realm.configuration.fileURL;
    XCTAssertThrows([RLMRealm performMigrationForConfiguration:configuration error:nil]);
}

- (void)testNotificationPipeBufferOverfull {
    RLMRealm *realm = [self inMemoryRealmWithIdentifier:@"test"];
    // pipes have a 8 KB buffer on OS X, so verify we don't block after 8192 commits
    for (int i = 0; i < 9000; ++i) {
        [realm transactionWithBlock:^{}];
    }
}

- (void)testCompact
{
    RLMRealm *realm = self.realmWithTestPath;
    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSUInteger count = 1000;
    [realm transactionWithBlock:^{
        [StringObject createInRealm:realm withValue:@[@"A"]];
        for (NSUInteger i = 0; i < count; ++i) {
            [StringObject createInRealm:realm withValue:@[uuid]];
        }
        [StringObject createInRealm:realm withValue:@[@"B"]];
    }];
    auto fileSize = ^(NSString *path) {
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        return [(NSNumber *)attributes[NSFileSize] unsignedLongLongValue];
    };
    unsigned long long fileSizeBefore = fileSize(realm.configuration.fileURL.path);
    StringObject *object = [StringObject allObjectsInRealm:realm].firstObject;

    XCTAssertTrue([realm compact]);

    XCTAssertTrue(object.isInvalidated);
    XCTAssertEqual([[StringObject allObjectsInRealm:realm] count], count + 2);
    XCTAssertEqualObjects(@"A", [[StringObject allObjectsInRealm:realm].firstObject stringCol]);
    XCTAssertEqualObjects(@"B", [[StringObject allObjectsInRealm:realm].lastObject stringCol]);

    unsigned long long fileSizeAfter = fileSize(realm.configuration.fileURL.path);
    XCTAssertGreaterThan(fileSizeBefore, fileSizeAfter);
}

- (void)testCompactOnLaunch
{
    // Set up a Realm file with lots of space to compact
    NSUInteger count = 1000;
    @autoreleasepool {
        RLMRealm *realm = self.realmWithTestPath;
        NSString *uuid = [[NSUUID UUID] UUIDString];
        [realm transactionWithBlock:^{
            [StringObject createInRealm:realm withValue:@[@"A"]];
            for (NSUInteger i = 0; i < count; ++i) {
                [StringObject createInRealm:realm withValue:@[uuid]];
            }
            [StringObject createInRealm:realm withValue:@[@"B"]];
        }];
    }

    // Expected sizes
    // Note: These exact numbers are very sensitive to changes in core's allocator
    // and other internals unrelated to what this is testing, but it's probably useful
    // to know if they ever change, so it's preferable to have the test fail if these
    // exact numbers eventually change.
    NSUInteger expectedTotalBytesBefore = 655360;
    NSUInteger expectedUsedBytesBefore = 70144;
    NSUInteger expectedTotalBytesAfter = 73728;

    auto fileSize = ^(NSString *path) {
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        return [(NSNumber *)attributes[NSFileSize] unsignedLongLongValue];
    };

    // Configure the Realm to compact on launch
    RLMRealmConfiguration *configuration = [RLMRealmConfiguration defaultConfiguration];
    configuration.fileURL = RLMTestRealmURL();
    configuration.shouldCompactOnLaunchBlock = ^BOOL(NSUInteger totalBytes, NSUInteger usedBytes){
        // Confirm expected sizes
        XCTAssertEqual(totalBytes, expectedTotalBytesBefore);
        XCTAssertEqual(usedBytes, expectedUsedBytesBefore);

        // Compact if the file is over 500KB in size and less than 20% 'used'
        // In practice, users might want to use values closer to 100MB and 50%
        NSUInteger fiveHundredKB = 500 * 1024;
        return (totalBytes > fiveHundredKB) && (usedBytes / totalBytes) < 0.2;
    };

    // Confirm expected sizes before and after opening the Realm
    XCTAssertEqual(fileSize(configuration.fileURL.path), expectedTotalBytesBefore);
    RLMRealm *realm = [RLMRealm realmWithConfiguration:configuration error:nil];
    XCTAssertEqual(fileSize(configuration.fileURL.path), expectedTotalBytesAfter);

    // Validate that the file still contains what it should
    XCTAssertEqual([[StringObject allObjectsInRealm:realm] count], count + 2);
    XCTAssertEqualObjects(@"A", [[StringObject allObjectsInRealm:realm].firstObject stringCol]);
    XCTAssertEqualObjects(@"B", [[StringObject allObjectsInRealm:realm].lastObject stringCol]);
}

// TODO: Write docs
// TODO: Add test that underfull file doesn't compact
// TODO: Add test that unset block doesn't compact
// TODO: Add test that compact never gets called if there are cached Realms
// TODO: Add interprocess test
// TODO: Add Swift tests
// TODO: Figure out if we want to expose get_stats to users in general
// TODO: Validate that you can only set a block for writable, on-disk, non-synced Realms
// TODO: Can we detect if another process has a Realm open?

- (NSArray *)pathsFor100Realms
{
    NSMutableArray *paths = [NSMutableArray array];
    for (int i = 0; i < 100; ++i) {
        NSString *realmFileName = [NSString stringWithFormat:@"test.%d.realm", i];
        [paths addObject:RLMRealmPathForFile(realmFileName)];
    }
    return paths;
}

- (void)testCanCreate100RealmsWithoutBreakingGCD
{
    NSMutableArray *realms = [NSMutableArray array];
    for (NSString *realmPath in self.pathsFor100Realms) {
        [realms addObject:[RLMRealm realmWithURL:[NSURL fileURLWithPath:realmPath]]];
    }

    XCTestExpectation *expectation = [self expectationWithDescription:@"Block dispatched to concurrent queue should be executed"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [expectation fulfill];
    });
    [self waitForExpectationsWithTimeout:1 handler:nil];
}

@end
