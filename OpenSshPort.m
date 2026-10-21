#import <Preferences/PSSpecifier.h>
#import <Preferences/PSViewController.h>
#import <Preferences/PSListController.h>
#import <objc/runtime.h>

#import <Preferences/PSEditableTableCell.h>
#import <Preferences/PSSwitchTableCell.h>

#include <dlfcn.h>
#include <sys/types.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>
#include <string.h>
#include <stdarg.h>

static const char * const fp_ssw = "SSHswitch";
static const char * const jbroot = "/var/jb"; // fallback root directory path.
static const char * fp_sss = NULL;

static uint8_t openSshPortAllowedPorts = 8;
static unsigned long openSshPortHasPorts = 0; // port count -1. For if we come from an earlier version which didn't have the limits

// pass the full environment to SSHswitch. Has an env var like 
// XPC_SERVICE_NAME=UIKitApplication:com.apple.Preferences[....][rb-legacy]
// XPC_SERVICE_NAME=UIKitApplication:com.apple.Preferences[0x....][...]
// Possibly for the future, so SSHswitch might know it's being called from Preferences, detect OpenSshPort version or something something.
extern char **environ;

#pragma mark static functions

// This probably isn't sending anything on arm64e devices on iOS14 if built with Xcode11
static void 
bhLogOSP(NSString *format, ...){
	va_list argp;
	va_start(argp, format);
	NSLogv([NSString stringWithFormat:@"%.4f u.blanxd.opensshport %@", ([[NSDate date] timeIntervalSince1970] * 1000.0)/1000, format], argp);
	va_end(argp);
}

// https://stackoverflow.com/a/5337804/5610645 or from elsewhere...
static _Bool 
sys_ver_ge(NSString *v){
	return [[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending ? 1 : 0;
}

// 1:exists, 0:don't exist
static _Bool 
osp_file_exist(const char *path) {
	if ( access( path, F_OK ) != -1 ){
		return 1;
	}
	return 0;
}

// return 0 if file contains the string, 1 otherwise. -1 on error.
static int 
osp_grepq(const char *path, const char *str){

	FILE *file = fopen ( path, "r" );
	if ( file != NULL ){
// an expected longest line we can find in com.openssh.sshd.plist
//		<string>/usr/libexec/sshd-keygen-wrapper</string>
		char line [ 64 ]; /* or other suitable maximum line size */
		char *s;
		while ( fgets ( line, sizeof line, file ) != NULL ){ /* read a line */
			s = strstr(line, str);
			if ( s != NULL ){
				fclose ( file );
				return 0;
			}
		}
		fclose ( file );
	} else return -1;
	return 1;
}

static _Bool 
osp_sameports( NSString* ports1, NSString* ports2 ) {

	// https://stackoverflow.com/questions/24331566/objective-c-sort-an-array-of-strings-containing-numbers
	NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"intValue" ascending:YES];

	NSArray* p1 = [ports1 componentsSeparatedByString:@","];
	NSArray* p2 = [ports2 componentsSeparatedByString:@","];
	if ( [ [p1 sortedArrayUsingDescriptors:@[sortDescriptor]] 
			isEqualToArray:
			[p2 sortedArrayUsingDescriptors:@[sortDescriptor]]
		] ){
		return 1;
	}
	return 0;
}

static _Bool 
osp_okports(NSString* portString) {
	NSArray* ports = [portString componentsSeparatedByString:@","];
	if ( [ports indexOfObjectPassingTest:^(NSString* obj, NSUInteger idx, BOOL *stop){
			NSInteger intVal = [obj integerValue];
			if ( intVal > 65535 || (intVal < 1001 && intVal != 22) || intVal==1080 || intVal==1083 || intVal==8021 || intVal==62078 ){
				*stop = YES;
				return YES;
			}
			return NO;
		}] == NSNotFound ){
		return 1;
	}
	return 0;
}

// worker (reader)
// the caller should actually check the length of err (providing an empty one) because the return value can be from either SSHswitch or from here.
static int 
osp_switch_read( const char *swargs[], uint8_t arglen, NSMutableString* output, NSMutableString* err ){

	// ok, so I was using popen() for years, for easily getting any output from cli programs.
	// It probably just calls `/bin/sh -c "command here"' so this doesn't work in rootless environments, need to go with a straight thing ie. posix_spawn().

	int status = -1;
	posix_spawn_file_actions_t action;
	int pipes[2];
	char read_err[14] = {0};
	if ( pipe(pipes) == -1 ){ // make the pipe
		bhLogOSP(@"switch_read ERROR: pipe");
		strlcpy(read_err,"pipe",14);
	} else if ( posix_spawn_file_actions_init(&action) != 0 ){ // make the actions
		bhLogOSP(@"switch_read ERROR: actions_init");
		strlcpy(read_err,"actions_init",14);
	} else if ( posix_spawn_file_actions_addclose(&action, pipes[0]) != 0 ){ // close the stdin in SSHswitch
		bhLogOSP(@"switch_read ERROR: actions_addclose");
		strlcpy(read_err,"addclose",14);
	} else if ( posix_spawn_file_actions_adddup2(&action, pipes[1], 1) != 0 ){ // take the stdout from SSHswitch
		bhLogOSP(@"switch_read ERROR: actions_adddup2");
		strlcpy(read_err,"adddup2",14);
	} else if ( posix_spawn_file_actions_addopen(&action, STDERR_FILENO, "/dev/null", O_RDONLY, 0) != 0 ){ // send its stderr to the black hole, we'll create msgs to the `syslog' anyway
		bhLogOSP(@"switch_read ERROR: STDERR_FILENO>/dev/null");
		strlcpy(read_err,"STDERR_FILENO",14);
	} else {

		pid_t pid;
		const char *args[arglen+2];
		args[0] = fp_ssw;
		for ( uint8_t ai=0; ai<arglen; ai++ ){
			args[ai+1] = swargs[ai];
		}
		args[arglen+1] = NULL;

		status = posix_spawn(&pid, fp_sss, &action, NULL, (char* const*)args, environ);
		if (status == 0) {
			close(pipes[1]); // might not be necessary really
			FILE *file = fdopen(pipes[0], "r");
			if (!file){
				bhLogOSP(@"switch_read ERROR: fdopen(pipes[0], 'r') (pid:%d)", pid);
				strlcpy(read_err,"fdopen",14);
			} else {

				char *data = NULL;
				size_t linecap = 0;
				while ( getline(&data, &linecap, file) > 0 ){
					[output appendString:[NSString stringWithUTF8String:data]];
				}
				fclose(file);

				if (waitpid(pid,&status,0) != -1) {
					if ( WIFEXITED(status) != 0 ){
						status = WEXITSTATUS(status); // should be either 0=OK, or 0=On/1=Off, or 0=haveSessions/1=noSessions.
						if ( status < 0 || status > 9 ){
							bhLogOSP(@"switch_read ERROR: %s returned %d", fp_ssw, status);
							strlcpy(read_err,"WEXITSTATUS",14);
						}
					} else {
						bhLogOSP(@"switch_read ERROR: WIFEXITED(status) = 0 (pid:%d)", pid);
						strlcpy(read_err,"WIFEXITED",14);
					}
				} else {
					bhLogOSP(@"switch_read ERROR: waitpid(%d,&status,0) = -1", pid);
					strlcpy(read_err,"waitpid",14);
				}
			}
		} else {
			bhLogOSP(@"switch_read ERROR: posix_spawn()=%d:%s", status, strerror(status));
			strlcpy(read_err,"posix_spawn",14);
		}

	}
	posix_spawn_file_actions_destroy(&action);

	if ( read_err[0] != '\0' ){
		[err setString:[NSString stringWithFormat:@"%s", read_err]];
	}

	return status;

} // static int osp_switch_read( const char *swargs[], uint8_t arglen, NSMutableString* output, NSMutableString* err ){

// worker
static void 
osp_switch_simple(const char* opt) {
	posix_spawn_file_actions_t action;
	posix_spawn_file_actions_init(&action);
	posix_spawn_file_actions_addopen (&action, STDOUT_FILENO, "/dev/null", O_RDONLY, 0);
	posix_spawn_file_actions_addopen (&action, STDERR_FILENO, "/dev/null", O_RDONLY, 0);

	pid_t pid;
	const char *args[] = {fp_ssw, opt, NULL};
	int status;
	status = posix_spawn(&pid, fp_sss, &action, NULL, (char* const*)args, environ);
	if (status == 0) {
		// so all this is for debug only, don't care really here
		if (waitpid(pid,&status,0) != -1) {
			if ( WIFEXITED(status) != 0 ){
//bhLogOSP(@"switch_simple WIFEXITED(status) = %d (OK?), WEXITSTATUS(status) = %d", WIFEXITED(status), WEXITSTATUS(status)); //// debug
			} else {
				bhLogOSP(@"switch_simple(%s) ERROR: WIFEXITED(status) = 0 (pid:%d)", opt, pid);
			}
		} else {
			bhLogOSP(@"switch_simple(%s) ERROR: waitpid(%d,&status,0) = -1", opt, pid);
		}
	} else {
		bhLogOSP(@"switch_simple(%s) ERROR: posix_spawn() = %d - %s", opt, status, strerror(status));
	}
	posix_spawn_file_actions_destroy(&action);
} // static void osp_switch_simple(const char* opt) {

// worker
static void 
osp_switch_onoff(uint8_t older, _Bool onoff, NSString* nport, NSNumber* ar, NSNumber* ap, NSNumber* ak, NSNumber* gl, int8_t kickem){
	posix_spawn_file_actions_t action;
	posix_spawn_file_actions_init(&action);
	posix_spawn_file_actions_addopen (&action, STDOUT_FILENO, "/dev/null", O_RDONLY, 0);
	posix_spawn_file_actions_addopen (&action, STDERR_FILENO, "/dev/null", O_RDONLY, 0);

	pid_t pid;
	int status = 1;

	const char *args[] = {
		fp_ssw, // 0
		onoff==1 ? "on" : "of", // 1
		nport==NULL ? "-" : [nport UTF8String], // 2
		[[NSString stringWithFormat:@"a%@", ar==NULL?@"-":[ar stringValue]] UTF8String], // 3
		[[NSString stringWithFormat:@"w%@", ap==NULL?@"-":[ap stringValue]] UTF8String], // 4
		[[NSString stringWithFormat:@"u%@", ak==NULL?@"-":[ak stringValue]] UTF8String], // 5
		kickem==1 ? "k1" : (kickem==0 ? "k0" : "k-"), // 6
		[[NSString stringWithFormat:@"g%@", gl==NULL?@"-":[gl stringValue]] UTF8String], // 7, SSHswitch v.1.0.x doesn't care about stuff after argv[6]
		NULL // 8
		};
	if ( older >= 1 ){ // no letters, just concrete positions
		args[3] += 1;
		args[4] += 1;
		args[5] += 1;
		args[6] += 1;
	}

#if ALPHABETA
bhLogOSP(@"switch_onoff (%d) %s %s %s %s %s %s %s", older, args[1], args[2], args[3], args[4], args[5], args[6], args[7]); //// debug
#endif
	
	status = posix_spawn(&pid, fp_sss, &action, NULL, (char* const*)args, environ);

	if (status == 0) {
		if (waitpid(pid, &status, 0) != -1) {
			if ( WIFEXITED(status) != 0 ){
				status = WEXITSTATUS(status);
				if ( status != 0 ){
					bhLogOSP(@"switch_onoff(%d,%d,%@,%@,%@,%@,%@,%d) ERROR: WEXITSTATUS(status) = %d (pid:%d)", older, onoff, nport==NULL?@"":nport, ar==NULL?@"":[ar stringValue], ap==NULL?@"":[ap stringValue], ak==NULL?@"":[ak stringValue], gl==NULL?@"":[gl stringValue], kickem, status, pid );
				}
			} else {
				bhLogOSP(@"switch_onoff(%d,%d,%@,%@,%@,%@,%@,%d) ERROR: WIFEXITED(status) = 0 (pid:%d)", older, onoff, nport==NULL?@"":nport, ar==NULL?@"":[ar stringValue], ap==NULL?@"":[ap stringValue], ak==NULL?@"":[ak stringValue], gl==NULL?@"":[gl stringValue], kickem, pid );
			}
		} else {
			bhLogOSP(@"switch_onoff(%d,%d,%@,%@,%@,%@,%@,%d) ERROR: waitpid(%d,&status,0) = -1", older, onoff, nport==NULL?@"":nport, ar==NULL?@"":[ar stringValue], ap==NULL?@"":[ap stringValue], ak==NULL?@"":[ak stringValue], gl==NULL?@"":[gl stringValue], kickem, pid );
		}
    } else {
		bhLogOSP(@"switch_onoff(%d,%d,%@,%@,%@,%@,%@,%d) ERROR: posix_spawn() = %d:%s", older, onoff, nport==NULL?@"":nport, ar==NULL?@"":[ar stringValue], ap==NULL?@"":[ap stringValue], ak==NULL?@"":[ak stringValue], gl==NULL?@"":[gl stringValue], kickem, status, strerror(status));
    }
	posix_spawn_file_actions_destroy(&action);

} // static void osp_switch_onoff(uint8_t older, _Bool onoff, NSString* nport, NSNumber* ar, NSNumber* ap, NSNumber* ak, NSNumber* gl, int8_t kickem){

#pragma mark end static functions, start iOS>=14 stuff while using iOS11 SDK

/* only declare these when building against an SDK older than iOS 14;
   newer SDKs already declare them in UIKit, and -Werror fails on duplicates */
#if !defined(__IPHONE_14_0) || (__IPHONE_OS_VERSION_MAX_ALLOWED < __IPHONE_14_0)

@protocol UIContentConfiguration <NSObject,NSCopying>
@required
-(id)makeContentView;
-(id)updatedConfigurationForState:(id)arg1;
@end

@interface UIListContentConfiguration : NSObject <UIContentConfiguration, NSSecureCoding>
-(void)setAttributedText:(NSAttributedString *)arg1 ;
@end

@interface UITableViewHeaderFooterView (iOS14)
-(UIListContentConfiguration*)defaultContentConfiguration;
-(id<UIContentConfiguration>)contentConfiguration;
-(void)setContentConfiguration:(id<UIContentConfiguration>)arg1 ;
@end

#endif /* SDK < iOS 14 */

#pragma mark end iOS>=14 stuff while using iOS11 SDK, start interfaces

// why aren't these things (and more) included in theos headers??
@interface PSListController (iOS5)
-(void)_returnKeyPressed:(id)arg1 ;
@end

@interface PSEditableTableCell (iOS6)
-(id)textField;
@end

@interface NSConcreteNotification: NSNotification
@end

@interface OpenSshPortCell : PSEditableTableCell 
@end

@interface OpenSshSubtitleSwitchCell : PSSwitchTableCell 
@end

@interface OpenSshPortController: PSListController
@property (nonatomic,strong,readonly) UIBarButtonItem *sessionsButton;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (void)notificationCallbackReceivedWithName:(NSString *)name;
@end

#pragma mark end interfaces, start implementations

@implementation OpenSshPortCell


-(OpenSshPortCell *)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {

	self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];

	[(UITextField *)[self textField] setTextAlignment: NSTextAlignmentRight];

	return self;	
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
	if(range.length + range.location > textField.text.length){ // Prevent crashing undo bug
		return NO;
	}

	if ( string.length > 0 && [string rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789,"] invertedSet]].location != NSNotFound )
		return NO;

	NSMutableString* newString = [NSMutableString stringWithString:textField.text];
	if ( range.location < textField.text.length ){
		if ( string.length == 0 )
			[newString deleteCharactersInRange:range];
		else
			[newString replaceCharactersInRange:range withString:string];
	} else
		[newString appendString:string];

	NSUInteger commas = [newString 
							replaceOccurrencesOfString:@","
							withString:@","
							options:NSLiteralSearch
							range:NSMakeRange(0, newString.length)];

	// for if we come from an earlier version which didn't have the limits
	if ( commas < openSshPortHasPorts ) openSshPortHasPorts = commas; // once we get to the allowed amount...
	if ( newString.length < textField.text.length || 
		commas < (openSshPortHasPorts>openSshPortAllowedPorts ? openSshPortHasPorts+1 : openSshPortAllowedPorts) ){
		return YES;
	}
	return NO;

}

@end

@implementation OpenSshSubtitleSwitchCell

- (OpenSshSubtitleSwitchCell *)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
	self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];
	self.detailTextLabel.text = @" "; // so the chain of ...Cell classes know to make some space there for the secondary text right from their init. Deprecated but still present in iOS16.
	return self;	
}

@end


@implementation OpenSshPortController

@synthesize table = _table;
@synthesize sessionsButton = _sessionsButton;

static NSString* _sswitch;
static NSNumber* _isRunning;
static NSString* _thePort;
static NSNumber* _isLinger;
static NSNumber* _isAroot;
static NSNumber* _isApass;
static NSNumber* _isAwLocked;
static NSNumber* _isFtoggle; // BootAsToggled
static NSNumber* _isNonBoot;
static NSNumber* _isApkey;
static NSNumber* _is2fact;
static NSNumber* _notGlobal;
static int _sssVersion;
static BOOL _didThatMyself;
static _Bool _missingPlist;
static _Bool _missingLhFun;
static _Bool _showErrorSec;
static NSMutableAttributedString* _errTxtLnks;

/** v.1.1.0 adding yet another toggle
	plist map (_showErrorSec might +1 everything), dependent code is commented with `// MAP' everywhere
 * 0 PSGroupCell				OpenSSH config							// section 0 (or 1 if _showErrorSec)
 * 1 PSSwitchCell				SSH ON/OFF								// 0-0
 * 2 PSSwitchCell				Permit Root Login						// 0-1
 * 3 OpenSshSubtitleSwitchCell	Require password (ie. don't allow pubkey) // 0-2
 * 4 OpenSshSubtitleSwitchCell	Require key (ie. don't allow password)	// 0-3
 * 5 OpenSshSubtitleSwitchCell	Localhost only							// 0-4
 * 6 OpenSshPortCell			SSH Port								// 0-5
 * 7 PSGroupCell				At device startup (after reboot/re-JB)	// section 1 (or 2 if _showErrorSec)
 * 8 PSSwitchCell				Remember last state						// 1-0
 * 9 PSSwitchCell				Start SSH server by default				// 1-1
 *10 PSGroupCell				Active Sessions							// section 2 (or 3 if _showErrorSec)
 *11 PSSwitchCell				Let'em linger							// 2-0
 *12 PSGroupCell				CC Toggle								// section 3 (or 4 if _showErrorSec)
 *13 PSSwitchCell				Allow toggling while locked				// 3-0
 *14 PSGroupCell(foot)			This is SSHswitch GUI					// section 4 (or 5 if _showErrorSec)
 *15 PSGroupCell(foot)			©										// section 5 (or 6 if _showErrorSec)
 **/

-(OpenSshPortController *) init {
    self = [super init];

	// xinaA15 mitigations 1st
	char * usr = "usr";
	char * bin = "bin";
	// without the prefix
	_sswitch = [NSString stringWithFormat:@"/%s/%s/%s", usr, bin, fp_ssw]; // rooted
	if ( !osp_file_exist([_sswitch UTF8String]) ){
		_sswitch = [NSString stringWithFormat:@"%s%@", jbroot, _sswitch]; // simple /var/jb
		if ( !osp_file_exist([_sswitch UTF8String]) ){
			NSString * envJbRoot = [[[NSProcessInfo processInfo] environment] objectForKey:@"JB_ROOT_PATH"];
			if ( envJbRoot ){
				_sswitch = [NSString stringWithFormat:@"%@/%s/%s/%s", envJbRoot, usr, bin, fp_ssw];
			} // else now we're f*d, this isn't going to work
		}
	}
	fp_sss = [_sswitch UTF8String];
	// 1.1.0: need to know the version before determining the other stuff, and definitely before it calls specifiers()
	[self readSssPrefs];

#if ALPHABETA
bhLogOSP(@"init switch path:%s ver:%d", fp_sss, _sssVersion); //// debug
#endif

	return self;
}

-(void)loadView {
//bhLogOSP(@"loadView"); //// debug

	[self bootAsTog];
	[self notOnBoot];
	_didThatMyself = NO;

	[super loadView];

	CFNotificationCenterAddObserver(
		CFNotificationCenterGetDarwinNotifyCenter(), 
		(__bridge const void *)(self),
		openSshPortOnOffCallback, 
		CFSTR("com.openssh.sshd/on"), 
		NULL, 
		CFNotificationSuspensionBehaviorCoalesce
		);
	CFNotificationCenterAddObserver(
		CFNotificationCenterGetDarwinNotifyCenter(), 
		(__bridge const void *)(self),
		openSshPortOnOffCallback, 
		CFSTR("com.openssh.sshd/off"), 
		NULL, 
		CFNotificationSuspensionBehaviorCoalesce
		);
	
	_sessionsButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSearch target:self action:@selector(showSessions:)];
	[[self navigationItem] setRightBarButtonItem:self.sessionsButton animated:NO];
	
}

- (void)dealloc {
	CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)(self));
}

// it's either viewWillDisappear or willResignActive in all cases?
// happens in all cases unless willResignActive
- (void)viewWillDisappear:(BOOL)arg1 {

#if ALPHABETA
bhLogOSP(@"viewWillDisappear %d view.layer.z:%f",arg1,self.view.layer.zPosition); //// debug
#endif

	[super viewWillDisappear:arg1];

	// so we know to re-read stuff when we're displayed again
	_thePort = nil;
}

// [PSViewController willResignActive]
// it's either viewWillDisappear or willResignActive in all cases?
-(void)willResignActive {

#if ALPHABETA
bhLogOSP(@"willResignActive "); //// debug
#endif
	
	// so we know to re-read stuff when we're displayed again
	_thePort = nil;
}

// [PSViewController willBecomeActive]
// Happens if viewWillAppear doesn't (which in turn happens after loadView et al).
// But in some circumstances this happens:
//  Pulling Notification Center down results in willResignActive,
//  then when the center is settled (all the way down), willBecomeActive & willResignActive are called again - why??
//  So we do reload stuff unnecessarily at those times. I couldn't find any good indicator or method to tell us about this situation.
// And after some notification this gets called without being preceded by any willResignActive{}.
-(void)willBecomeActive {

#if ALPHABETA
bhLogOSP(@"willBecomeActive"); //// debug
#endif

	if ( _thePort == nil ){
		_Bool oldShowErrorSec = _showErrorSec;
		_Bool oldMissingPlist = _missingPlist;
		_Bool oldMissingLhFun = _missingLhFun;
		
		[self readSssPrefs];

		if ( oldMissingPlist != _missingPlist || oldMissingLhFun != _missingLhFun ){
#if ALPHABETA
bhLogOSP(@"willBecomeActive oldShowErrorSec != _showErrorSec"); //// debug
#endif

			if ( oldShowErrorSec==1 )
				[self removeSpecifierAtIndex:0];
			if ( _showErrorSec==1 )
				[self addErrorSpecifier:NO];
			
			[self reloadSpecifiers];
			[_table reloadRowsAtIndexPaths: @[ 
					[self indexPathForSpecifier:[_specifiers objectAtIndex:1+_showErrorSec]], // MAP: SSH ON/OFF
					[self indexPathForSpecifier:[_specifiers objectAtIndex:2+_showErrorSec]], // MAP: Permit Root Login
					[self indexPathForSpecifier:[_specifiers objectAtIndex:3+_showErrorSec]], // MAP: Require password (ie. don't allow pubkey)
					[self indexPathForSpecifier:[_specifiers objectAtIndex:4+_showErrorSec]], // MAP: Require key (ie. don't allow password)
					[self indexPathForSpecifier:[_specifiers objectAtIndex:5+_showErrorSec]], // MAP: Localhost only
					[self indexPathForSpecifier:[_specifiers objectAtIndex:6+_showErrorSec]], // MAP: SSH Port
					[self indexPathForSpecifier:[_specifiers objectAtIndex:8+_showErrorSec]], // MAP: Remember last state
					[self indexPathForSpecifier:[_specifiers objectAtIndex:9+_showErrorSec]] // MAP: Start SSH server by default
				] 
				withRowAnimation:UITableViewRowAnimationNone];

		}
	}
}

#pragma mark UITableViewDelegate overrides stuff

// detail labels
- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
	if ( indexPath.section == 0 +_showErrorSec ){

		if ( indexPath.row == 2 ) // MAP: Require password (ie. don't allow pubkey)
			cell.detailTextLabel.text = [NSString stringWithFormat: [_is2fact boolValue]
				? @"必须同时使用密钥和密码"
				: @"密码登录：%@", [[self passAllowed] boolValue] ? @"允许" : @"拒绝" ];
		else if ( indexPath.row == 3 ) // MAP: Require key (ie. don't allow password)
			cell.detailTextLabel.text = [NSString stringWithFormat: [_is2fact boolValue]
				? @"必须同时使用密钥和密码"
				: @"公钥登录：%@", [[self pkeyAllowed] boolValue] ? @"允许" : @"拒绝" ];
		else if ( indexPath.row == 4 ){ // MAP: `Localhost only'
			cell.detailTextLabel.text = _missingLhFun ? @"（此功能需升级 SSHswitch）" : @"仅本机 127.0.0.1（及 ::1）";
		}

	} else if ( indexPath.section == 1 +_showErrorSec ){ // MAP: At device startup (after reboot/re-JB)	// section 1
		cell.detailTextLabel.text =
			indexPath.row == 0 // MAP: Remember last state
				? ( [_isFtoggle boolValue]
					? @"恢复重启/重越狱前的状态"
					: @"由下方开关强制决定"
					)
				: ( [_isFtoggle boolValue] // MAP: Start SSH server by default
					? @"按上次开关状态"
					: ( [_isNonBoot boolValue]
						? @"更安全"
						: @"便于灾难恢复"
						)
					);

	}
}

- (void)tableView:(UITableView *)tablView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
	if ( _showErrorSec==0 || section > 0 ) return;

	if (_errTxtLnks){
		// iOS < 14. Deprecated yeah but it's still there in iOS 16.
		UILabel* txtLabel = (UILabel*)[(UITableViewHeaderFooterView *)view textLabel];
		txtLabel.attributedText = _errTxtLnks;
		[txtLabel setUserInteractionEnabled:YES];
		[txtLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openPkgManager:)]];
	}	
}

// I don't want section headers in all caps
- (void)tableView:(UITableView *)tablView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {

	if ( _showErrorSec==0 || section>0 )
		[(UITableViewHeaderFooterView *)view textLabel].text = [self specifierAtIndex:[self indexOfGroup:section]].name;

}

#pragma mark PSListController overrides stuff

// if it was applicationWillSuspend earlier, this happens before most things
-(BOOL)shouldReloadSpecifiersOnResume {

#if ALPHABETA
bhLogOSP(@"shouldReloadSpecifiersOnResume"); //// debug
#endif

	return YES;
}

- (id)specifiers {
#if ALPHABETA
bhLogOSP(@"specifiers (sver:%d)", _sssVersion); //// debug
#endif
	if (_specifiers == nil) {

		[self readSssPrefs]; // this might set _showErrorSec=1 (as of v.1.1.0)

		_specifiers = [self loadSpecifiersFromPlistName:@"OpenSshPort" target:self];

		if ( _showErrorSec ){
			[self addErrorSpecifier:YES];
		}

		if ( _isFtoggle == nil ){
			[self bootAsTog];
		}
		if ( [_isFtoggle boolValue] )
			_isNonBoot = [_isRunning boolValue] ? @0 : @1;
		else if ( _isNonBoot == nil )
			[self notOnBoot];

	}

	return _specifiers;
} // - (id)specifiers {

/* generic setter/getter */
-(id)readPreferenceValue:(PSSpecifier*)specifier {

#if ALPHABETA
bhLogOSP(@"readPreferenceValue name: %@", specifier.name); //// debug
#endif

	id ret = @"";

	long mapInd = [self indexOfSpecifier:specifier] - _showErrorSec;

	if ( mapInd<10 ){
		[specifier setProperty: ( 
				(mapInd==9 && [_isFtoggle boolValue]) 
				|| _missingPlist 
				|| (mapInd==5 && _showErrorSec) 
			) ? @NO : @YES 
		forKey:@"enabled"];
	}

	switch( mapInd ){
		case 1:{ // MAP: SSH ON/OFF
			ret = [self sshRunning];
			break;}
		case 2:{ // MAP: Permit Root Login
			ret = [self rootAllowed];
			break;}
		case 3:{ // MAP: Require password
			ret = [[self pkeyAllowed] boolValue] ? @0 : @1;
			break;}
		case 4:{ // MAP: Require key
			ret = [[self passAllowed] boolValue] ? @0 : @1;
			break;}
		case 5:{ // MAP: Localhost only
			ret = [self localOnly];
			break;}
		case 6:{ // MAP: SSH Port
			ret = [self readSssPrefs];
			break;}
		case 8:{ // MAP: Remember last state
			ret = _isFtoggle;
			break;}
		case 9:{ // MAP: Start SSH server by default
			ret = [_isNonBoot boolValue] ? @0 : @1;
			break;}
		case 11:{ // MAP: Let'em linger
			ret = [self letEmLinger];
			break;}
		case 13:{ // MAP: Allow toggling while locked
			ret = [self allowWhileLocked];
			break;}
		default: break;		
	}

	return ret;
} // -(id)readPreferenceValue:(PSSpecifier*)specifier {

-(void)setPreferenceValue:(id)value specifier:(PSSpecifier*)specifier {

	BOOL valueBool = [value boolValue]; // if `SSH Port' then it's always TRUE
	long indOfSpec = [self indexOfSpecifier:specifier];
	long mapInd = indOfSpec - _showErrorSec;

#if ALPHABETA
bhLogOSP(@"setPref:%@ name:%@ i:%lu m:%lu", value, specifier.name, indOfSpec, mapInd); //// debug
#endif

	switch( mapInd ){
		case 1:{ // MAP: SSH ON/OFF
			if ( valueBool != [[self sshRunning] boolValue] ){
				_didThatMyself = YES;
				osp_switch_onoff(_missingLhFun,valueBool?1:0,NULL, NULL, NULL, NULL, NULL, 0);
				_isRunning = (NSNumber*)value;
				if ( [_isFtoggle boolValue] ){
					_isNonBoot = valueBool ? @0 : @1;
					[self reloadSpecifierAtIndex:9+_showErrorSec]; // MAP: Start SSH server by default
					[_table reloadRowsAtIndexPaths: @[ 
							[self indexPathForSpecifier:[_specifiers objectAtIndex:9+_showErrorSec]] // MAP: Start SSH server by default
						] withRowAnimation:UITableViewRowAnimationNone];
				}
			}
			break;}
		case 2:{ // MAP: Permit Root Login
			if ( valueBool != [_isAroot boolValue] ){
				osp_switch_onoff(_missingLhFun, [_isRunning boolValue]?1:0, NULL, [NSNumber numberWithBool:valueBool], NULL, NULL, NULL, -1);
				_isAroot = (NSNumber*)value;
			}
			break;}
		case 3:  // MAP: Require password
		case 4:{ // MAP: Require key
			// `Require password' is the opposite of `Allow Pubkey Auth'
			// `Require key' is the opposite of `Allow Password Auth'
			BOOL thisOne = [mapInd==3?_isApkey:_isApass boolValue];
			BOOL othrOne = [mapInd==4?_isApkey:_isApass boolValue];
			if ( valueBool == thisOne ){

				if ( mapInd==3 ) _isApkey = valueBool ? @0 : @1;
				else _isApass = valueBool ? @0 : @1;
				_is2fact = ( valueBool && !othrOne ) ? @1 : @0;
				
				osp_switch_onoff(_missingLhFun, [_isRunning boolValue]?1:0, NULL, NULL, _isApass, _isApkey, NULL, -1);

				[self reloadSpecifierAtIndex:indOfSpec+ (mapInd==3 ? 1 : -1) ];
				[self reloadSpecifierAtIndex:indOfSpec];
				[_table reloadRowsAtIndexPaths: @[
						[self indexPathForSpecifier:[_specifiers objectAtIndex:indOfSpec+ (mapInd==3 ? 1 : -1) ]],
						[self indexPathForSpecifier:[_specifiers objectAtIndex:indOfSpec]]
					] withRowAnimation:UITableViewRowAnimationNone];
			}
			break;}
		case 5:{ // MAP: Localhost only
			if ( valueBool != [_notGlobal boolValue] ){
				osp_switch_onoff(_missingLhFun, [_isRunning boolValue]?1:0, NULL, NULL, NULL, NULL, [NSNumber numberWithBool:!valueBool], 0);
				_notGlobal = (NSNumber*)value;
			}
			break;}
		case 6:{ // MAP: SSH Port
			NSString* stringVal = (NSString *)value;
			NSString* currPort = [self readSssPrefs]; 
			if ( osp_okports(stringVal)==1 && osp_sameports(currPort,stringVal)==0 ){
				osp_switch_onoff(_missingLhFun, [_isRunning boolValue]?1:0, stringVal, NULL, NULL, NULL, NULL, -1);
				_thePort = stringVal;
			} else {
				[_table reloadRowsAtIndexPaths: @[
						[self indexPathForSpecifier:[_specifiers objectAtIndex:indOfSpec]] // MAP: SSH Port
					] withRowAnimation:UITableViewRowAnimationNone]; 
			}
			break;}
		case 8:{ // MAP: Remember last state
			if ( valueBool != [_isFtoggle boolValue] ){

				osp_switch_simple( valueBool ? "b" : "r" );
				_isFtoggle = value;

				_isNonBoot = valueBool ? ([_isRunning boolValue] ? @0 : @1) : @0;
				[(PSSpecifier*)[_specifiers objectAtIndex:indOfSpec+1] setProperty:valueBool?@NO:@YES forKey:@"enabled"]; // MAP: Start SSH server by default
				
				[self reloadSpecifierAtIndex:indOfSpec]; // MAP: Run SSH server after re-JB
				[self reloadSpecifierAtIndex:indOfSpec+1]; // MAP: Start SSH server by default
				[_table reloadRowsAtIndexPaths: @[
						[self indexPathForSpecifier:[_specifiers objectAtIndex:indOfSpec]], // MAP: Run SSH server after re-JB
						[self indexPathForSpecifier:[_specifiers objectAtIndex:indOfSpec+1]] // MAP: Start SSH server by default
					] withRowAnimation:UITableViewRowAnimationNone];
			}
			break;}
		case 9:{ // MAP: Start SSH server by default
			if ( valueBool == [_isNonBoot boolValue] ){
				osp_switch_simple( valueBool ? "r" : "n" );
			}
			_isNonBoot = valueBool ? @0 : @1;
			_isFtoggle = @0;
			[self reloadSpecifierAtIndex:indOfSpec]; // MAP: Start SSH server by default
			[_table reloadRowsAtIndexPaths: @[ 
					[self indexPathForSpecifier:[_specifiers objectAtIndex:indOfSpec]] // MAP: Start SSH server by default
				] withRowAnimation:UITableViewRowAnimationNone];

			break;}
		case 11:{ // MAP: Let'em linger
			if ( valueBool != [[self letEmLinger] boolValue] ){
				osp_switch_simple( valueBool ? "l" : "k" );
				_isLinger = value;
			}
			break;}
		case 13:{ // MAP: Allow toggling while locked
			if ( valueBool != [[self allowWhileLocked] boolValue] ){
				osp_switch_simple( valueBool ? "e" : "f" );
				_isAwLocked = value;
			}
			break;}
		default: break;
	} // switch( mapInd ){

	// offer to kick everyone out when turning it off, or if we're going localOnly
	if ( ![[self letEmLinger] boolValue] 
		&& (
			(mapInd==1 && !valueBool) // MAP: SSH ON/OFF
			|| (mapInd==5 && valueBool) // MAP: Localhost only
		)
	){
		NSMutableString * output = [self readSessions];
		if ( ![output hasPrefix:@"err"] && output.length>2 ){
			[self showSessions:output];
		}
	}

} // -(void)setPreferenceValue:(id)value specifier:(PSSpecifier*)specifier {

#pragma mark OpenSshPortController own stuff

// dismiss keyboard on Return key... what about numberic pad ???
- (void)_returnKeyPressed:(NSConcreteNotification *)notification {
	[self.view endEditing:YES];
	[super _returnKeyPressed:notification];
}

// based on https://stackoverflow.com/a/38537164/5610645
// and hints from https://github.com/AliSoftware/OHAttributedStringAdditions
- (void)openPkgManager:(UIGestureRecognizer *)recognizer {
#if ALPHABETA
bhLogOSP(@"UILabel openPkgManager"); //// debug
#endif

	CGPoint location = [recognizer locationInView:recognizer.view];
	UILabel* txtLabel = (UILabel*)recognizer.view;

	NSTextContainer* textContainer = [[NSTextContainer alloc] initWithSize:CGSizeZero];
	textContainer.lineFragmentPadding = 0.0;
	textContainer.lineBreakMode = txtLabel.lineBreakMode;
	textContainer.maximumNumberOfLines = txtLabel.numberOfLines;
	textContainer.size = CGSizeMake( txtLabel.bounds.size.width, txtLabel.bounds.size.height+10 );

	NSLayoutManager* layoutManager = [[NSLayoutManager alloc] init];
	[layoutManager addTextContainer:textContainer];

	NSTextStorage* textStorage = [[NSTextStorage alloc] initWithAttributedString:txtLabel.attributedText];
	[textStorage addAttribute:NSFontAttributeName value:txtLabel.font range:NSMakeRange(0, textStorage.length)];
	[textStorage addLayoutManager:layoutManager];

	NSInteger indexOfCharacter = [layoutManager characterIndexForPoint:CGPointMake(location.x,location.y) inTextContainer:textContainer fractionOfDistanceBetweenInsertionPoints:NULL];

	if (indexOfCharacter >= 0) {
		NSURL* url = [textStorage attribute:NSLinkAttributeName atIndex:indexOfCharacter effectiveRange:NULL];

		if (url) {
#if ALPHABETA
bhLogOSP(@"openPkgManager GO %@", url.absoluteString); //// debug
#endif
			if ( sys_ver_ge(@"10.0") ){
				[[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
			} else {
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
				[[UIApplication sharedApplication] openURL:url];
#pragma clang diagnostic warning "-Wdeprecated-declarations"
			}
		}
	}
}

- (void)showSessions:(id)inputOrButton {
//bhLogOSP(@"showSessions:%@", [inputOrButton description]); //// debug

	NSMutableString *popMsg = [NSMutableString stringWithString:@""];
	NSMutableAttributedString *popMsgAbtd;
	int sessCount = 0;

	NSMutableString * output;
	if ( [inputOrButton isKindOfClass:[NSMutableString class]] ){
		output = (NSMutableString *)inputOrButton;
	} else {
		output = [self readSessions];
	}

	if ( [output hasPrefix:@"err"] ){
		[popMsg appendFormat:@"(%@)", output];
	} else if ( output.length > 2 ) { // 0 sessions still gives an empty json array "[]"
		NSMutableArray *word7indexes = [[NSMutableArray alloc] init]; // `) since' indexes
		NSMutableArray *word5indexes = [[NSMutableArray alloc] init]; // `using' and `(pid:' indexes
		NSMutableArray *word4indexes = [[NSMutableArray alloc] init]; // `from' indexes

		NSArray *sessions = [output componentsSeparatedByString:@"},{"];

		NSArray *infos;
		NSArray *infs;
		for (NSString *sess in sessions) {
			[popMsg appendString:@"* "];
			infos = [sess componentsSeparatedByString:@","];
			for (NSString *info in infos) {
				infs = [info componentsSeparatedByString:@":"];
				if ( [infs[0] hasSuffix:@"\"n\""] ){
					[popMsg appendFormat:@"%@ ", [infs[1] stringByTrimmingCharactersInSet:[NSCharacterSet punctuationCharacterSet]]]; // "mobile "
				} else if ( [infs[0] hasSuffix:@"\"c\""] ){
					[word5indexes addObject:[NSNumber numberWithLong:popMsg.length]]; // index of "using"
					[popMsg appendFormat:@"使用 %@ ", [infs[1] stringByTrimmingCharactersInSet:[NSCharacterSet punctuationCharacterSet]] ]; // "using bash "
				} else if ( [infs[0] hasSuffix:@"\"p\""] ){
					[word5indexes addObject:[NSNumber numberWithLong:popMsg.length]]; // index of "(pid:"
					[popMsg appendFormat:@"(pid:%@) ", infs[1] ]; // "(pid:24234) "
				} else if ( [infs[0] hasSuffix:@"\"i\""] ){
					[word4indexes addObject:[NSNumber numberWithLong:popMsg.length]]; // index of "from"
					[popMsg appendFormat:@"来自 %@ ", [[[infs subarrayWithRange:NSMakeRange(1,[infs count]-1)] componentsJoinedByString:@":"] stringByReplacingOccurrencesOfString:@"\"" withString:@""] ];
				} else if ( [infs[0] hasSuffix:@"\"s\""] ){
					[word7indexes addObject:[NSNumber numberWithLong:popMsg.length-2]]; // index of ") since"
					[popMsg appendFormat:@"自 %@\n",  
						[NSDateFormatter localizedStringFromDate: [NSDate dateWithTimeIntervalSince1970: 
																	[[infs[1] stringByTrimmingCharactersInSet:
																		[NSCharacterSet punctuationCharacterSet]
																	] doubleValue] ]
										dateStyle: NSDateFormatterMediumStyle
										timeStyle: NSDateFormatterLongStyle
							]
						];
				} // } else if ( [infs[0] hasSuffix:@"\"s\""] ){
			} // for (NSString *info in infos) {
			sessCount++;
		} // for (NSString *sess in sessions) {

		if ( sys_ver_ge(@"11.0") ){
			NSMutableParagraphStyle *popMsgStyle = [[NSMutableParagraphStyle alloc] init];
			[popMsgStyle setAlignment:NSTextAlignmentLeft];
			popMsgAbtd = [[NSMutableAttributedString alloc] initWithString:popMsg attributes: @{NSParagraphStyleAttributeName:popMsgStyle, NSFontAttributeName:[UIFont systemFontOfSize:12]}];
			for ( NSNumber *i in word4indexes ){
				// `来自'
				[popMsgAbtd addAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:12 weight:UIFontWeightUltraLight]} range:NSMakeRange([i unsignedLongValue],4)];
			}
			for ( NSNumber *i in word5indexes ){
				// `使用' and `(pid:'
				[popMsgAbtd addAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:12 weight:UIFontWeightUltraLight]} range:NSMakeRange([i unsignedLongValue],5)];
			}
			for ( NSNumber *i in word7indexes ){
				// `) 自'
				[popMsgAbtd addAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:12 weight:UIFontWeightUltraLight]} range:NSMakeRange([i unsignedLongValue],3)];
			}
		}
	} // } else if ( output.length > 2 ) {

	// alert
	NSString * aTitle = [NSString stringWithFormat:@"%d 个 SSH 会话", sessCount];
	NSString * aKick = @"踢出所有会话";
	NSString * aCopy = @"复制文本";
	if ( sys_ver_ge(@"8.0") ){
		id UIAlertControllerClass = objc_lookUpClass("UIAlertController");
		if ( UIAlertControllerClass != nil ){

			UIAlertController *alert = (UIAlertController*)[UIAlertControllerClass alertControllerWithTitle:aTitle
				message: popMsgAbtd.length > 0 ? nil : popMsg
				preferredStyle:UIAlertControllerStyleAlert];

			id UIAlertActionClass = objc_lookUpClass("UIAlertAction");
			if ( UIAlertActionClass != nil ){
				if ( sessCount > 0 ){
					[alert addAction: (UIAlertAction*)[UIAlertActionClass
						actionWithTitle:aKick
						style:UIAlertActionStyleDefault // UIAlertActionStyleCancel
						handler:^(UIAlertAction *action) {
							osp_switch_onoff(_missingLhFun, [_isRunning boolValue]?1:0, NULL, NULL, NULL, NULL, NULL, 1);
						}]];
					[alert addAction: (UIAlertAction*)[UIAlertActionClass
						actionWithTitle:aCopy
						style:UIAlertActionStyleDefault // UIAlertActionStyleCancel
						handler:^(UIAlertAction *action) {
							[UIPasteboard generalPasteboard].string = popMsg;
						}]];
				}
				[alert addAction: (UIAlertAction*)[UIAlertActionClass
					actionWithTitle:@"好"
					style:UIAlertActionStyleDefault
					handler:^(UIAlertAction *action) {}]];

				if ( popMsgAbtd.length > 0 )
					[alert setValue:popMsgAbtd forKey:@"attributedMessage"];

				[[[[UIApplication sharedApplication] keyWindow] rootViewController] presentViewController:alert animated:YES completion:nil];
			} // if ( UIAlertActionClass != nil ){
		} // if ( UIAlertControllerClass != nil ){

	} else {
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		UIAlertView *alert = [[UIAlertView alloc] initWithTitle:aTitle
			message: popMsg
			delegate:self
			cancelButtonTitle:@"OK"
			otherButtonTitles:nil];

		if ( sessCount > 0 ){
			[alert addButtonWithTitle:aKick];
			[alert addButtonWithTitle:aCopy];
		}
		[alert show];
#pragma clang diagnostic warning "-Wdeprecated-declarations"
	}

} // - (void)showSessions {

#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
	if ( [[alertView buttonTitleAtIndex:buttonIndex] isEqualToString:@"Copy text"] ){
		[UIPasteboard generalPasteboard].string = alertView.message;
	} else if ( [[alertView buttonTitleAtIndex:buttonIndex] isEqualToString:@"Kick 'em out"] ){
		osp_switch_onoff(_missingLhFun, [_isRunning boolValue]?1:0, NULL, NULL, NULL, NULL, NULL, 1);
	}
}
#pragma clang diagnostic warning "-Wdeprecated-declarations"

- (void)addErrorSpecifier:(BOOL)inSpecifiers {

	NSString* mpTxt = @"错误：\n无法找到或读取 OpenSSH 的 LaunchDaemon 配置文件。这可能表示 OpenSSH 未正确安装或缺少组件。";
	NSString* mlTxt = @"补充信息：\n若把 OpenSSH 设置为仅监听本机（例如通过 USB 的 iproxy 或本机 SSH 应用），需要升级 SSHswitch 插件。";
	
	PSSpecifier* whyDisabled = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
	[whyDisabled setProperty:0 forKey:@"alignment"];
	[whyDisabled setProperty: _missingPlist ? mpTxt : mlTxt forKey:@"footerText"]; // this needs to be non-empty for it to consider it worth processing at all (although we might overwrite it in the tableView).
	
	char * abc = "://apt.bingner.com";
	char * s_pus = "/etc/apt/sources.list.d/procursus.sources";
	char * s_cyd = "/etc/apt/sources.list.d/cydia.list";
	char * s_zbr = "/var/mobile/Library/Application Support/xyz.willy.Zebra/sources.list";
	char * s_ins = "/var/mobile/Library/Application Support/Installer/APT/sources.list";

#if ALPHABETA
bhLogOSP(@"addErrorSpecifier inSp:%d pus:%s cyd:%s zbr:%s ins:%s", inSpecifiers?1:0, s_pus, s_cyd, s_zbr, s_ins); //// debug
#endif

	_errTxtLnks = nil;
	NSURL* mgrUrl;

	if ( _missingPlist && osp_file_exist(s_pus) == 0 ){

		// so unfortunately I cannot find a file that would list all repos for Saily, so need to go thru a list of plist files...
		NSString* sailyDir = @"/var/mobile/Documents/wiki.qaq.chromatic/RepositoryCenter";
		__block BOOL sailyABC = NO;
		if ( osp_file_exist( sailyDir.UTF8String ) == 1 ){
			NSArray* sailyRepos = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:sailyDir error:Nil];
			/**
			__block NSDictionary* repoCont;
			__block id repoURLk;
			__block id repoURLv;
			[sailyRepos enumerateObjectsUsingBlock:^(NSString* obj, NSUInteger idx, BOOL *stop) {
				repoCont = [NSDictionary dictionaryWithContentsOfFile: [sailyDir stringByAppendingFormat:@"/%@", obj] ];
				repoURLk = [repoCont objectForKey:@"url"];
				if ( repoURLk != NULL ){
					repoURLv = [(NSDictionary*)repoURLk objectForKey:@"relative"];
					if ( repoURLv != NULL ){
						if ( [(NSString*)repoURLv containsString:[NSString stringWithUTF8String:abc]] ){
							sailyABC = YES;
							*stop = YES;
						}
					}
				}
			}];
			**/

			// it's magnitudes faster to simply search for the string in the binary plist than process the whole contents
			[sailyRepos enumerateObjectsUsingBlock:^(NSString* obj, NSUInteger idx, BOOL *stop) {
				if ( osp_grepq([sailyDir stringByAppendingFormat:@"/%@", obj].UTF8String,abc) == 0 ){
					sailyABC = YES;
					*stop = YES;
				}
			}];

		}

		if (
			// Saily
			sailyABC
			// apt ie. Cydia & Sileo
			|| ( osp_file_exist(s_cyd) == 1 && osp_grepq(s_cyd,abc) == 0 )
			// Zebra
			|| ( osp_file_exist(s_zbr) == 1 && osp_grepq(s_zbr,abc) == 0 )
			// Installer
			|| ( osp_file_exist(s_ins) == 1 && osp_grepq(s_ins,abc) == 0 )
			) {

			_errTxtLnks = [[NSMutableAttributedString alloc] 
					initWithString: [ 
							(NSString*)[whyDisabled propertyForKey:@"footerText"]
							stringByAppendingString:@" If OpenSSH is from the Elucubratus repo, you might need the \"OpenSSH Global Listener\" package."
						]
				];

			mgrUrl = [NSURL URLWithString:@"cydia://package/openssh-global-listener"];
			if ( [[UIApplication sharedApplication] canOpenURL:mgrUrl] ) {
				[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:@{}]];
				[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:@"Cydia" attributes:@{NSLinkAttributeName:mgrUrl}]];
			}
			mgrUrl = [NSURL URLWithString:@"zbra://packages/openssh-global-listener"];
			if ( [[UIApplication sharedApplication] canOpenURL:mgrUrl] ) {
				[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:@{}]];
				[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:@"Zebra" attributes:@{NSLinkAttributeName:mgrUrl}]];
			}
			mgrUrl = [NSURL URLWithString:@"installer://show/shared=Installer&name=OpenSSH%20Global%20Listener&bundleid=openssh-global-listener&repo=apt.bingner.com"];
			if ( [[UIApplication sharedApplication] canOpenURL:mgrUrl] ) {
				[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:@{}]];
				[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:@"Installer" attributes:@{NSLinkAttributeName:mgrUrl}]];
			}
			mgrUrl = [NSURL URLWithString:@"sileo://package/openssh-global-listener"];
			if ( [[UIApplication sharedApplication] canOpenURL:mgrUrl] ) {
				[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:@{}]];
				[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:@"Sileo" attributes:@{NSLinkAttributeName:mgrUrl}]];
			}
			// ok, for Saily, maybe I just cannot understand Swift (might easily happen), 
			// but I really cannot find it being able to parse a package id from its url scheme, 
			// seems like only deb files and repo addresses are supported (github.com/SailyTeam/Saily)				
		}

	} // if ( _missingPlist && osp_file_exist(s_pus) == 0 ){

	if ( _missingLhFun ){

		if ( _errTxtLnks ){
			[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"\n%@", mlTxt] attributes:@{}]];
		} else {
			_errTxtLnks = [[NSMutableAttributedString alloc] 
					initWithString: [(NSString*)[whyDisabled propertyForKey:@"footerText"] stringByAppendingString: _missingPlist ? mlTxt : @""]
				];			
		}

		mgrUrl = [NSURL URLWithString:@"cydia://package/u.blanxd.sshswitch"];
		if ( [[UIApplication sharedApplication] canOpenURL:mgrUrl] ) {
			[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:@{}]];
			[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:@"Cydia" attributes:@{NSLinkAttributeName:mgrUrl}]];
		}
		mgrUrl = [NSURL URLWithString:@"zbra://packages/u.blanxd.sshswitch"];
		if ( [[UIApplication sharedApplication] canOpenURL:mgrUrl] ) {
			[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:@{}]];
			[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:@"Zebra" attributes:@{NSLinkAttributeName:mgrUrl}]];
		}
		mgrUrl = [NSURL URLWithString:@"installer://show/shared=Installer&name=SSHswitch&bundleid=u.blanxd.sshswitch"];
		if ( [[UIApplication sharedApplication] canOpenURL:mgrUrl] ) {
			[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:@{}]];
			[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:@"Installer" attributes:@{NSLinkAttributeName:mgrUrl}]];
		}
		mgrUrl = [NSURL URLWithString:@"sileo://package/u.blanxd.sshswitch"];
		if ( [[UIApplication sharedApplication] canOpenURL:mgrUrl] ) {
			[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:@{}]];
			[_errTxtLnks appendAttributedString:[[NSAttributedString alloc] initWithString:@"Sileo" attributes:@{NSLinkAttributeName:mgrUrl}]];
		}

	}

	// it can only be a string, but we need to adjust to the bigger size else it may get hidden behind the top navigation bar
	if ( _errTxtLnks ){
		[whyDisabled setProperty:_errTxtLnks.string forKey:@"footerText"];
	}

	if ( inSpecifiers )
		[_specifiers insertObject:whyDisabled atIndex:0];
	else
		[self insertSpecifier:whyDisabled atIndex:0]; // this goes in the very beginning

} // - (void)addErrorSpecifier:(BOOL)inSpecifiers {

// https://stackoverflow.com/questions/26637023/how-to-properly-use-cfnotificationcenteraddobserver-in-swift-for-ios
- (void)notificationCallbackReceivedWithName:(NSString *)name {

	if ( _didThatMyself ){
		_didThatMyself = NO;
		return;
	}
//bhLogOSP(@"notificationCallbackReceivedWithName %@", name); //// debug

	if ( [name isEqualToString:@"com.openssh.sshd/off"] )
		_isRunning = @0;
	else 
		_isRunning = @1;

	[self reloadSpecifierAtIndex:1+_showErrorSec]; // MAP: SSH ON/OFF
	NSMutableArray *reloadRows = [NSMutableArray arrayWithObject:[self indexPathForSpecifier:[_specifiers objectAtIndex:1]]];
	if ( [_isFtoggle boolValue] ){
		_isNonBoot = [_isRunning boolValue] ? @0 : @1;
		[self reloadSpecifierAtIndex:9+_showErrorSec]; // MAP: Start SSH server by default
		[reloadRows addObject:[self indexPathForSpecifier:[_specifiers objectAtIndex:9+_showErrorSec]]]; // MAP: Start SSH server by default
	}
	[_table reloadRowsAtIndexPaths:reloadRows withRowAnimation:UITableViewRowAnimationNone]; // MAP: SSH ON/OFF [+ // MAP: Start SSH server by default] 

}

// so this isn't really a part of the class.
static void 
openSshPortOnOffCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
// bhLogOSP(@"openSshPortOnOffCallback %@", (__bridge NSString *)name); //// debug

	[(__bridge OpenSshPortController *)observer notificationCallbackReceivedWithName:(__bridge NSString *)name];		
}

#pragma mark READERS

// worker (reader)
- (NSMutableString*)readSessions {
	NSMutableString * output = [NSMutableString string];
	NSMutableString * err = [NSMutableString string];
	const char *swargs[] = {"ij"};
	int status = osp_switch_read( swargs, 1, output, err );
	if ( err.length || status<0 || status>1 ){
		[output appendFormat:@"error getting session list (ret:%d, err:%@)", status, err];
	}
	return output;
}

// worker (reader)
-(NSString *)readSssPrefs {
#if ALPHABETA
bhLogOSP(@"readSssPrefs"); //// debug
#endif

	if ( _thePort==nil || _isAroot==nil || _isApass==nil || _isRunning==nil || _isApkey==nil || _is2fact==nil ){

#if ALPHABETA
bhLogOSP(@"readSssPrefs exec"); //// debug
#endif

		// initially... or if SSHswitch fails or smthng.
		_thePort = @"22";
		_isAroot = @1;
		_isApass = @1;
		_isApkey = @1;
		_is2fact = @0;
		_missingPlist = 0;
		_missingLhFun = 0;
		_showErrorSec = 0;
		_sssVersion = 0;
		_notGlobal = nil;
		_isLinger = nil;
		_isAwLocked = nil;
		_isFtoggle = nil;
		_isNonBoot = nil;

		int status;
		NSMutableString * output = [NSMutableString string];
		NSMutableString * err = [NSMutableString string];
		const char *swargs[] = {"p","awutgvelnb"};
		status = osp_switch_read( swargs, 2, output, err );
		if ( (status==16||status==19) && [err isEqualToString:@"WEXITSTATUS"] ){
			_missingPlist = 1;
			_showErrorSec = 1;
			_isRunning = @0;
			if ( status==19 )
				_notGlobal = @0;
			// let's still get the version so we know about functionalities
			output = [NSMutableString string];
			err = [NSMutableString string];
			const char *vargs[] = {"v"};
			status = osp_switch_read( vargs, 1, output, err );
			if ( output.length )
				[output insertString:@"v" atIndex:0];
		}
		if ( err.length ){
			if ( !output.length )
				return _thePort;
		} else {
			_isRunning = status==0 && _missingPlist==0 ? @1 : @0;
		}

		NSMutableArray *ports = [NSMutableArray arrayWithArray:[output componentsSeparatedByString:@"\n"]];
		NSString *fstPort = [ports objectAtIndex:0];
		if ( fstPort == nil || fstPort.length < 2 ){
			return _thePort;
		}
		
		// need to get the ports into the beginning no matter how they were given, and iterate from the end, removing the words as we go
		[ports sortUsingComparator:^NSComparisonResult(id a, id b) {
			// need to get them in ascending order, then the words after that. Words result in intValue==0.
			if ( [a intValue]==0 ) // a is a word ie. needs to be after the b. The order of the words I don't care about
				return (NSComparisonResult)NSOrderedDescending;
			if ( [b intValue]==0 ) // b is a word ie. needs to be before the a.
				return (NSComparisonResult)NSOrderedAscending;
			
			// else both are numbers (if we've had anything to do with this, they're in ascending order, too)
			if ( [a intValue] < [b intValue] ) 
				return (NSComparisonResult)NSOrderedAscending;
			if ( [a intValue] > [b intValue] ) 
				return (NSComparisonResult)NSOrderedDescending;
			
			return (NSComparisonResult)NSOrderedSame;
		}];
		
		// do the iteration ourselves (instead of several containsObject and removeObject), so might catch output from newer SSHswitch et al
		// 		going backward we can remove the current element without worries and continue to the previous
		for ( NSInteger i = [ports count]-1; i >= 0; i-- ){
			NSString *line = ports[i];
			
			if ( [line intValue] == 0 ){ // it shouldn't really return anything beyond 65535
				if ( [line length] > 0 ){
					if ( [line isEqualToString:@"ano"] ){
						_isAroot = @0;
					} else if ( [line isEqualToString:@"wno"] ){
						_isApass = @0;
					} else if ( [line isEqualToString:@"uno"] ){
						_isApkey = @0;
					} else if ( [line isEqualToString:@"tyes"] ){
						_is2fact = @1;
						_isApass = @0; // don't care that it probably returns wyes (else it'd be a lockout (or advanced custom) setup)
						_isApkey = @0; // don't care that it probably returns uyes (else it'd be a lockout (or advanced custom) setup)
					} else if ( [line isEqualToString:@"gno"] ){
						_notGlobal = @1;
					} else if ( [line isEqualToString:@"eyes"] ){
						_isAwLocked = @1;
					} else if ( [line isEqualToString:@"lyes"] ){
						_isLinger = @1;
					} else if ( [line isEqualToString:@"nyes"] ){
						_isNonBoot = @1;
					} else if ( [line isEqualToString:@"byes"] ){
						_isFtoggle = @1;
					} else if ( [line hasPrefix:@"v"] ){
						// not forseeing the sub version numbers ever becoming more than x.99.99
						// 3 pieces: 1.0.0=10000, 1.1.0=10100, 1.1.1=10101. F* the build and alpha/beta stuff at the end.
						NSArray* vp = [[line substringFromIndex:1] componentsSeparatedByString:@"."];
						NSMutableString* vers;
						NSString* numStr;
						for ( uint8_t ind=0; ind<3; ind++ ){
							if ( vp.count>ind ){
								numStr = @([vp[ind] intValue]).stringValue; // only the numeric prefix of it
								if ( ind==0 )
									vers = [NSMutableString stringWithString:numStr];
								else {
									if ( numStr.length > 2 ) // let's just keep the 2nd and 3rd under a 100, need to just increase the prev number if necessary
										numStr = [numStr substringWithRange: NSMakeRange(numStr.length-2, 2) ];
									[vers appendFormat:@"%@%@", numStr.length > 1 ? @"" : @"0", numStr];
								}
							} else {
								[vers appendString:@"00"];
							}
						}
						_sssVersion = [vers intValue];

					}
				}
				[ports removeObjectAtIndex:i];
			}
		}

		openSshPortHasPorts = ports.count>0 ? ports.count-1 : 0;
		if ( ports.count>0 )
			_thePort = [ports componentsJoinedByString:@","];
	}

	if ( _sssVersion >= 10100 ){
		// stuff that's available since SSHswitch 1.1.0 (else the wrapper funcs do the reading of old pref files)
		if ( _missingPlist==0 ){
			if ( _notGlobal==nil )
				_notGlobal = @0;
			if ( _isLinger==nil )
				_isLinger = @0;
			if ( _isAwLocked==nil )
				_isAwLocked = @0;
			if ( _isFtoggle==nil )
				_isFtoggle = @0;
			if ( _isNonBoot==nil )
				_isNonBoot = @0;
		}
	} else {
		_missingLhFun = 1;
		_showErrorSec = 1;
	}

	return _thePort;
	
} // -(NSString *)readSssPrefs {

// worker wrapper
-(NSNumber *)sshRunning {
	[self readSssPrefs];
	return _isRunning;
}

// worker wrapper
-(NSNumber *)rootAllowed {
	[self readSssPrefs];
	return _isAroot;
}

// worker wrapper
-(NSNumber *)passAllowed {
	[self readSssPrefs];
	return _isApass;
}

// worker wrapper
-(NSNumber *)pkeyAllowed {
	[self readSssPrefs];
	return _isApkey;
}

// worker wrapper
-(NSNumber *)localOnly {
	[self readSssPrefs];
	return _notGlobal;
}

// worker (wrapper/reader)
-(NSNumber *)letEmLinger {
	if ( _sssVersion >= 10100 )
		[self readSssPrefs];
	else
		_isLinger = [NSNumber numberWithInt:osp_file_exist("/etc/ssh/u.blanxd.sshswitch.letemlinger")];
	return _isLinger;
}

// worker (wrapper/reader)
-(NSNumber *)allowWhileLocked {
	if ( _sssVersion >= 10100 )
		[self readSssPrefs];
	else
		_isAwLocked = [NSNumber numberWithInt:osp_file_exist("/etc/ssh/u.blanxd.sshswitch.eveniflocked")];
	return _isAwLocked;
}

// worker (wrapper/reader)
-(BOOL)bootAsTog {
	if ( _sssVersion >= 10100 )
		[self readSssPrefs];
	else
		_isFtoggle = [NSNumber numberWithInt:osp_file_exist("/etc/ssh/u.blanxd.sshswitch.bootastog")];
	return [_isFtoggle boolValue];
}

// worker (wrapper/reader)
-(BOOL)notOnBoot {
	if ( _sssVersion >= 10100 )
		[self readSssPrefs];
	else
		_isNonBoot = [NSNumber numberWithInt:osp_file_exist("/etc/ssh/u.blanxd.sshswitch.notonboot")];
	return [_isNonBoot boolValue];
}

@end
