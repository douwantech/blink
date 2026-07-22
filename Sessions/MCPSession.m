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

#include <stdio.h>
#include <string.h>
#include <libgen.h>
#include <sys/stat.h>
#include <dispatch/dispatch.h>

#import "MCPSession.h"
#import "MoshSession.h"
#import "BKPubKey.h"
#import "SSHCopyIDSession.h"
#import "SSHSession.h"
#import "BlinkdSession.h"

#import "BKUserConfigurationManager.h"
#import "BlinkPaths.h"

#include <ios_system/ios_system.h>

#include "ios_error.h"
#include "Blink-Swift.h"


@implementation MCPSession {
  NSString * _sessionUUID;
  Session *_childSession;
  NSString *_currentCmd;
  NSMutableArray *_sshClients;
//  dispatch_queue_t _cmdQueue;
  dispatch_queue_t _sshQueue;
  TermStream *_cmdStream;
  NSString *_currentCmdLine;
  NSString *_autoConnectCommand;   // 自动发起的 ssh 命令，断开后据此重连
  int _reconnectAttempts;          // 连续快速重连计数（连上够久会清零）
  BOOL _autoConnectMachineBased;   // YES=按机器重连（每次重新解析 host）；NO=固定命令
  BOOL _sawConnect;                // 本次连接尝试是否已连上（喂给看门狗）
  BOOL _reconnectPending;          // 已排了一次重连（退避 delay 窗口内），避免重复重连
}

// 断线自动重连开关，默认开（key 没设过当作开）
static BOOL BlinkAutoReconnectEnabled(void) {
  id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"BlinkAutoReconnect"];
  return v == nil ? YES : [v boolValue];
}

@dynamic sessionParams;

- (id)initWithDevice:(TermDevice *)device andParams:(MCPParams *)params {
  if (self = [super initWithDevice:device andParams:params]) {
    _sshClients = [[NSMutableArray alloc] init];
    _sessionUUID = [[NSProcessInfo processInfo] globallyUniqueString];
    _cmdQueue = dispatch_queue_create("mcp.command.queue", DISPATCH_QUEUE_SERIAL);
    _sshQueue = dispatch_queue_create("mcp.sshclients.queue", DISPATCH_QUEUE_SERIAL);
    [self setActiveSession];
    device.readlineListener = self;

    NSString *initialPrompt = [WhatsNewInfo mustDisplayInitialPrompt];
    if (initialPrompt) {
      [device writeOutLn:initialPrompt];
    }
  }

  return self;
}

- (void)executeWithArgs:(NSString *)args {
  dispatch_async(_cmdQueue, ^{
    [self setActiveSession];
    ios_setStreams(_stream.in, _stream.out, _stream.out);

    NSString *homePath = [BlinkPaths homePath];
    ios_setMiniRoot(homePath);
    [self updateAllowedPaths];

    // We are restoring mosh session if possible first.
    if ([@"mosh" isEqualToString:self.sessionParams.childSessionType] && self.sessionParams.hasEncodedState) {
      MoshParams *moshParams = (MoshParams *)self.sessionParams.childSessionParams;

      BlinkMosh *mosh = [[BlinkMosh alloc] initWithMcpSession: self device:_device andParams:moshParams];
      _childSession = mosh;
      [_childSession executeAttachedWithArgs:@""];
      _childSession = nil;
      if (self.sessionParams.hasEncodedState) {
        return;
      }
    }
    if ([@"mosh1" isEqualToString:self.sessionParams.childSessionType] && self.sessionParams.hasEncodedState) {
      MoshSession *mosh = [[MoshSession alloc] initWithDevice:_device andParams:self.sessionParams.childSessionParams];
      mosh.mcpSession = self;
      _childSession = mosh;
      [_childSession executeAttachedWithArgs:@""];
      _childSession = nil;
      if (self.sessionParams.hasEncodedState) {
        return;
      }
    }
    NSString *initialCommand = self.sessionParams.initialCommand;
    if (initialCommand.length > 0) {
      // 拉记录等一次性命令不参与自动重连；只有 ssh/mosh 这类连接命令才记为自动重连目标
      NSString *trimmedInit = [initialCommand stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if ([trimmedInit hasPrefix:@"ssh "] || [trimmedInit hasPrefix:@"mosh "]) {
        _autoConnectCommand = initialCommand;
        _autoConnectMachineBased = NO;   // 固定命令，重连原样重跑
      }
      [self enqueueCommand:initialCommand];
      return;
    }
    #if TARGET_OS_MACCATALYST
      BKHosts *localhost = [BKHosts withHost:@"localhost"];
      if (localhost) {
        NSString *sshcmd = [NSString stringWithFormat: @"ssh -A %@", localhost.host];
        [self enqueueCommand:sshcmd];
      } else {
        [_device prompt:@"blink> " secure:NO shell:YES];
      }
    #else
    if (_device) {
      [Migrator setupAutoSSHKey];
      if ([BlinkMachineStore.shared hasAnyMachine]) {
        NSString *machineId = self.sessionParams.machineId;
        if (![BlinkMachineStore.shared machineExistsForId:machineId]) {
          machineId = BlinkMachineStore.shared.currentMachineId;
          self.sessionParams.machineId = machineId;
        }
        // 开了「用 blinkd」就走 blinkd 传输(不走 SSH,绕 MDM);没开或没配 blinkd 主机则回退 ssh
        NSString *cmd = [BlinkMachineStore.shared blinkdCommandForMachineId:machineId workDirId:self.sessionParams.workDirId tmuxSession:self.sessionParams.tmuxSession useTmux:self.sessionParams.useTmux];
        if (cmd.length == 0) {
          cmd = [BlinkMachineStore.shared sshCommandForMachineId:machineId workDirId:self.sessionParams.workDirId tmuxSession:self.sessionParams.tmuxSession useTmux:self.sessionParams.useTmux];
        }
        if (cmd) {
          NSString *hostInfo = [BlinkMachineStore.shared chosenHostInfoForMachineId:machineId];
          if (hostInfo) {
            [_device writeOutLn:hostInfo];
          }
          _autoConnectCommand = cmd;   // 记为自动重连目标
          _autoConnectMachineBased = YES;   // 重连时按机器重新解析 host（LAN 坏了自动降级外网）
          [self enqueueCommand:cmd];
        } else {
          [_device prompt:@"blink> " secure:NO shell:YES];
        }
      } else {
        [_device prompt:@"还没有机器，先在弹出的页面添加 → " secure:NO shell:YES];
        [BlinkMachineStore presentAddMachineIfNeeded];
      }
    }
    #endif
  });
}

- (void)enqueueCommand:(NSString *)cmd {
  [self enqueueCommand:cmd skipHistoryRecord:NO];
}

- (void)enqueueCommand:(NSString *)cmd skipHistoryRecord: (BOOL) skipHistoryRecord {
  // NOTE This shouldn't be done this way. The MCP should read from, but not write to the input.
  // The terminal device in this case is acting like a shell, which is not fully wrong, but I don't like it.
  // The terminal view is also receiving requests for "what's being typed" in order to then do Completion, etc...
  if (_cmdStream) {
    [_device writeInDirectly:[NSString stringWithFormat: @"%@\n", cmd]];
    return;
  }
  dispatch_async(_cmdQueue, ^{
    self->_currentCmdLine = cmd;
    [self _runCommand:cmd skipHistoryRecord:skipHistoryRecord];
    self->_currentCmdLine = nil;
  });
}

- (BOOL)_runCommand:(NSString *)cmdline skipHistoryRecord: (BOOL) skipHistoryRecord {

  cmdline = [cmdline stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  NSDate *cmdStart = [NSDate date];

  // 自动连接命令：重置「已连上」标志并起看门狗，卡在建连阶段就杀掉重连
  BOOL isAutoConnect = (_autoConnectCommand.length > 0 && [cmdline isEqualToString:_autoConnectCommand]);
  if (isAutoConnect) {
    _sawConnect = NO;
    [self _armConnectWatchdogFor:cmdline];
  }

  if (!skipHistoryRecord) {
    [HistoryObj appendIfNeededWithCommand:cmdline];
  }
  
  NSString *mayBeURLString = [cmdline stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  
  NSURL *mayBeHttpURL = [NSURL URLWithString:mayBeURLString];
  NSString *scheme = mayBeHttpURL.scheme.lowercaseString;
  if ([@"http" isEqual: scheme] || [@"https" isEqual:scheme]) {
    cmdline = [NSString stringWithFormat:@"browse %@", mayBeURLString];
  }
  
  // 命令派发用「trim 后按空白切分出的第一个非空 token」。原来直接取
  // componentsSeparatedByString:@" " 的 [0]，遇到结尾 \r、Tab、前导/多重空格会把首词算错——
  // blinkd 重连命令首词一旦不等于字面 "blinkd"，就会被丢给下面的 ios_system 分支，
  // 打印 "blinkd: command not found" 并立即退出 → 满足 willReconnect → 死循环刷屏。
  NSString *cmd = @"";
  for (NSString *t in [cmdline componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
    if (t.length > 0) { cmd = t; break; }
  }

  if ([cmd isEqualToString:@"exit"]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.delegate sessionFinished];
    });
    
    return NO;
  }
  
  // NOTE We don't have a passthrough for all of it.
  // This should be done at a different function
  setenv("LC_ALL", "UTF-8", 1);
  setenv("LC_CTYPE", "UTF-8", 1);
  setlocale(LC_ALL, "UTF-8");
  setlocale(LC_CTYPE, "UTF-8");
  
  if ([cmd isEqualToString:@"mosh"]) {
    [self _runMoshWithArgs:cmdline];
    if (self.sessionParams.hasEncodedState) {
      return NO;
    }
  } else if ([cmd isEqualToString:@"mosh1"]) {
    [self _runMosh1WithArgs:cmdline];
    if (self.sessionParams.hasEncodedState) {
      return NO;
    }
  } else if ([cmd isEqualToString:@"ssh2"]) {
    [self _runSSHWithArgs:cmdline];
  } else if ([cmd isEqualToString:@"blinkd"]) {
    [self _runBlinkdWithArgs:cmdline];
  } else if ([cmd isEqualToString:@"ssh-copy-id"]) {
    [self _runSSHCopyIDWithArgs:cmdline];
  } else if (![cmd isEqualToString:@""]) {
    // Manually set raw mode for some commands, as we cannot receive control any other way.
    [_device closeReadline];
    if ([cmd isEqualToString:@"less"] || [cmd isEqualToString:@"vim"]) {
      self.device.rawMode = true;
      self.device.autoCR = TRUE;
    }
    [self setActiveSession];
    [self updateAllowedPaths];

    _currentCmd = cmdline;

    _cmdStream = [_device.stream duplicate];
    ios_setStreams(_cmdStream.in, _cmdStream.out, _cmdStream.out);
    // ios_system provides a get command that returns a "tty" instead of an open.  We can control it here.
    FILE* tty = [_cmdStream openTTY];
    ios_settty(tty);
    ios_setWindowSize((int)self.device.cols, (int)self.device.rows, _sessionUUID.UTF8String);

    pid_t _pid = ios_fork();
    ios_system(cmdline.UTF8String);
    _currentCmd = nil;
    ios_waitpid(_pid);
    ios_releaseThreadId(_pid);
    self.device.autoCR = FALSE;

    fclose(tty);
    tty = nil;
    [_cmdStream close];
    _cmdStream = nil;
    _sshClients = [[NSMutableArray alloc] init];

    setenv("LC_ALL", "UTF-8", 1);
    setenv("LC_CTYPE", "UTF-8", 1);
    setlocale(LC_ALL, "UTF-8");
    setlocale(LC_CTYPE, "UTF-8");
  }
  
  // 断线自动重连：刚退出的是自动 ssh 连接命令 && 开关打开 → 延迟后重跑（tmux 会 attach 回原会话）
  BOOL willReconnect = (_device
                        && _autoConnectCommand.length > 0
                        && [cmdline isEqualToString:_autoConnectCommand]
                        && BlinkAutoReconnectEnabled());
  if (willReconnect) {
    // 连上够久(>=15s)才退，说明是中途掉线，重连计数清零；否则是连不上，累加用于退避
    if (-[cmdStart timeIntervalSinceNow] >= 15.0) {
      _reconnectAttempts = 0;
    }
    [self _scheduleReconnect];
    return YES;
  }

  if (_device) {
    // TODO At the moment this is just a prompt instead of a readline. This needs to be fixed.
    // And bc of that, we need to check that there is a device. The MCP may be killed, but the loop here may still
    // try to write to the device.
    [_device prompt:@"blink> " secure:NO shell:YES];
  }

  return YES;
}

// 连接成功回调（ssh.swift 在连上后调）：喂给看门狗，标记本次尝试已连上
- (void)sshClientDidConnect {
  _sawConnect = YES;
}

// 按机器重新生成 ssh 命令（重新解析 host：LAN 坏了自动降级外网/tailscale）；非机器型返回原命令
- (NSString *)_freshAutoConnectCommand {
  if (!_autoConnectMachineBased) {
    return _autoConnectCommand;
  }
  NSString *machineId = self.sessionParams.machineId;
  if (![BlinkMachineStore.shared machineExistsForId:machineId]) {
    machineId = BlinkMachineStore.shared.currentMachineId;
  }
  NSString *cmd = [BlinkMachineStore.shared blinkdCommandForMachineId:machineId
                                                            workDirId:self.sessionParams.workDirId
                                                          tmuxSession:self.sessionParams.tmuxSession
                                                              useTmux:self.sessionParams.useTmux];
  if (cmd.length == 0) {
    cmd = [BlinkMachineStore.shared sshCommandForMachineId:machineId
                                                 workDirId:self.sessionParams.workDirId
                                               tmuxSession:self.sessionParams.tmuxSession
                                                   useTmux:self.sessionParams.useTmux];
  }
  return cmd.length > 0 ? cmd : _autoConnectCommand;
}

// 连接看门狗：起 ssh 后 12s 内若还没连上、且 ssh 仍在跑（卡在建连/认证阶段）→ 杀掉，触发重连。
// Blink 的 ssh 建连超时是坏的（阻塞 runloop，定时器不触发），会无限假死，靠这个兜住。
- (void)_armConnectWatchdogFor:(NSString *)cmdline {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (!self->_device) { return; }
    // 已连上 → 放行；ssh 已退出(_sshClients 空) → 交给正常退出流程；否则卡住 → 杀
    if (self->_sawConnect) { return; }
    __block NSUInteger clientCount = 0;
    dispatch_sync(self->_sshQueue, ^{ clientCount = self->_sshClients.count; });
    if (clientCount == 0) { return; }
    if (![cmdline isEqualToString:self->_autoConnectCommand]) { return; }  // 已经换了命令
    [self->_device writeOutLn:@"\r\n\033[33m⚠️ 连接卡住（12s 没连上），重连中…\033[0m"];
    dispatch_sync(self->_sshQueue, ^{
      for (id client in self->_sshClients) { [client kill]; }
    });
    // kill 后 ssh 命令会退出，走 _runCommand 尾部 → 自动重连（会重新解析 host）
  });
}

// 延迟重跑自动 ssh 命令；每次重新解析 host + 清可达性缓存；失败越快退避越久(3→6→9…最多 15s)
- (void)_scheduleReconnect {
  _reconnectPending = YES;
  int attempt = ++_reconnectAttempts;
  double delay = MIN(3.0 * attempt, 15.0);
  if (_device) {
    [_device writeOutLn:[NSString stringWithFormat:
      @"\r\n\033[33m⚠️ 连接断开，%.0f 秒后自动重连（第 %d 次）… 关闭：设置→断线自动重连\033[0m", delay, attempt]];
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _cmdQueue, ^{
    self->_reconnectPending = NO;
    // 重连前再判一次：设备还在、开关仍开
    if (!self->_device) {
      return;
    }
    if (!BlinkAutoReconnectEnabled() || self->_autoConnectCommand.length == 0) {
      [self->_device prompt:@"blink> " secure:NO shell:YES];
      return;
    }
    // 清可达性缓存并重新解析 host（不再用 30s 陈旧缓存里的坏 LAN）
    [BlinkMachineStore.shared invalidateHostReachabilityCache];
    self->_autoConnectCommand = [self _freshAutoConnectCommand];
    self->_currentCmdLine = self->_autoConnectCommand;
    [self _runCommand:self->_autoConnectCommand skipHistoryRecord:YES];
    self->_currentCmdLine = nil;
  });
}

// 切到这台机器/这个 tab 时调：若当前没有活的 ssh（掉线后停在 blink> 或后台没重连上）
// 且没有已排队的重连 → 立刻重连。有 ssh 在跑（含正在建连）则什么都不做。
- (void)reconnectIfDisconnected {
  if (!_device) { return; }
  if (!BlinkAutoReconnectEnabled() || _autoConnectCommand.length == 0) { return; }
  if (_reconnectPending) { return; }
  // blinkd/mosh 等子会话活着时不算掉线。它们是 _childSession，从不进 _sshClients，
  // 只看 _sshClients 会把「blinkd 正连着」误判成掉线，每次切 tab 都重连一次。
  if (_childSession) { return; }
  __block NSUInteger clientCount = 0;
  dispatch_sync(_sshQueue, ^{ clientCount = self->_sshClients.count; });
  if (clientCount > 0) { return; }   // 已有 ssh 在跑/在连，别打断
  _reconnectPending = YES;
  [_device writeOutLn:@"\r\n\033[36m↻ 重新连接…\033[0m"];
  dispatch_async(_cmdQueue, ^{
    self->_reconnectPending = NO;
    if (!self->_device) { return; }
    __block NSUInteger n = 0;
    dispatch_sync(self->_sshQueue, ^{ n = self->_sshClients.count; });
    if (n > 0) { return; }   // 排队期间已经连上了
    [BlinkMachineStore.shared invalidateHostReachabilityCache];
    self->_autoConnectCommand = [self _freshAutoConnectCommand];
    self->_currentCmdLine = self->_autoConnectCommand;
    [self _runCommand:self->_autoConnectCommand skipHistoryRecord:YES];
    self->_currentCmdLine = nil;
  });
}

- (int)main:(int)argc argv:(char **)argv
{
  return 0;
}

- (void)registerSSHClient:(id __weak)sshClient {
  dispatch_sync(_sshQueue, ^(void){
    [_sshClients addObject:sshClient];
  });
}

- (void)unregisterSSHClient:(id __weak)sshClient {
  dispatch_sync(_sshQueue, ^(void){
    [_sshClients removeObject:sshClient];
  });
}

- (bool)isRunningCmd {
  return _childSession != nil || _currentCmd != nil || _currentCmdLine != nil;
}


- (void)updateAllowedPaths
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableArray<NSString *> *allowedPaths = [[NSMutableArray alloc] init];
  NSString *documentsPath = [BlinkPaths documentsPath];
  NSString *iCloudDriveDocumentsPath = [BlinkPaths iCloudDriveDocuments];

  if (documentsPath != NULL) {
    [allowedPaths addObject: documentsPath];
    NSString *resolvedPath = [fm destinationOfSymbolicLinkAtPath:[BlinkPaths documentsPath] error:nil];
    if (resolvedPath != NULL) {
      [allowedPaths addObject: resolvedPath];
    }
  }

  if (iCloudDriveDocumentsPath != NULL) {
    [allowedPaths addObject: iCloudDriveDocumentsPath];
    NSString *resolvedPath = [fm destinationOfSymbolicLinkAtPath:[BlinkPaths iCloudDriveDocuments] error:nil];
    if (resolvedPath != NULL) {
      [allowedPaths addObject: iCloudDriveDocumentsPath];
    }
  }

  NSArray<NSString *> *allowedLocations = [[BookmarkedLocationsManager default] getLocationPaths];
  for (NSString *path in allowedLocations) {
    char resolvedPath[PATH_MAX];
    if (realpath([path fileSystemRepresentation], resolvedPath)) {
      NSString *stringResolvingPath = [NSString stringWithUTF8String:resolvedPath];
      [allowedPaths addObject: stringResolvingPath];
    } else {
      [allowedPaths addObject:path];
    }
  }

  // ios_setAllowedPaths 会 objc_storeStrong 到 ios_system 的进程级全局 allowedPaths，本身不是
  // 线程安全的。多个会话各自在自己的 _cmdQueue 上重连时会并发调它（executeWithArgs / _runCommand），
  // 两个线程同时 storeStrong 会把旧值 double-release → EXC_BAD_ACCESS（栈里两条 mcp.command.queue
  // 线程同崩在 ios_setAllowedPaths）。用共享的 Class 作锁把这次写全局串行化。
  @synchronized ([MCPSession class]) {
    ios_setAllowedPaths(allowedPaths);
  }
}

- (void)_runSSHCopyIDWithArgs:(NSString *)args
{
  self.sessionParams.childSessionParams = nil;
  _childSession = [[SSHCopyIDSession alloc] initWithDevice:_device andParams:self.sessionParams.childSessionParams];
  self.sessionParams.childSessionType = @"sshcopyid";
  
  // duplicate args
  NSString *str = [NSString stringWithFormat:@"%@", args];
  [_childSession executeAttachedWithArgs:str];

  _childSession = nil;
}

- (void)_runMoshWithArgs:(NSString *)args
{
  self.sessionParams.childSessionParams = [[MoshParams alloc] init];
  self.sessionParams.childSessionType = @"mosh";
  BlinkMosh *mosh = [[BlinkMosh alloc] initWithMcpSession: self device:_device andParams:self.sessionParams.childSessionParams];
  //MoshSession *mosh = [[MoshSession alloc] initWithDevice:_device andParams:self.sessionParams.childSessionParams];
  //mosh.mcpSession = self;
  _childSession = mosh;
  
  // duplicate args
  NSString *str = [NSString stringWithFormat:@"%@", args];
  [_childSession executeAttachedWithArgs:str];
  
  _childSession = nil;
}

- (void)_runMosh1WithArgs:(NSString *)args
{
  self.sessionParams.childSessionParams = [[MoshParams alloc] init];
  self.sessionParams.childSessionType = @"mosh1";
  //BlinkMosh *mosh = [[BlinkMosh alloc] initWithMcpSession: self device:_device andParams:self.sessionParams.childSessionParams];
  MoshSession *mosh = [[MoshSession alloc] initWithDevice:_device andParams:self.sessionParams.childSessionParams];
  mosh.mcpSession = self;
  _childSession = mosh;
  
  // duplicate args
  NSString *str = [NSString stringWithFormat:@"%@", args];
  [_childSession executeAttachedWithArgs:str];
  
  _childSession = nil;
}

- (void)_runSSHWithArgs:(NSString *)args
{
  self.sessionParams.childSessionParams = nil;
  _childSession = [[SSHSession alloc] initWithDevice:_device andParams:self.sessionParams.childSessionParams];
  self.sessionParams.childSessionType = @"ssh";
  [_childSession executeAttachedWithArgs:args];
  _childSession = nil;
}

// blinkd <host> <port> <token> — 原始 TCP 连 Mac 端 blinkd daemon(不走 SSH)
- (void)_runBlinkdWithArgs:(NSString *)args
{
  // 只有「真建连」的 blinkd 调用才登记自动重连;管理子命令(save/ls/rm/help)不登记,
  // 否则断线重连会把 `blinkd ls` 之类反复重跑。掉线重连复用 ssh 那套退避+看门狗,
  // 受 设置→断线自动重连 开关(BlinkAutoReconnectEnabled)控制;daemon 已就绪回放,
  // 重连即恢复画面。别名会在每次重跑时重新解析(host/token 换了也跟得上)。
  NSArray *parts = [args componentsSeparatedByString:@" "];
  NSString *sub = parts.count > 1 ? parts[1] : @"";
  BOOL isMgmt = (sub.length == 0
                 || [sub isEqualToString:@"save"] || [sub isEqualToString:@"ls"]
                 || [sub isEqualToString:@"rm"]   || [sub isEqualToString:@"help"]
                 || [sub isEqualToString:@"-h"]   || [sub isEqualToString:@"--help"]);
  if (!isMgmt) {
    _autoConnectCommand = args;
    _autoConnectMachineBased = NO;
  }
  self.sessionParams.childSessionParams = nil;
  _childSession = [[BlinkdSession alloc] initWithDevice:_device andParams:self.sessionParams.childSessionParams];
  self.sessionParams.childSessionType = @"blinkd";
  [_childSession executeAttachedWithArgs:args];
  _childSession = nil;
}

- (void)sigwinch
{
  [self setActiveSession];
  ios_setWindowSize((int)self.device.cols, (int)self.device.rows, _sessionUUID.UTF8String);
  
  [_childSession sigwinch];
  dispatch_sync(_sshQueue, ^{
    for (id client in _sshClients) {
      [client sigwinch];
    }
  });
}

// TODO It would be nice if this could be re-used (interrupt children, interrupt yourself).
- (void)kill
{
  if (_sshClients.count > 0) {
    dispatch_sync(_sshQueue, ^{
      for (id client in _sshClients) {
        [client kill];
      }
    });
    
    return;
  } else if (_childSession) {
    [_childSession kill];
  } else if (_cmdStream) {
    [self setActiveSession];
    ios_kill();
  }
  
  ios_closeSession(_sessionUUID.UTF8String);
  [_device close];
  _device = NULL;
}

- (void)suspend
{
  [self setActiveSession];
  [_childSession suspend];
}

- (void)handleControl:(NSString *)control
{
  NSString *ctrlC = @"\x03";
  NSString *ctrlD = @"\x04";
  
  if (_childSession) {
    if (_sshClients.count > 0) {
      dispatch_sync(_sshQueue, ^{
        for (id client in _sshClients) {
          // TODO We need the kill here because of the Proxy connections, but if we simplify, SSH will just be a
          // regular child session.
          [client kill];
        }
      });
    } else {
      // Send kill signal to child session.
      [_childSession kill];
    }
    return;
  } else if (_currentCmd) {
    if ([control isEqualToString:ctrlD]) {
      // We give a chance to the session to capture the new stdin, as it may have changed.
      [self setActiveSession];
      if (_cmdStream != NULL) {
        [_cmdStream close];
        _cmdStream = NULL;
        _cmdStream = [_device.stream duplicate];
      }
      ios_setStreams(_cmdStream.in, _cmdStream.out, _cmdStream.out);
      return;
    }
    
    if ([control isEqualToString:ctrlC]) {
      if (_sshClients.count > 0) {
        dispatch_sync(_sshQueue, ^{
          for (id client in _sshClients) {
            [client kill];
          }
        });
      } else {
        if (_tokioSignals) {
          [_tokioSignals signalCtrlC];
          _tokioSignals = nil;
        } else {
          [self setActiveSession];
          ios_kill();
        }
      }
      return;
    }
  }

  return;
}

- (void)setActiveSession {
  // Need to reset all thread variables, including context!
  // This fixes "segmentation faults" after a few subsequent session - new command cycles.
  thread_context = NULL;
  ios_switchSession(_sessionUUID.UTF8String);
  ios_setContext((__bridge void*)self);
  thread_stdout = NULL;
  thread_stdin = NULL;
  thread_stderr = NULL;
  _currentActiveMCP = self;
}

static __weak MCPSession *_currentActiveMCP = nil;

+ (MCPSession *)currentActive {
  return _currentActiveMCP;
}

- (void)switchToMachineId:(NSString *)machineId workDirId:(NSString *)workDirId tmuxSession:(NSString *)tmuxSession {
  if (!_device) { return; }
  self.sessionParams.machineId = machineId;
  self.sessionParams.workDirId = workDirId;
  self.sessionParams.tmuxSession = tmuxSession;
  BOOL useTmux = self.sessionParams.useTmux;
  [self setActiveSession];
  if (_sshClients.count > 0) {
    dispatch_sync(_sshQueue, ^{
      for (id client in _sshClients) {
        [client kill];
      }
    });
  } else if (_childSession) {
    [_childSession kill];
  } else if (_cmdStream) {
    ios_kill();
  }
  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf || !strongSelf->_device) { return; }
    NSString *cmd = [BlinkMachineStore.shared sshCommandForMachineId:machineId workDirId:workDirId tmuxSession:tmuxSession useTmux:useTmux];
    if (cmd) {
      NSString *hostInfo = [BlinkMachineStore.shared chosenHostInfoForMachineId:machineId];
      if (hostInfo) {
        [strongSelf->_device writeOutLn:hostInfo];
      }
      [strongSelf enqueueCommand:cmd];
    }
  });
}

- (void)lineSubmitted:(NSString *)line {
  [self enqueueCommand:line];
}

@end
