#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, or nil.
///
/// AVFAudio reports some failures (a tap whose format no longer matches a
/// busy or switching microphone, a player started on a stopped engine) by
/// raising NSException, which Swift cannot catch. Raised in a main-actor task,
/// AppKit swallows it and the main dispatch queue never runs again: the app
/// looks alive and ignores every later key press. Raised in a plain main-queue
/// block, the app aborts. Keep the block to the single framework call being
/// guarded.
FOUNDATION_EXPORT NSException * _Nullable SonaCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
