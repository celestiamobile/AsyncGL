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

`Tests/RuntimeHost/Native.xcodeproj` and `Tests/RuntimeHost/ANGLE.xcodeproj`
provide isolated application hosts linked against the local package. Open one
project at a time (the projects select different package traits). Run its `Mac`
scheme on macOS, or its `UIKit` scheme on Mac Catalyst or an iOS simulator.
Each run checks presented pixels, source/mirror resizing, hide/show, stop/restart,
and shutdown with an active mirror, both without MSAA and with 4x MSAA.
UIKit hosts also move an already-rendering source to another window before
starting mirroring, then move it back with mirroring active. They check window
attachment state before incidental layout callbacks can hide stale render state.
The host displays PASS/FAIL and writes `AsyncGL-<platform>-<backend>.json` in its
Documents directory. These hosts use test-only GPU readback; production mirroring
does not. Hardened runtime is disabled only for these ad-hoc-signed test hosts.

## Sample-buffer output / PiP prototype

`startSampleBufferOutputWithMaximumSize:handler:error:` exports native GLES 3,
CGL 4.1, or ANGLE GLES 3 frames as GPU-backed BGRA `CMSampleBuffer`s.
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

Run `NativePiPMac` or `NativePiPUIKit` in `Tests/RuntimeHost/Native.xcodeproj`.
For ANGLE, use `ANGLEPiPMac` or `ANGLEPiPUIKit` in
`Tests/RuntimeHost/ANGLE.xcodeproj`; open only one host project at a time.
These isolated hosts connect the output to `AVSampleBufferDisplayLayer`.
**ANGLEPiPMac** and **ANGLEPiPUIKit on Mac Catalyst** use the private presenter
described below; click **Start / stop
PiP** after `PiP private ready=1` (frames are ready; SPI availability is checked
when starting). The other hosts use `AVPictureInPictureController`; wait for
`PiP possible=1`.
The changing upper-right quadrant demonstrates liveness; `bad=0` checks the other
three quadrants, orientation, and dimensions. Reports are written every second to
`Documents/AsyncGL-PiP.json`, including PiP and window/background state.
The host uses a test timer rather than AsyncGLViewController's display link.

For an independent macOS baseline, open `Tests/RuntimeHost/MacPiP.xcodeproj`
and run **MacPiP** on **My Mac**. This standalone target has no package
dependencies: it generates animated NV12 or BGRA frames on the CPU and sends them directly
to `AVSampleBufferDisplayLayer` / `AVPictureInPictureController`. Click
**Start / stop PiP**, then resize the PiP window to check video scaling.
The source window shows frame counts and AVKit's reported render size.
Stop PiP before using **Format** to switch between NV12 and BGRA. Both formats
reproduce the public sample-buffer scaling failure on the current test Mac.
The same project also has a **MacPiPPlayer** scheme using `AVPlayerLayer`.
Run it, click **Open movie...**, choose a local video, then start and resize PiP.
Playback is muted and loops so that the comparison can run continuously.
This is a control for the standard movie-playback path, not a live-frame fallback.
On the current test Mac, the CPU sample-buffer target reproduces the same clipping
as the GPU hosts, while the AVPlayerLayer control fills and scales correctly with
a generated H.264 movie. The failing sample-buffer path does not require AsyncGL
or ANGLE to reproduce; a movie-playback control is not a fix for live GPU output.

**Private SPI experiment:** the same project has a separate **MacPiPPrivate**
scheme. That target and **ANGLEPiPMac** compile the adapter that dynamically loads
Apple's undocumented `PIP.framework`. **ANGLEPiPUIKit on Mac Catalyst** embeds a
native AppKit bridge bundle using the same adapter. Neither the AsyncGL library,
the iOS host builds, nor the public baseline includes this adapter.
It presents the actual video view in a private PiP panel, rather than asking
AVKit to mirror its sample-buffer layer. ANGLEPiPMac reparents its GPU-fed preview,
not the source GL view, with no encoding or CPU-generated fallback.
The content container fills the panel
on attachment and appearance, including when the panel acquires its final size
after attachment. Closing PiP restores the inline view. ANGLEPiPMac waits for
both private PiP dismissal and renderer cleanup before terminating.
This is a local, opt-in experiment with OS-compatibility and App Store risks,
not a supported library feature. MacPiPPrivate's BGRA/NV12 sample generation is
shared with the public baseline. Its geometry reports go to
`Documents/MacPiPPrivate-Geometry.json` (the public baseline writes
`MacPiP-Geometry.json`). ANGLEPiPMac retains `AsyncGL-PiP.json`, identifying its
`PrivateSPI` presenter separately from its `ANGLE` renderer.

macOS continues producing PiP frames while its source window is occluded.
The Catalyst private host also enables desktop offscreen rendering while PiP is active.
On iOS, **Background experiment: ON** opts into continued rendering
only while PiP is actually active. It defaults OFF. This is a simulator experiment,
not a supported device background-rendering contract: native GLES commands in the
background can terminate an iOS app, and Metal can reject background submissions.
ANGLE does not bypass those restrictions. Apple's iOS 18+ MTKView video-call PiP
exception does not establish support for this general sample-buffer path.
The offscreen override is private and used only by the test host; normal AsyncGL
background protection remains unchanged. MobileCelestia does not adopt this API.

Current runtime results: native macOS PiP continues delivering validated frames
with its source window minimized. The iPadOS 27.2 simulator rejects the native
GLES pixel-buffer texture with `kCVReturnPixelBufferNotOpenGLCompatible` (-6683),
including with explicit IOSurface framebuffer-compatibility attributes. It
therefore cannot validate this GPU-only iOS PiP path or the background experiment.
No CPU fallback is used, and physical-device behavior has not been verified.
ANGLE's macOS GPU export tests pass, including the default framebuffer with and
without 4x MSAA. ANGLEPiPMac's private presenter fills the panel on first opening
and scales when resized. Validated samples continue while its source window is
minimized, and stopping PiP restores the inline preview.
The public macOS sample-buffer route remains blocked by fixed-size/clipped
content. Changing inline layer geometry affected that mirrored content, but
zero-origin/backing-layer and standalone layer-hosting experiments did not fix
PiP scaling. The failed layer-hosting workaround and preview-layout probe have
been removed from the GPU host.
The ANGLE iOS host builds; interactive iOS PiP and background behavior remain
unverified.

On the current macOS 27.2 test machine, the public AVKit path tested in
**ANGLEPiPUIKit on Mac Catalyst** renders valid samples, creates its public PiP
controller, and receives playback-delegate
queries, but PiP remains unavailable. AVKit logs `isContentSourceSupported: NO`
despite `sourceIsVisible: YES` and `isSystemPictureInPicturePossible: YES`.
A UIView-backed sample layer and a direct start request did not resolve this.
Display status `1` means the sample layer is rendering, not that PiP is available.
Reports include controller/support flags and playback-query counts to distinguish
this failure from GPU export or delegate setup failures.

The Catalyst host now uses a separate **CatalystPiPBridge.bundle**, embedded only
for Mac Catalyst. It resolves the native window using private host-window SPI and
temporarily moves the existing GPU-fed sample-buffer layer into an AppKit view
for the private presenter. Closing PiP restores the inline layer; the host's
**Quit** button waits for renderer cleanup and PiP dismissal before termination.
Initial presentation and resizing work. Minimized-frame progression,
stop/restart/restoration, and coordinated quit still need runtime verification.
These private APIs are confined to test-host code, not the AsyncGL library.

Run `bash Tests/run-sample-buffer-tests.sh` on macOS for headless native output
tests, or `bash Tests/run-sample-buffer-tests.sh angle` for the ANGLE Metal
equivalent: single-sample/4x MSAA pixels, scaling, resize, timestamps, asynchronous
fence delivery, pool backpressure and recovery, GL-state preservation, and cleanup
with pending work. Lifecycle cases cover single-frame delivery without another
draw, paused output replacement/stopping (including mirroring), and resuming
deferred work. A gated resume-during-output-update case checks task ordering and
exactly-once drawing. The ANGLE runner builds the package to resolve its frameworks.

## License

Licensed under the [MIT](LICENSE) license.
