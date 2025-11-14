#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <Foundation/NSUserDefaults+Private.h>
#include <unistd.h>
#include <substrate.h>
#include <rootless.h>
#include <spawn.h>
#include <sys/types.h>
#include <pwd.h>
#include <errno.h>
#include <string.h>

extern char **environ;

#define LOG(fmt, ...) NSLog(@"[XcodeRootDebug] " fmt "\n", ##__VA_ARGS__)

static NSString * nsDomainString = @"com.byteage.xcoderootdebug";
static NSString * nsNotificationString = @"com.byteage.xcoderootdebug/preferences.changed";
static BOOL enabled;
static NSString *debugserverPath;
static BOOL isRootUser;
static BOOL isRemotedProcess = NO;

static void reloadSettings() {
	NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:ROOT_PATH_NS(@"/var/mobile/Library/Preferences/com.byteage.xcoderootdebug.plist")];
	NSNumber * enabledValue = (NSNumber *)[settings objectForKey:@"enabled"];
	enabled = (enabledValue)? [enabledValue boolValue] : YES;
	debugserverPath = [settings objectForKey:@"debugserverPath"];
	if(!debugserverPath.length) {
		debugserverPath = ROOT_PATH_NS(@"/usr/bin/debugserver");
	}
	NSNumber * isRootUserValue = (NSNumber *)[settings objectForKey:@"isRootUser"];
	isRootUser = (isRootUserValue)? [isRootUserValue boolValue] : YES;
}

static void notificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	// kill self
	exit(0);
}

// If the compiler understands __arm64e__, assume it's paired with an SDK that has
// ptrauth.h. Otherwise, it'll probably error if we try to include it so don't.
#if __arm64e__
#include <ptrauth.h>
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"

// Given a pointer to instructions, sign it so you can call it like a normal fptr.
static void *make_sym_callable(void *ptr) {
#if __arm64e__
    ptr = ptrauth_sign_unauthenticated(ptrauth_strip(ptr, ptrauth_key_function_pointer), ptrauth_key_function_pointer, 0);
#endif
    return ptr;
}

// Given a function pointer, strip the PAC so you can read the instructions.
static void *make_sym_readable(void *ptr) {
#if __arm64e__
    ptr = ptrauth_strip(ptr, ptrauth_key_function_pointer);
#endif
    return ptr;
}

#pragma clang diagnostic pop

typedef CFTypeRef AuthorizationRef;

bool (*original_SMJobSubmit)(CFStringRef domain, CFDictionaryRef job, AuthorizationRef auth, CFErrorRef _Nullable *error);

static NSString *systemDebugserverPath;

bool hooked_SMJobSubmit(CFStringRef domain, CFDictionaryRef job, AuthorizationRef auth, CFErrorRef _Nullable *error) {
	LOG(@"Enter hooked_SMJobSubmit %@", job);
	NSMutableDictionary *newJobInfo = [NSMutableDictionary dictionaryWithDictionary:(__bridge NSDictionary *)job];
	NSMutableArray *programArgs = [newJobInfo[@"ProgramArguments"] mutableCopy];
	NSString *program = programArgs[0];
	if (enabled) {
		if([program isEqualToString:@"/Developer/usr/bin/debugserver"] || [program isEqualToString:@"/usr/libexec/debugserver"]) {
			LOG("Found launch %@", program);
			systemDebugserverPath = [program copy];
			if(debugserverPath.length > 0 && access(debugserverPath.UTF8String, F_OK) == 0){
				LOG("Change to launch %@", debugserverPath);
				programArgs[0] = debugserverPath;
				newJobInfo[@"ProgramArguments"] = programArgs;
			} else {
				LOG("Debug Server does not exist at %@", debugserverPath);
			}
			if(isRootUser) {
				LOG("Change to launch with root");
				newJobInfo[@"UserName"] = @"root";
			} else {
				newJobInfo[@"UserName"] = @"mobile";
			}
			LOG(@"Now SMJobSubmit %@", newJobInfo);
		} else if([program isEqualToString:debugserverPath]) {
			LOG("Found launch %@",debugserverPath);
			if(isRootUser) {
				LOG("Change to launch with root");
				newJobInfo[@"UserName"] = @"root";
			} else {
				newJobInfo[@"UserName"] = @"mobile";
			}
			LOG(@"Now SMJobSubmit %@", newJobInfo);
		}
	} else {
		if([program isEqualToString:debugserverPath]) {
			LOG("Found launch %@", debugserverPath);
			LOG("Restore launch system debugserver at %@ with mobile", systemDebugserverPath);
			programArgs[0] = systemDebugserverPath;
			newJobInfo[@"ProgramArguments"] = programArgs;
			newJobInfo[@"UserName"] = @"mobile";
			LOG(@"Now SMJobSubmit %@", newJobInfo);
		}
	}
	LOG(@"New SMJobSubmit %@", newJobInfo);
	return original_SMJobSubmit(domain, (__bridge CFDictionaryRef)newJobInfo, auth, error);
}

// Helper function to check if a path is a debugserver
static BOOL isDebugserverPath(const char *path) {
    if (path == NULL) return NO;
    NSString *pathStr = [NSString stringWithUTF8String:path];
    return [pathStr hasSuffix:@"/debugserver"];
}

// Helper function to redirect debugserver path
static const char* getRedirectedDebugserverPath(const char *originalPath) {
    if (!enabled || !debugserverPath || debugserverPath.length == 0) {
        return originalPath;
    }
    
    if (access(debugserverPath.UTF8String, F_OK) != 0) {
        LOG(@"Custom debugserver not found at: %@", debugserverPath);
        return originalPath;
    }
    
    NSString *origPath = [NSString stringWithUTF8String:originalPath];
    if ([origPath isEqualToString:debugserverPath]) {
        return originalPath; // Already using custom
    }
    
    if (!systemDebugserverPath) {
        systemDebugserverPath = [origPath copy];
        LOG(@"Saved system debugserver path: %@", systemDebugserverPath);
    }
    
    LOG(@"Redirecting from %@ to %@", origPath, debugserverPath);
    return debugserverPath.UTF8String;
}

// posix_spawn hook for iOS 17+ CoreDevice framework compatibility
// This catches debugserver launches from remoted process
int (*original_posix_spawn)(pid_t *restrict pid, const char *restrict path,
                           const posix_spawn_file_actions_t *restrict file_actions,
                           const posix_spawnattr_t *restrict attrp,
                           char *const argv[restrict],
                           char *const envp[restrict]);

int hooked_posix_spawn(pid_t *restrict pid, const char *restrict path,
                      const posix_spawn_file_actions_t *restrict file_actions,
                      const posix_spawnattr_t *restrict attrp,
                      char *const argv[restrict],
                      char *const envp[restrict]) {
    if (path == NULL || argv == NULL || argv[0] == NULL) {
        return original_posix_spawn(pid, path, file_actions, attrp, argv, envp);
    }
    
    // Check if this is a debugserver launch
    if (!isDebugserverPath(path)) {
        return original_posix_spawn(pid, path, file_actions, attrp, argv, envp);
    }
    
    LOG(@"posix_spawn debugserver: %s", path);
    
    const char *newPath = getRedirectedDebugserverPath(path);
    
    if (newPath == path) {
        // No redirection needed
        return original_posix_spawn(pid, path, file_actions, attrp, argv, envp);
    }
    
    // Create new argv with modified path
    int argc = 0;
    while (argv[argc] != NULL) argc++;
    
    char **newArgv = (char **)malloc((argc + 1) * sizeof(char *));
    newArgv[0] = (char *)newPath;
    for (int i = 1; i < argc; i++) {
        newArgv[i] = argv[i];
    }
    newArgv[argc] = NULL;
    
    int result = original_posix_spawn(pid, newPath, file_actions, attrp, newArgv, envp);
    
    if (result == 0 && pid != NULL) {
        LOG(@"Successfully spawned custom debugserver (PID: %d)", *pid);
    } else if (result != 0) {
        LOG(@"Failed to spawn debugserver: %d (%s)", result, strerror(result));
    }
    
    free(newArgv);
    return result;
}

// execve hook as fallback/alternative
int (*original_execve)(const char *path, char *const argv[], char *const envp[]);

int hooked_execve(const char *path, char *const argv[], char *const envp[]) {
    if (!isDebugserverPath(path)) {
        return original_execve(path, argv, envp);
    }
    
    LOG(@"execve debugserver: %s", path);
    
    const char *newPath = getRedirectedDebugserverPath(path);
    
    if (newPath == path) {
        // No redirection needed
        return original_execve(path, argv, envp);
    }
    
    // Create new argv with modified path
    int argc = 0;
    if (argv) {
        while (argv[argc] != NULL) argc++;
    }
    
    char **newArgv = (char **)malloc((argc + 1) * sizeof(char *));
    newArgv[0] = (char *)newPath;
    for (int i = 1; i < argc; i++) {
        newArgv[i] = argv[i];
    }
    newArgv[argc] = NULL;
    
    int result = original_execve(newPath, newArgv, envp);
    
    // Note: execve doesn't return on success, only on error
    LOG(@"execve failed: %d (%s)", errno, strerror(errno));
    
    free(newArgv);
    return result;
}

%ctor {
  const char *processName = getprogname();
  LOG(@"loaded in %s (%d)", processName, getpid());
  
  // Detect which process we're running in
  if (strcmp(processName, "dtdebugproxyd") == 0) {
    LOG(@"Detected dtdebugproxyd process - iOS 17+ debug proxy (THIS IS THE RIGHT ONE!)");
  } else if (strcmp(processName, "remoted") == 0) {
    isRemotedProcess = YES;
    LOG(@"Detected remoted process - iOS 17+ CoreDevice mode");
  } else if (strcmp(processName, "lockdownd") == 0) {
    LOG(@"Detected lockdownd process - legacy mode");
  }
  
  reloadSettings();

  CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, notificationCallback, (CFStringRef)nsNotificationString, NULL, CFNotificationSuspensionBehaviorCoalesce);

  // Hook SMJobSubmit for lockdownd (iOS < 17)
  MSImageRef image = MSGetImageByName("/System/Library/PrivateFrameworks/ServiceManagement.framework/ServiceManagement");
  if (image) {
    void *smJobSubmit = MSFindSymbol(image, "_SMJobSubmit");
    if (smJobSubmit) {
      MSHookFunction(
        smJobSubmit,
        (void *)hooked_SMJobSubmit,
        (void **)&original_SMJobSubmit
      );
      LOG(@"Successfully hooked SMJobSubmit");
    } else {
      LOG(@"SMJobSubmit symbol not found");
    }
  } else {
    LOG(@"ServiceManagement framework not found");
  }
  
  // Hook posix_spawn for both lockdownd and remoted (universal hook for iOS 17+)
  // This will catch debugserver launches from any process
  void *posix_spawn_ptr = MSFindSymbol(NULL, "_posix_spawn");
  if (posix_spawn_ptr) {
    MSHookFunction(
      posix_spawn_ptr,
      (void *)hooked_posix_spawn,
      (void **)&original_posix_spawn
    );
    LOG(@"Successfully hooked posix_spawn");
  } else {
    LOG(@"posix_spawn symbol not found");
  }
  
  // Hook execve as well (some processes may use this instead)
  void *execve_ptr = MSFindSymbol(NULL, "_execve");
  if (execve_ptr) {
    MSHookFunction(
      execve_ptr,
      (void *)hooked_execve,
      (void **)&original_execve
    );
    LOG(@"Successfully hooked execve");
  } else {
    LOG(@"execve symbol not found");
  }
  
  LOG(@"XcodeRootDebug initialization complete (enabled=%d, debugserverPath=%@, isRootUser=%d)", enabled, debugserverPath, isRootUser);
}
