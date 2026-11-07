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

## License

Licensed under the [MIT](LICENSE) license.
