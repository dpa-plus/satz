// Tells satz whether music or a video is playing, and in which app.
//
// Since macOS 15.4 only Apple's own programs may read that from the system's
// MediaRemote framework; any other app gets "nothing playing". satz loads
// this library into /usr/bin/perl, which is Apple's and may (see
// now-playing.pl). Sending Pause and Play needs no such detour: satz does that
// itself.
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*IsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*PidFn)(dispatch_queue_t, void (^)(int));

// Called by Perl as an XSUB; the two arguments are Perl's and not used.
void satz_now_playing(void *perl, void *cv) {
    void *framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    IsPlayingFn isPlaying = framework ? (IsPlayingFn)dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") : NULL;
    PidFn pid = framework ? (PidFn)dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationPID") : NULL;
    if (!isPlaying || !pid) { printf("{\"error\":\"MediaRemote not found\"}\n"); fflush(stdout); return; }

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block Boolean playing = false;
    __block int app = 0;
    isPlaying(dispatch_get_global_queue(0, 0), ^(Boolean value) { playing = value; dispatch_semaphore_signal(done); });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    pid(dispatch_get_global_queue(0, 0), ^(int value) { app = value; dispatch_semaphore_signal(done); });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    printf("{\"playing\":%s,\"pid\":%d}\n", playing ? "true" : "false", app);
    fflush(stdout);
}
