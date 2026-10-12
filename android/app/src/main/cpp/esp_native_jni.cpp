#include "esp_native_core.h"
#include <jni.h>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <stdexcept>
#include <vector>

namespace {
class AndroidPort final : public meshcore::EspTransport {
public:
    JNIEnv *env;
    jobject engine;
    jmethodID readMethod, writeMethod, signalsMethod, baudMethod, delayMethod, cancelMethod;
    std::vector<uint8_t> buffered;
    size_t cursor = 0;
    AndroidPort(JNIEnv *e, jobject instance) : env(e) {
        engine = env->NewGlobalRef(instance);
        jclass type = env->GetObjectClass(instance);
        readMethod = env->GetMethodID(type, "nativeUsbRead", "(II)[B");
        writeMethod = env->GetMethodID(type, "nativeUsbWrite", "([B)V");
        signalsMethod = env->GetMethodID(type, "nativeUsbSignals", "(ZZ)V");
        baudMethod = env->GetMethodID(type, "nativeUsbBaud", "(I)V");
        delayMethod = env->GetMethodID(type, "nativeUsbDelay", "(I)V");
        cancelMethod = env->GetMethodID(type, "nativeUsbCancelled", "()Z");
        env->DeleteLocalRef(type);
        try { check(); if (!engine) throw std::runtime_error("Native USB callback allocation failed"); }
        catch (...) { if (engine) env->DeleteGlobalRef(engine); throw; }
    }
    ~AndroidPort() override { env->DeleteGlobalRef(engine); }
    void check() { if (env->ExceptionCheck()) { env->ExceptionClear(); throw std::runtime_error("Native USB driver operation failed or was cancelled"); } }
    bool cancelled() override { auto value = env->CallBooleanMethod(engine, cancelMethod); check(); return value; }
    void read(uint8_t *data, size_t size, uint32_t timeout) override {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout);
        size_t done = 0;
        while (done < size) {
            if (cancelled()) throw std::runtime_error("USB operation cancelled");
            if (cursor < buffered.size()) {
                size_t count = std::min(size - done, buffered.size() - cursor);
                memcpy(data + done, buffered.data() + cursor, count); cursor += count; done += count;
                continue;
            }
            auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
            if (remaining <= 0) throw meshcore::EspTransportTimeout("USB read timed out");
            auto bytes = static_cast<jbyteArray>(env->CallObjectMethod(engine, readMethod, 4096, static_cast<jint>(std::min<int64_t>(250, remaining))));
            check(); if (!bytes) throw std::runtime_error("USB read returned no buffer");
            const jsize length = env->GetArrayLength(bytes); buffered.resize(length); cursor = 0;
            if (length) env->GetByteArrayRegion(bytes, 0, length, reinterpret_cast<jbyte *>(buffered.data()));
            env->DeleteLocalRef(bytes); check();
        }
    }
    void write(const uint8_t *data, size_t size, uint32_t) override {
        if (cancelled()) throw std::runtime_error("USB operation cancelled");
        auto bytes = env->NewByteArray(size); if (!bytes) throw std::runtime_error("USB write allocation failed");
        env->SetByteArrayRegion(bytes, 0, size, reinterpret_cast<const jbyte *>(data));
        env->CallVoidMethod(engine, writeMethod, bytes); env->DeleteLocalRef(bytes); check();
    }
    void signals(bool dtr, bool rts) override { env->CallVoidMethod(engine, signalsMethod, static_cast<jboolean>(dtr), static_cast<jboolean>(rts)); check(); }
    void baud(uint32_t value) override { env->CallVoidMethod(engine, baudMethod, static_cast<jint>(value)); check(); }
    void delay(uint32_t value) override { env->CallVoidMethod(engine, delayMethod, static_cast<jint>(value)); check(); }
};
struct Session { AndroidPort port; meshcore::EspNativeCore core; Session(JNIEnv *env, jobject engine) : port(env, engine), core(port) {} };
Session &session(JNIEnv *env, jlong handle) {
    if (!handle) throw std::runtime_error("Native ESP bootloader is not connected");
    auto &value = *reinterpret_cast<Session *>(handle); value.port.env = env; return value;
}
std::string string(JNIEnv *env, jstring value) {
    if (!value) throw std::runtime_error("Required identity or digest is missing");
    const char *bytes = env->GetStringUTFChars(value, nullptr); if (!bytes) throw std::runtime_error("String allocation failed");
    std::string result(bytes); env->ReleaseStringUTFChars(value, bytes); return result;
}
void fail(JNIEnv *env, const std::exception &error) {
    jclass type = env->FindClass("java/lang/IllegalStateException");
    if (type) { env->ThrowNew(type, error.what()); env->DeleteLocalRef(type); }
}
}
extern "C" JNIEXPORT jstring JNICALL Java_com_meshcore_meshcore_1open_MeshcoreUsbEspEngine_nativeVersion(JNIEnv *env, jobject) {
    return env->NewStringUTF("esp-serial-flasher/2.1.0/24997fe693ff17e6598d7eb1d37af312752100aa");
}
extern "C" JNIEXPORT jlong JNICALL Java_com_meshcore_meshcore_1open_MeshcoreUsbEspEngine_nativeCreate(JNIEnv *env, jobject self) {
    try { return reinterpret_cast<jlong>(new Session(env, self)); } catch (const std::exception &error) { fail(env, error); return 0; }
}
extern "C" JNIEXPORT jstring JNICALL Java_com_meshcore_meshcore_1open_MeshcoreUsbEspEngine_nativeConnect(JNIEnv *env, jobject, jlong handle, jboolean reset, jboolean nativeUsb, jboolean usbJtag, jboolean allowUnreviewed) {
    try {
        const auto info = session(env, handle).core.connect(reset, nativeUsb, usbJtag, allowUnreviewed);
        const auto json = std::string("{\"chip\":") + std::to_string(info.chip) + ",\"flashBytes\":" + std::to_string(info.flashBytes) +
            ",\"mac\":\"" + info.mac + "\",\"name\":\"" + info.name + "\"}";
        return env->NewStringUTF(json.c_str());
    } catch (const std::exception &error) { fail(env, error); return nullptr; }
}
extern "C" JNIEXPORT jbyteArray JNICALL Java_com_meshcore_meshcore_1open_MeshcoreUsbEspEngine_nativeReadFlash(JNIEnv *env, jobject, jlong handle, jint offset, jint length, jstring mac) {
    try {
        if (offset < 0 || length <= 0) throw std::runtime_error("Invalid read bounds");
        auto data = session(env, handle).core.read(offset, length, string(env, mac));
        auto result = env->NewByteArray(data.size());
        if (result) env->SetByteArrayRegion(result, 0, data.size(), reinterpret_cast<const jbyte *>(data.data()));
        return result;
    } catch (const std::exception &error) { fail(env, error); return nullptr; }
}
extern "C" JNIEXPORT void JNICALL Java_com_meshcore_meshcore_1open_MeshcoreUsbEspEngine_nativeWriteFlash(JNIEnv *env, jobject, jlong handle, jint offset, jbyteArray bytes, jstring mac, jstring hash) {
    try {
        if (!bytes || offset < 0) throw std::runtime_error("Invalid write arguments");
        const jsize length = env->GetArrayLength(bytes);
        if (length <= 0 || length > 32 * 1024 * 1024) throw std::runtime_error("Invalid firmware size");
        std::vector<uint8_t> data(length); env->GetByteArrayRegion(bytes, 0, length, reinterpret_cast<jbyte *>(data.data()));
        if (env->ExceptionCheck()) return;
        session(env, handle).core.write(offset, data, string(env, mac), string(env, hash));
    } catch (const std::exception &error) { fail(env, error); }
}
extern "C" JNIEXPORT void JNICALL Java_com_meshcore_meshcore_1open_MeshcoreUsbEspEngine_nativeEraseFlash(JNIEnv *env, jobject, jlong handle, jstring mac) {
    try { session(env, handle).core.erase(string(env, mac)); } catch (const std::exception &error) { fail(env, error); }
}
extern "C" JNIEXPORT void JNICALL Java_com_meshcore_meshcore_1open_MeshcoreUsbEspEngine_nativeRunApplication(JNIEnv *env, jobject, jlong handle, jstring mac) {
    try { session(env, handle).core.runApplication(string(env, mac)); } catch (const std::exception &error) { fail(env, error); }
}
extern "C" JNIEXPORT void JNICALL Java_com_meshcore_meshcore_1open_MeshcoreUsbEspEngine_nativeDestroy(JNIEnv *env, jobject, jlong handle) {
    if (handle) { auto &value = session(env, handle); delete &value; }
}
