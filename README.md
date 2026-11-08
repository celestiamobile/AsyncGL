## AsyncGL

A framework that allows rendering OpenGL (ES) contents on an NSThread.

Executor work wakes an initialized, unpaused render thread without waiting for a
frame. Asynchronous work queued before initialization or while paused is deferred.
Synchronous calls from other threads raise `NSInternalInconsistencyException`
when the view is uninitialized, pausing, paused, or stopped; calls on the render
thread run inline. Submissions to a detached executor or a stopped view also raise.
Accepted work drains on active shutdown; deferred asynchronous work is discarded.
Executor tasks must not synchronously wait for the main thread, which can itself
be waiting for rendering to pause or for a synchronous executor task.

Call `shutdown` on the main thread before releasing a view controller. It stops
display links and requests asynchronous teardown, retaining the controller until
its render-thread `clearGL` callback finishes. It is safe to call more than once.
If preparation never began, no `clearGL` callback is needed. Deallocation alone
cannot deliver subclass cleanup through the view's weak delegate.

## Mirroring

Call `glView.startMirroring()` on main and add the returned `UIView` (iOS/Catalyst)
or `NSView` (macOS) to the destination window. Mirroring requires OpenGL ES 3
for native EAGL/ANGLE, or an initialized OpenGL 4.1 core renderer for native CGL.
It uses a GPU texture copy instead of UIKit snapshots or CPU readback. The source
remains the only frame producer, with presentation on its render thread.
EAGL/ANGLE use the source context; CGL uses a shared presentation context and GPU
fences. Mirroring supports resizing and MSAA; a new mirror replaces the previous one.
Call `glView.stopMirroring()` on main and remove the returned view when finished.
Keep the source rendering view attached to a visible window.

Run `bash Tests/run-mirroring-tests.sh` for the native CGL and ANGLE GPU tests.
They check pixel output, live resizing, reattachment, MSAA, and GL state restoration
while the main thread is blocked.

Runtime application hosts are kept locally and are not distributed in this
repository. The automated GPU and lifecycle tests remain included.

## Sample-buffer output / PiP prototype

`startSampleBufferOutputWithMaximumSize:handler:error:` exports native GLES 3,
CGL 4.1, or ANGLE GLES 3 frames as GPU-backed BGRA `CMSampleBuffer`s.
Native OpenGL on Mac Catalyst is unsupported because its CoreVideo OpenGL
texture-cache APIs are unavailable; start returns an error. Use ANGLE on Catalyst.
ANGLE requires `EGL_ANGLE_iosurface_client_buffer` with a 2D texture target
(the Metal backend). It imports each pixel buffer's IOSurface into an EGL
pbuffer, renders through its texture, and releases the EGL texture binding before
inserting the completion fence. It does not switch the source EGL context or
surfaces, and AsyncGL performs no CPU pixel copy.
Call start/stop on main. The handler runs on the render thread after a GPU fence
signals; retain the sample if handing it to another queue. Never wait for main or
modify GL state inside the handler. Honor the consumer's readiness and do not
enqueue an unbounded sequence of asynchronous delivery blocks.

The output preserves aspect ratio, scales down only, and flips GL's origin to
top-down pixel-buffer coordinates. Maximum dimensions must be 1...4096 pixels.
MSAA resolves before scaling. There are at most three pending GPU frames and four
pool buffers at the current output size; a slow consumer drops new frames.
Starting again replaces the output; stopping retires it asynchronously.
Completed frames are polled independently of new draws. Stopped or replaced
outputs are retired even while paused, without resuming drawing or queued tasks.
Runtime capture failures are logged and suspend that output until replaced.
This API can run alongside mirroring and does not change application suspension
or audio-session policy.

For experimental PiP clients, set
`AsyncGLViewController.rendersWhileOffscreen = true` while PiP is starting or
active, then reset it when PiP stops or fails. This opts into offscreen rendering,
resumes a ready renderer, and replaces the scene/display-bound clock with an
independent timer honoring the configured frame rate. Automatic inactivity and
window-detachment pauses are suppressed; explicit `paused = true` still pauses.
Disabling restores the normal clock and lifecycle policy. The corresponding view
property only enables offscreen drawing; it does not schedule frames.
Both properties default to false and must be changed on main. This policy does
not grant permission to execute GPU commands in the background.

PiP presentation is client-owned. On the macOS 27.2 test machine, public AVKit
sample-buffer PiP clips or fails to scale on macOS and rejects the content source
on Mac Catalyst despite valid GPU samples. Local private-SPI experiments are not
part of the library or a supported integration.

Physical-device iOS behavior remains unverified. The iPadOS 27.2 simulator rejects
the native GLES pixel-buffer texture with
`kCVReturnPixelBufferNotOpenGLCompatible` (-6683); no CPU fallback is used.
Background rendering is not a supported device contract: native GLES commands
can terminate an iOS app, and Metal can reject background submissions. ANGLE does
not bypass these restrictions. Normal AsyncGL background protection is unchanged.

Run `bash Tests/run-sample-buffer-tests.sh` on macOS for headless native output
tests, or `bash Tests/run-sample-buffer-tests.sh angle` for the ANGLE Metal
equivalent: single-sample/4x MSAA pixels, scaling, resize, timestamps, asynchronous
fence delivery, pool backpressure and recovery, GL-state preservation, and cleanup
with pending work. Lifecycle cases cover single-frame delivery without another
draw, paused output replacement/stopping (including mirroring), and resuming
deferred work. A gated resume-during-output-update case checks task ordering and
exactly-once drawing. The ANGLE runner builds the package to resolve its frameworks.
Controller cases also cover the independent offscreen clock, lifecycle pauses,
explicit pause, restart, and shutdown.

## License

Licensed under the [MIT](LICENSE) license.
