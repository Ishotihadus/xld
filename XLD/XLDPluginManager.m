//
//  XLDPluginManager.m
//  XLD
//
//  Created by tmkk on 11/08/18.
//  Copyright 2011 tmkk. All rights reserved.
//

#import "XLDPluginManager.h"
#import "XLDCustomClasses.h"
#import <sys/xattr.h>
#import <dirent.h>

static void removeQuarantine(NSString *path, BOOL isDir)
{
	if(isDir) {
		DIR *dir = opendir([path UTF8String]);
		if(!dir) return;
		struct dirent *file = NULL;
		while(file = readdir(dir)) {
			if(!strcmp(file->d_name, ".") || !strcmp(file->d_name, "..")) continue;
			NSString *newPath = [path stringByAppendingPathComponent:[NSString stringWithUTF8String:file->d_name]];
			//NSLog(@"%@",newPath);
			removeQuarantine(newPath, file->d_type == DT_DIR);
		}
		closedir(dir);
	}
	removexattr([path UTF8String], "com.apple.quarantine", 0);
}

@implementation XLDPluginManager

- (id)init
{
	[super init];
	plugins = [[NSMutableArray alloc] init];
	NSMutableDictionary *internalPlugins = [[NSMutableDictionary alloc] init];
	NSMutableDictionary *externalPlugins = [[NSMutableDictionary alloc] init];
	
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray *bundleArr = [fm directoryContentsAt:[@"~/Library/Application Support/XLD/PlugIns" stringByExpandingTildeInPath]];
	int i;
	NSBundle *bundle = nil;
	
	for(i=0;i<[bundleArr count];i++) {
		BOOL isDir = NO;
		NSString *bundlePath = [[@"~/Library/Application Support/XLD/PlugIns" stringByExpandingTildeInPath] stringByAppendingPathComponent:[bundleArr objectAtIndex:i]];
		if([fm fileExistsAtPath:bundlePath isDirectory:&isDir] && isDir && [[bundlePath pathExtension] isEqualToString:@"bundle"]) {
			if(getxattr([bundlePath UTF8String], "com.apple.quarantine", NULL, 0, 0, 0) > 0)
				removeQuarantine(bundlePath, YES);
			bundle = [NSBundle bundleWithPath:bundlePath];
			if(bundle) {
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5
				NSArray *archArray = [bundle executableArchitectures];
#if defined(__x86_64__)
				if([archArray indexOfObject:@(NSBundleExecutableArchitectureX86_64)] == NSNotFound) continue;
#elif defined(__i386__)
				if([archArray indexOfObject:@(NSBundleExecutableArchitectureI386)] == NSNotFound) continue;
#elif defined(__ppc__)
				if([archArray indexOfObject:@(NSBundleExecutableArchitecturePPC)] == NSNotFound) continue;
#elif defined(__aarch64__)
				if([archArray indexOfObject:@(NSBundleExecutableArchitectureARM64)] == NSNotFound) continue;
#endif
#endif
				if(![[bundle infoDictionary] objectForKey:@"NSPrincipalClass"]) continue;
				[externalPlugins setObject:bundlePath forKey:[[bundle infoDictionary] objectForKey:@"NSPrincipalClass"]];
				//NSLog(@"%@",[[bundle infoDictionary] description]);
				//NSLog(@"loaded:%d",[bundle isLoaded]);
			}
		}
	}
	
	bundleArr = [fm directoryContentsAt:[[NSBundle mainBundle] builtInPlugInsPath]];
	for(i=0;i<[bundleArr count];i++) {
		BOOL isDir = NO;
		NSString *bundlePath = [[[NSBundle mainBundle] builtInPlugInsPath] stringByAppendingPathComponent:[bundleArr objectAtIndex:i]];
		if([fm fileExistsAtPath:bundlePath isDirectory:&isDir] && isDir && [[bundlePath pathExtension] isEqualToString:@"bundle"]) {
			bundle = [NSBundle bundleWithPath:bundlePath];
			if(bundle) {
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5
				NSArray *archArray = [bundle executableArchitectures];
#if defined(__x86_64__)
				if([archArray indexOfObject:@(NSBundleExecutableArchitectureX86_64)] == NSNotFound) continue;
#elif defined(__i386__)
				if([archArray indexOfObject:@(NSBundleExecutableArchitectureI386)] == NSNotFound) continue;
#elif defined(__ppc__)
				if([archArray indexOfObject:@(NSBundleExecutableArchitecturePPC)] == NSNotFound) continue;
#elif defined(__aarch64__)
				if([archArray indexOfObject:@(NSBundleExecutableArchitectureARM64)] == NSNotFound) continue;
#endif
#endif
				if(![[bundle infoDictionary] objectForKey:@"NSPrincipalClass"]) continue;
				if([externalPlugins objectForKey:[[bundle infoDictionary] objectForKey:@"NSPrincipalClass"]]) continue;
				[internalPlugins setObject:bundlePath forKey:[[bundle infoDictionary] objectForKey:@"NSPrincipalClass"]];
				//NSLog(@"%@",[[bundle infoDictionary] objectForKey:@"NSPrincipalClass"]);
				//NSLog(@"loaded:%d",[bundle isLoaded]);
			}
		}
	}
	
	/* Prefer external plugins over internal ones */
	[plugins addObjectsFromArray:[[externalPlugins allValues] sortedArrayUsingSelector:@selector(compare:)]];
	[plugins addObjectsFromArray:[[internalPlugins allValues] sortedArrayUsingSelector:@selector(compare:)]];
	
	[internalPlugins release];
	[externalPlugins release];
	
	//NSLog(@"%@",[plugins description]);
	
	return self;
}

- (void)dealloc
{
	[plugins release];
	[super dealloc];
}

- (NSArray *)plugins
{
	return plugins;
}

@end
