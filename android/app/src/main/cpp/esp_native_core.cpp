#include "esp_native_core.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <zlib.h>
extern "C" {
#include "esp_loader_stubs.h"
#include "esp_targets.h"
#include "md5_hash.h"
#include "protocol.h"
}
namespace meshcore {
static uint64_t nowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
static std::string hex(const uint8_t *bytes, size_t size) {
    static const char digits[] = "0123456789abcdef";
    std::string result(size * 2, '0');
    for (size_t i = 0; i < size; ++i) {
        result[i * 2] = digits[bytes[i] >> 4]; result[i * 2 + 1] = digits[bytes[i] & 15];
    }
    return result;
}
EspNativeCore::EspNativeCore(EspTransport &transport) : transport_(transport) {
    static const esp_loader_port_ops_t ops = [] {
        esp_loader_port_ops_t value{};
        value.enter_bootloader = portEnter; value.reset_target = portReset;
        value.start_timer = portTimer; value.remaining_time = portRemaining;
        value.delay_ms = portDelay; value.read = portRead; value.write = portWrite;
        value.change_transmission_rate = portBaud;
        // Never print firmware, private NVS, or wire frames into Android logs.
        return value;
    }();
    port_.owner = this; port_.base.ops = &ops;
    check(esp_loader_init_serial(&loader_, &port_.base), "Initialize native flasher");
    initialized_ = true;
}
EspNativeCore::~EspNativeCore() {
    // Port deinit is intentionally NULL: close/free cannot assert reset pins.
    if (initialized_) esp_loader_deinit(&loader_);
}
EspNativeCore &EspNativeCore::owner(esp_loader_port_t *port) {
    return *reinterpret_cast<Port *>(port)->owner;
}
esp_loader_error_t EspNativeCore::portRead(esp_loader_port_t *port, uint8_t *data, uint16_t size, uint32_t timeout) {
    auto &self = owner(port);
    try {
        if (!self.callbackError_.empty() || self.transport_.cancelled()) throw std::runtime_error("USB operation cancelled");
        self.transport_.read(data, size, timeout); return ESP_LOADER_SUCCESS;
    } catch (const EspTransportTimeout &) { return ESP_LOADER_ERROR_TIMEOUT; }
    catch (const std::exception &error) { self.callbackError_ = error.what(); return ESP_LOADER_ERROR_FAIL; }
}
esp_loader_error_t EspNativeCore::portWrite(esp_loader_port_t *port, const uint8_t *data, uint16_t size, uint32_t timeout) {
    auto &self = owner(port);
    try {
        if (!self.callbackError_.empty() || self.transport_.cancelled()) throw std::runtime_error("USB operation cancelled");
        self.transport_.write(data, size, timeout); return ESP_LOADER_SUCCESS;
    } catch (const std::exception &error) { self.callbackError_ = error.what(); return ESP_LOADER_ERROR_FAIL; }
}
esp_loader_error_t EspNativeCore::portBaud(esp_loader_port_t *port, uint32_t baud) {
    auto &self = owner(port);
    try { self.transport_.baud(baud); return ESP_LOADER_SUCCESS; }
    catch (const std::exception &error) { self.callbackError_ = error.what(); return ESP_LOADER_ERROR_FAIL; }
}
void EspNativeCore::portTimer(esp_loader_port_t *port, uint32_t ms) { reinterpret_cast<Port *>(port)->deadline = nowMs() + ms; }
uint32_t EspNativeCore::portRemaining(esp_loader_port_t *port) {
    auto deadline = reinterpret_cast<Port *>(port)->deadline;
    auto now = nowMs(); return now >= deadline ? 0 : static_cast<uint32_t>(deadline - now);
}
void EspNativeCore::portDelay(esp_loader_port_t *port, uint32_t ms) {
    auto &self = owner(port);
    try { self.transport_.delay(ms); } catch (const std::exception &error) { self.callbackError_ = error.what(); }
}
void EspNativeCore::portEnter(esp_loader_port_t *port) {
    auto &self = owner(port);
    if (!self.resetRequested_ || self.resetPerformed_) return;
    self.resetPerformed_ = true;
    try {
        if (self.usbJtag_) {
            self.transport_.signals(false, false); self.transport_.delay(100);
            self.transport_.signals(true, false); self.transport_.delay(100);
            self.transport_.signals(true, true); self.transport_.signals(false, true);
            self.transport_.delay(100); self.transport_.signals(false, false);
        } else {
            self.transport_.signals(false, true); self.transport_.delay(100);
            self.transport_.signals(true, false); self.transport_.delay(50);
            self.transport_.signals(false, false);
        }
    } catch (const std::exception &error) { self.callbackError_ = error.what(); }
}
void EspNativeCore::portReset(esp_loader_port_t *port) {
    // Only runApplication calls this. Deinit/cancel/passive connect never do.
    auto &self = owner(port);
    try {
        self.transport_.signals(false, true); self.transport_.delay(self.usbJtag_ ? 200 : 100);
        self.transport_.signals(false, false);
        if (self.usbJtag_) self.transport_.delay(200);
    } catch (const std::exception &error) { self.callbackError_ = error.what(); }
}
void EspNativeCore::check(esp_loader_error_t code, const char *operation) {
    if (!callbackError_.empty()) throw std::runtime_error(callbackError_);
    if (transport_.cancelled()) throw std::runtime_error("USB operation cancelled");
    if (code != ESP_LOADER_SUCCESS) throw std::runtime_error(std::string(operation) + " failed (native error " + std::to_string(code) + ")");
}
int EspNativeCore::imageChipId(target_chip_t target) {
    switch (target) {
        case ESP32_CHIP: return 0; case ESP32S2_CHIP: return 2;
        case ESP32C3_CHIP: return 5; case ESP32S3_CHIP: return 9;
        case ESP32C2_CHIP: return 12;
        case ESP32C5_CHIP: return 23; case ESP32H2_CHIP: return 16;
        case ESP32C6_CHIP: return 13; case ESP32P4_CHIP: return 18;
        case ESP32C61_CHIP: return 20; case ESP32S31_CHIP: return 32;
        case ESP32H21_CHIP: return 25; case ESP32H4_CHIP: return 28;
        // ESP8266 has neither an extended image chip ID nor an upstream
        // factory-MAC API. Never substitute an enum/address for identity.
        default: return -1;
    }
}
bool EspNativeCore::securityAllows(uint32_t flags, uint8_t counter) {
    unsigned count = 0; for (; counter; counter >>= 1) count += counter & 1;
    return !(flags & ((1U << 0) | (1U << 2) | (1U << 8))) && !(count & 1);
}
void EspNativeCore::securityBeforeStub(target_chip_t target) {
    securityVerified_ = false;
    if (target == ESP32_CHIP) {
        uint32_t crypt, secure;
        check(esp_loader_read_register(&loader_, 0x3ff5a000, &crypt), "Read flash encryption eFuse");
        check(esp_loader_read_register(&loader_, 0x3ff5a018, &secure), "Read secure boot eFuse");
        if ((secure & 0x30) || !securityAllows(0, (crypt >> 20) & 0x7f))
            throw std::runtime_error("Secure boot or flash encryption is enabled; refusing plaintext flashing");
    } else {
        // Pinned upstream2.1 incorrectly derives encryption from key_purposes.
        // Use the real ROM flash_crypt_cnt byte without altering vendor code.
        get_security_info_response_data_t raw{}; uint32_t received = 0;
        portTimer(&port_.base, 1000);
        check(loader_get_security_info_cmd(&loader_, &raw, &received), "Read ROM security info");
        if (received != sizeof(raw) && !(target == ESP32S2_CHIP && received == sizeof(raw) - 8))
            throw std::runtime_error("Unknown ROM security response; refusing flashing");
        if (!securityAllows(raw.flags, raw.flash_crypt_cnt))
            throw std::runtime_error("Secure boot, encryption or disabled USB recovery; refusing plaintext flashing");
        ecoVersion_ = raw.eco_version;
    }
    securityVerified_ = true;
}
std::string EspNativeCore::readMac() {
    uint8_t mac[6]; check(esp_loader_read_mac(&loader_, mac), "Read physical chip MAC");
    if (std::all_of(mac, mac + 6, [](uint8_t n) { return n == 0; }) ||
        std::all_of(mac, mac + 6, [](uint8_t n) { return n == 0xff; }))
        throw std::runtime_error("ROM returned no usable factory MAC; refusing flashing");
    return hex(mac, sizeof(mac));
}
void EspNativeCore::identity(const std::string &expected) {
    if (!connected_ || !securityVerified_) throw std::runtime_error("A security-verified ESP connection is required");
    if (expected.size() != 12 || expected != info_.mac || readMac() != expected)
        throw std::runtime_error("Connected chip MAC changed; refusing flash or reset");
}
void EspNativeCore::maskedWrite(uint32_t address, uint32_t value, uint32_t mask) {
    portTimer(&port_.base, 1000);
    check(loader_write_reg_cmd(&loader_, address, value, mask, 0), "Write recovery control register");
}
void EspNativeCore::disableNativeWatchdogs(target_chip_t target) {
    if (!usbJtag_ || (target != ESP32C3_CHIP && target != ESP32S3_CHIP)) return;
    const bool s3 = target == ESP32S3_CHIP;
    const uint32_t wdt = s3 ? 0x600080b0 : 0x600080a8;
    const uint32_t cfg = s3 ? 0x60008098 : 0x60008090;
    const uint32_t swd = s3 ? 0x600080b8 : 0x600080b0;
    const uint32_t swdCfg = s3 ? 0x600080b4 : 0x600080ac;
    maskedWrite(wdt, 0x50d83aa1, UINT32_MAX); maskedWrite(cfg, 0, UINT32_MAX); maskedWrite(wdt, 0, UINT32_MAX);
    maskedWrite(swd, 0x8f1d312a, UINT32_MAX); maskedWrite(swdCfg, 0x80000000, 0x80000000); maskedWrite(swd, 0, UINT32_MAX);
}
const esp_stub_t *EspNativeCore::stubProvider(esp_loader_t *, target_chip_t target, void *context) {
    auto &self = *static_cast<EspNativeCore *>(context);
    try {
        self.info_.chip = imageChipId(target);
        if (self.info_.chip < 0) throw std::runtime_error("The native library cannot prove this target's factory MAC and firmware chip ID");
        if (!self.allowUnreviewed_ && self.info_.chip != 0 && self.info_.chip != 2 && self.info_.chip != 5 && self.info_.chip != 9 && self.info_.chip != 12)
            throw std::runtime_error("This target requires the acknowledged expert-attempt mode");
        self.securityBeforeStub(target);
        self.info_.mac = self.readMac();
        self.disableNativeWatchdogs(target);
        switch (target) {
            case ESP32_CHIP: self.info_.name = "ESP32"; return &esp_stub_esp32;
            case ESP32S2_CHIP: self.info_.name = "ESP32-S2"; return &esp_stub_esp32s2;
            case ESP32C3_CHIP: self.info_.name = "ESP32-C3"; return &esp_stub_esp32c3;
            case ESP32S3_CHIP: self.info_.name = "ESP32-S3"; return &esp_stub_esp32s3;
            case ESP32C2_CHIP: self.info_.name = "ESP32-C2"; return &esp_stub_esp32c2;
            case ESP32C5_CHIP: self.info_.name = "ESP32-C5"; return &esp_stub_esp32c5;
            case ESP32H2_CHIP: self.info_.name = "ESP32-H2"; return &esp_stub_esp32h2;
            case ESP32C6_CHIP: self.info_.name = "ESP32-C6"; return &esp_stub_esp32c6;
            case ESP32P4_CHIP: self.info_.name = "ESP32-P4"; return self.ecoVersion_ >= ESP32P4_ECO_REV3_MIN ? &esp_stub_esp32p4 : &esp_stub_esp32p4rev1;
            case ESP32C61_CHIP: self.info_.name = "ESP32-C61"; return &esp_stub_esp32c61;
            case ESP32S31_CHIP: self.info_.name = "ESP32-S31"; return &esp_stub_esp32s31;
            case ESP32H21_CHIP: self.info_.name = "ESP32-H21"; return &esp_stub_esp32h21;
            case ESP32H4_CHIP: self.info_.name = "ESP32-H4"; return &esp_stub_esp32h4;
            default: return nullptr;
        }
    } catch (const std::exception &error) { self.callbackError_ = error.what(); return nullptr; }
}
EspChipInfo EspNativeCore::connect(bool reset, bool nativeUsb, bool usbJtag, bool allowUnreviewed) {
    resetRequested_ = reset; nativeUsb_ = nativeUsb; usbJtag_ = usbJtag;
    allowUnreviewed_ = allowUnreviewed;
    esp_loader_connect_args_t args{2000, reset ? 7 : 2};
    check(esp_loader_connect_with_stub_provider(&loader_, &args, stubProvider, this), "Connect official flasher stub");
    check(esp_loader_flash_detect_size(&loader_, &info_.flashBytes), "Detect physical flash capacity");
    if (!info_.flashBytes || info_.flashBytes > (256U << 20)) throw std::runtime_error("Unknown flash capacity");
    connected_ = true; identity(info_.mac); return info_;
}
void EspNativeCore::range(uint32_t offset, uint32_t length) {
    if (!connected_ || !length || static_cast<uint64_t>(offset) + length > info_.flashBytes)
        throw std::runtime_error("Flash region is outside the detected capacity");
}
std::string EspNativeCore::md5(const uint8_t *data, size_t length) {
    MD5Context context; uint8_t digest[16]; MD5Init(&context);
    MD5Update(&context, data, static_cast<unsigned>(length)); MD5Final(digest, &context);
    return hex(digest, sizeof(digest));
}
void EspNativeCore::verifyMd5(uint32_t offset, uint32_t length, const std::string &expected) {
    if (expected.size() != 32 || expected.find_first_not_of("0123456789abcdef") != std::string::npos)
        throw std::runtime_error("Invalid verification digest");
    check(esp_loader_flash_verify_known_md5(&loader_, offset, length,
          reinterpret_cast<const uint8_t *>(expected.data())), "Verify exact flash payload MD5");
}
std::vector<uint8_t> EspNativeCore::read(uint32_t offset, uint32_t length, const std::string &mac) {
    identity(mac); range(offset, length);
    if (length > 65536) throw std::runtime_error("Flash reads must be bounded to64KiB");
    std::vector<uint8_t> bytes(length);
    check(esp_loader_flash_read(&loader_, bytes.data(), offset, length), "Read verified flash bytes");
    verifyMd5(offset, length, md5(bytes.data(), bytes.size())); identity(mac);
    return bytes;
}
void EspNativeCore::write(uint32_t offset, const std::vector<uint8_t> &bytes,
                          const std::string &mac, const std::string &expected) {
    identity(mac); range(offset, static_cast<uint32_t>(bytes.size()));
    if (offset % 4096 || bytes.empty() || bytes.size() > (32U << 20)) throw std::runtime_error("Invalid flash write geometry");
    if (md5(bytes.data(), bytes.size()) != expected) throw std::runtime_error("Firmware payload digest changed before write");
    std::vector<uint8_t> padded(bytes); padded.resize((bytes.size() + 3) & ~size_t(3), 0xff);
    range(offset, static_cast<uint32_t>(padded.size()));
    uLongf length = compressBound(padded.size()); std::vector<uint8_t> compressed(length);
    if (compress2(compressed.data(), &length, padded.data(), padded.size(), Z_DEFAULT_COMPRESSION) != Z_OK)
        throw std::runtime_error("Unable to compress firmware");
    compressed.resize(length);
    esp_loader_flash_deflate_cfg_t cfg{};
    cfg.offset = offset; cfg.image_size = padded.size(); cfg.compressed_size = compressed.size(); cfg.block_size = 16384;
    check(esp_loader_flash_deflate_start(&loader_, &cfg), "Start sector-only compressed flash write");
    for (size_t i = 0; i < compressed.size(); i += cfg.block_size)
        check(esp_loader_flash_deflate_write(&loader_, &cfg, compressed.data() + i,
              std::min<size_t>(cfg.block_size, compressed.size() - i)), "Write compressed flash block");
    // Verify before ending, and again after ending (stay in loader). Never reboot
    // on failed verification. Verify exactly original bytes, not alignment padding.
    verifyMd5(offset, bytes.size(), expected);
    check(esp_loader_flash_deflate_finish(&loader_, &cfg), "Finish flash write without reboot");
    verifyMd5(offset, bytes.size(), expected); identity(mac);
}
void EspNativeCore::erase(const std::string &mac) {
    identity(mac);
    check(esp_loader_flash_erase(&loader_), "Erase physical flash");
    MD5Context hash; MD5Init(&hash); std::array<uint8_t,4096> erased{}; erased.fill(0xff);
    for (uint32_t read = 0; read < info_.flashBytes; read += erased.size())
        MD5Update(&hash, erased.data(), std::min<uint32_t>(erased.size(), info_.flashBytes - read));
    uint8_t digest[16]; MD5Final(digest, &hash);
    verifyMd5(0, info_.flashBytes, hex(digest, sizeof(digest))); identity(mac);
}
void EspNativeCore::runApplication(const std::string &mac) {
    identity(mac);
    const int chip = info_.chip;
    if (nativeUsb_ && chip != 2 && chip != 5 && chip != 9)
        throw std::runtime_error("Manual reset required: flash is verified, but this chip's native USB application-reset path is not qualified. Disconnect USB and reset the node manually.");
    if (chip == 9) maskedWrite(0x6000812c, 0, 1);
    if (chip == 5) maskedWrite(0x600080f4, 0, 1);
    if (chip == 2) maskedWrite(0x3f408128, 0, 1);
    if (nativeUsb_ && (chip == 2 || chip == 5 || chip == 9)) {
        const uint32_t unlock = chip == 9 ? 0x600080b0 : chip == 5 ? 0x600080a8 : 0x3f4080ac;
        const uint32_t timeout = chip == 9 ? 0x6000809c : chip == 5 ? 0x60008094 : 0x3f408098;
        const uint32_t config = chip == 9 ? 0x60008098 : chip == 5 ? 0x60008090 : 0x3f408094;
        maskedWrite(unlock, 0x50d83aa1, UINT32_MAX); maskedWrite(timeout, 2000, UINT32_MAX);
        maskedWrite(config, 0xd0000102, UINT32_MAX); maskedWrite(unlock, 0, UINT32_MAX);
        transport_.delay(500);
    } else {
        // Intentional launch only. Passive reconnect/cancel/close never reach it.
        portReset(&port_.base); check(ESP_LOADER_SUCCESS, "Launch application");
    }
    connected_ = false;
}
}
