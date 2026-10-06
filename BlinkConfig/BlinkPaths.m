////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2018 Blink Mobile Shell Project
//
// This file is part of Blink.
//
// Blink is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Blink is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Blink. If not, see <http://www.gnu.org/licenses/>.
//
// In addition, Blink is also subject to certain additional terms under
// GNU GPL version 3 section 7.
//
// You should have received a copy of these additional terms immediately
// following the terms and conditions of the GNU General Public License
// which accompanied the Blink Source Code. If not, see
// <http://www.github.com/blinksh/blink>.
//
////////////////////////////////////////////////////////////////////////////////

#import "BlinkPaths.h"
#import "XCConfig.h"

@implementation BlinkPaths

NSString *__homePath = nil;
NSString *__documentsPath = nil;
NSString *__groupContainerPath = nil;
NSString *__iCloudsDriveDocumentsPath = nil;

+ (NSString *)homePath {
  if (__homePath == nil) {
    __homePath = [[self groupContainerPath] stringByAppendingPathComponent:@"home"];
  }

  return __homePath;
}

+ (NSURL *)homeURL
{
  return [NSURL fileURLWithPath:[self homePath]];
}

+ (NSString *)documentsPath
{
  if (__documentsPath == nil) {
    __documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    // Linked and resolved files has prefix /private
    if (![__documentsPath hasPrefix:@"/private"]) {
      __documentsPath = [@"/private" stringByAppendingString:__documentsPath];
    }
  }
  return __documentsPath;
}

+ (NSString *)groupContainerPath {
  if (__groupContainerPath == nil) {

    NSString *groupID = [XCConfig infoPlistFullGroupID];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = [fm containerURLForSecurityApplicationGroupIdentifier:groupID].path;
    __groupContainerPath = path;
  }
  return __groupContainerPath;
}

+ (NSString *)iCloudDriveDocuments
{
  if (__iCloudsDriveDocumentsPath == nil) {
    NSString *iCloudID = [XCConfig infoPlistFullCloudID];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = [[fm URLForUbiquityContainerIdentifier:iCloudID] URLByAppendingPathComponent:@"Documents"].path;
    [self _ensureFolderAtPath:path];
    __iCloudsDriveDocumentsPath = path;
  }

  return __iCloudsDriveDocumentsPath;
}

+ (void)linkICloudDriveIfNeeded
{
  [self _linkAtPath:[[self homePath] stringByAppendingPathComponent:@"iCloud"]
    destinationPath:[self iCloudDriveDocuments]];
}

+ (void)linkDocumentsIfNeeded {
  [self _linkAtPath:[[self homePath] stringByAppendingPathComponent:@"Documents"]
    destinationPath:[self documentsPath]];
}

+ (void)_linkAtPath:(NSString *)path destinationPath:(NSString *)destinationPath {
  NSFileManager *fm = [NSFileManager defaultManager];
  
  // Don't use fileExists as that would traverse the symlink.
  if ([fm attributesOfItemAtPath:path error:nil]) {
    NSString *currentDestinationPath = [fm destinationOfSymbolicLinkAtPath:path error:nil];
    if (!currentDestinationPath) {
      return;
    }

    // We lost access. Remove that symlink.
    if (![fm isReadableFileAtPath: currentDestinationPath]) {
      [fm removeItemAtPath: path error: nil];
    } else {
      return;
    }
  }
  NSError *error = nil;

  BOOL ok = [fm createSymbolicLinkAtPath:path
                     withDestinationPath:destinationPath
                                   error:&error];

  if (!ok) {
    NSLog(@"Error: %@", error);
  };
}

+ (NSString *)blink {
  NSString *dotBlink = [[self homePath] stringByAppendingPathComponent:@".blink"];
  [self _ensureFolderAtPath:dotBlink];
  return dotBlink;
}

+ (NSString *)blinkBuild {
  NSString *dotBlinkBuild = [[self homePath] stringByAppendingPathComponent:@".blink-build"];
  [self _ensureFolderAtPath:dotBlinkBuild];
  return dotBlinkBuild;
}


+ (NSString *)ssh {
  NSString *dotSSH = [[self homePath] stringByAppendingPathComponent:@".ssh"];
  [self _ensureFolderAtPath:dotSSH];
  return dotSSH;
}

+ (NSString *)blinkAgentSettings {
  NSString *path = [[self blink] stringByAppendingPathComponent:@"agents"];
  [self _ensureFolderAtPath:path];
  return path;
}

+ (void)_ensureFolderAtPath:(NSString *)path {
  BOOL isDir = NO;
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:path isDirectory:&isDir]) {
    if (isDir) {
      return;
    }

    [fm removeItemAtPath:path error:nil];
  }
  [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{} error:nil];
}


+ (NSURL *)blinkURL
{
  return [NSURL fileURLWithPath:[self blink]];
}

+ (NSURL *)blinkBuildURL
{
  return [NSURL fileURLWithPath:[self blinkBuild]];
}

+ (NSURL *)blinkBuildTokenURL
{
  NSString *url = [self blinkBuild];
  return [NSURL fileURLWithPath:[url stringByAppendingPathComponent:@".build.token"]];
}

+ (NSURL *)blinkBuildStagingMarkURL
{
  NSString *url = [self blinkBuild];
  return [NSURL fileURLWithPath:[url stringByAppendingPathComponent:@".staging"]];
}

+ (NSURL *)blinkAgentSettingsURL
{
  return [NSURL fileURLWithPath:[self blinkAgentSettings]];
}

+ (NSURL *)sshURL
{
  return [NSURL fileURLWithPath:[self ssh]];
}

+ (NSString *)blinkKeysFile
{
  return [[self blink] stringByAppendingPathComponent:@"keys"];
}

+ (NSURL *)blinkKBConfigURL
{
  return [[self blinkURL] URLByAppendingPathComponent:@"kb.json"];
}

+ (NSString *)blinkHostsFile
{
  return [[self blink] stringByAppendingPathComponent:@"hosts"];
}

+ (NSURL *)blinkGlobalSSHConfigFileURL
{
  return [[self blinkURL] URLByAppendingPathComponent:@"ssh_global"];
}

+ (NSURL *)blinkSSHConfigFileURL
{
  return [[self blinkURL] URLByAppendingPathComponent:@"ssh_config"];
}


+ (NSString *)blinkSyncItemsFile
{
  return [[self blink] stringByAppendingPathComponent:@"syncItems"];
}

+ (NSString *)blinkProfileFile
{
  return [[self blink] stringByAppendingPathComponent:@"profile"];
}

+ (NSString *)historyFile
{
  return [[self blink] stringByAppendingPathComponent:@"history.txt"];
}

+ (NSURL *)historyURL
{
  return [NSURL fileURLWithPath:[self historyFile]];
}

+ (NSURL *)localSnippetsLocationURL
{
  return [NSURL fileURLWithPath:[[self documentsPath] stringByAppendingPathComponent:@"snips"]];
}

+ (NSURL *)iCloudSnippetsLocationURL {
  NSString *path = [self iCloudDriveDocuments];
  if (path) {
    return [NSURL fileURLWithPath:[path stringByAppendingPathComponent:@"snips"]];
  }
  return nil;
}

+ (NSURL *)fileProviderReplicatedURL {
  NSString *fileProviderPath = [[self groupContainerPath] stringByAppendingPathComponent:@"FileProviderReplicated"];
  [self _ensureFolderAtPath:fileProviderPath];
  return [NSURL fileURLWithPath:fileProviderPath];
}

+ (NSString *)knownHostsFile
{
  return [[self ssh] stringByAppendingPathComponent:@"known_hosts"];
}

// ---------------------------------------------------------------------------
// 内置信任的公用机器主机密钥（known_hosts 行格式：<host> <keytype> <base64>）
// ---------------------------------------------------------------------------
// 来由：App 装在手机上连 brain(47.237.122.99) 这类公用机器时，libssh 判
// SSH_KNOWN_HOSTS_UNKNOWN → 弹「The server is unknown. Do you trust the host key? [Y/n]: 」
// 并阻塞等输入（SSHConfigProvider.cliVerifyHostCallback → device.readline），
// 而 MCPSession 的 12 秒连接看门狗到点就把会话掐了（_armConnectWatchdogFor:）——
// 用户根本来不及按 Y，紧接着自动重连再来一遍，成死循环。
// 把公钥预置进应用私有容器的 known_hosts 后，libssh 直接判 KNOWN，确认框不再出现。
//
// 【同一台机器要把**所有**在用的密钥类型都写上】libssh 对「主机在册、但密钥类型不同」
// 返回 SSH_KNOWN_HOSTS_OTHER，SSHClient.swift 里走的是 .changed 分支 —— 照样弹框，
// 而且是更吓人的「REMOTE IDENTIFICATION HAS CHANGED」。所以 brain 的 ed25519 / ecdsa /
// rsa 三条都列上（三种它都提供）。
//
// 新增机器：`ssh-keyscan -t ed25519,ecdsa,rsa <host>`，逐行照抄；非 22 端口写成 [host]:port。
static NSArray<NSString *> *BlinkSeedKnownHosts(void) {
  return @[
    @"47.237.122.99 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBMcHcSSJgQRoP5pzj27QoSEssXmQymYG44vaTMUd+k5",
    @"47.237.122.99 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOQ/TURBwDaCzg6YeuAFgalzoyfIsb8KVwsB1dVNKdw+AcW5A66WPyh8E9wa1dcVuVpw5LHGPf3iUGY3PuM+mVk=",
    @"47.237.122.99 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCquWQ7hyz7LhY1OWLZGpoEokwjKeQVEEjqnWCKw1uvyE/4RrWBIMG5sk6tJhoxXsREW5aLf7CkwkWKE2Vvsk9QXDzYd+YG8rMl5RwWxQy93mNsEn+QSp2ZtUIJ3aVoWviQG+sABoZV2WUITrk/WFCWGmy/6I30lZXbuniJkbC55pdnDEkvDdbJilkpKyAxCHMAzcuDbpUHNPgkr6knNmKvnRqrXinbH539eZY3LLx5Szfipqq+4+GFWmvAiJ+yE0artRrnXj0V5bAZJAQJmyKZVWjRrF0nLizZPTx99aRrbUK9AAve0vhR0HpVIfVf8SARmZN96V60txH4QLLEhWVoKHxe1RaS2pmeuKneCdL3hhBt7ISgnxx4v6SFMP8yZvxMZ/PFxnaS8h5zF1gX6SKu0BQcT3n7RroeDd1vpEW2UNJ/9N7oaxUrRgJrozyoAD4NHnxMQfvHwBt/YaleDEhhYLB84TIvBIQWPCKZ8u71pr+oj4m0a5DbZ8Cs81uopyc=",
  ];
}

// 把上面几条补进 known_hosts：只补「这台机器 + 这个密钥类型」还没有的，其余一个字节不动。
// 已存在就跳过是有意为之 —— 真有哪天密钥换了，得让 libssh 判 CHANGED 弹框问人（安全默认），
// 不能由 App 悄悄替用户改信任。
+ (void)ensureSeededKnownHosts {
  NSString *path = [self knownHostsFile];
  NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] ?: @"";

  NSMutableSet<NSString *> *seen = [NSMutableSet set];  // "host keytype"
  for (NSString *line in [existing componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
    if ([line hasPrefix:@"#"] || [line hasPrefix:@"@"]) { continue; }  // 注释 / @cert-authority 等标记行
    NSMutableArray<NSString *> *fields = [NSMutableArray array];
    for (NSString *f in [line componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
      if (f.length > 0) { [fields addObject:f]; }
    }
    // 只看前两列：第三列是密钥本体，比对它没意义（那正是要能被新密钥顶掉的）
    if (fields.count >= 2) { [seen addObject:[NSString stringWithFormat:@"%@ %@", fields[0], fields[1]]]; }
  }

  NSMutableString *add = [NSMutableString string];
  for (NSString *entry in BlinkSeedKnownHosts()) {
    NSArray<NSString *> *f = [entry componentsSeparatedByString:@" "];
    if ([seen containsObject:[NSString stringWithFormat:@"%@ %@", f[0], f[1]]]) { continue; }
    [add appendFormat:@"%@\n", entry];
  }
  if (add.length == 0) { return; }

  NSMutableString *merged = existing.length ? [existing mutableCopy] : [NSMutableString string];
  if (merged.length > 0 && ![merged hasSuffix:@"\n"]) { [merged appendString:@"\n"]; }
  [merged appendString:add];
  [merged writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

+ (NSString *)blinkDefaultsFile
{
  return [[self blink] stringByAppendingPathComponent:@"defaults"];
}

+ (NSURL *)fileProviderErrorLogURL
{
  return [[self blinkURL] URLByAppendingPathComponent:@"fileprovider.log"];
}

+ (NSURL *)blinkCodeErrorLogURL
{
  return [[self blinkURL] URLByAppendingPathComponent:@"blinkCode.log"];
}

@end
