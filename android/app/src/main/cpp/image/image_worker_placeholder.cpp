// AGP requires a SHARED target to package the separately linked PIE worker.
// Its output is replaced with the worker by the CMake POST_BUILD command.
extern "C" int meshcore_image_worker_placeholder() { return 0; }
