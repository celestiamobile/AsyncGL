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

## License

Licensed under the [MIT](LICENSE) license.
