#pragma once
#include <cstdint>
#include <string>
#include <stdexcept>
#include <vector>
extern "C" {
#include "esp_loader.h"
}

namespace meshcore {
struct EspTransportTimeout : std::runtime_error { using std::runtime_error::runtime_error; };
struct EspTransport {
    virtual ~EspTransport() = default;
    virtual void read(uint8_t *data, size_t size, uint32_t timeout) = 0;
    virtual void write(const uint8_t *data, size_t size, uint32_t timeout) = 0;
    virtual void signals(bool dtr, bool rts) = 0;
    virtual void baud(uint32_t value) = 0;
    virtual void delay(uint32_t ms) = 0;
    virtual bool cancelled() = 0;
};
struct EspChipInfo { int chip; uint32_t flashBytes; std::string mac, name; };

// A single instance belongs to one descriptor-checked raw USB connection.
// No API can burn eFuses or write arbitrary registers from the platform channel.
class EspNativeCore {
public:
    explicit EspNativeCore(EspTransport &transport);
    ~EspNativeCore();
    EspChipInfo connect(bool reset, bool nativeUsb, bool hardwareUsbJtag, bool allowUnreviewed = false);
    std::vector<uint8_t> read(uint32_t offset, uint32_t length, const std::string &mac);
    void write(uint32_t offset, const std::vector<uint8_t> &data, const std::string &mac,
               const std::string &expectedMd5);
    void erase(const std::string &mac);
    void runApplication(const std::string &mac);
    const EspChipInfo &info() const { return info_; }
    static int imageChipId(target_chip_t target);
    static bool securityAllows(uint32_t flags, uint8_t flashCryptCount);
    static std::string md5(const uint8_t *data, size_t size);
private:
    struct Port { esp_loader_port_t base{}; EspNativeCore *owner; uint64_t deadline = 0; } port_;
    EspTransport &transport_;
    esp_loader_t loader_{};
    EspChipInfo info_{};
    bool initialized_ = false, connected_ = false, securityVerified_ = false;
    bool resetRequested_ = false, resetPerformed_ = false, nativeUsb_ = false, usbJtag_ = false;
    bool allowUnreviewed_ = false;
    uint32_t ecoVersion_ = 0;
    std::string callbackError_;
    void check(esp_loader_error_t code, const char *operation);
    void range(uint32_t offset, uint32_t length);
    std::string readMac();
    void identity(const std::string &expected);
    void securityBeforeStub(target_chip_t target);
    void disableNativeWatchdogs(target_chip_t target);
    void maskedWrite(uint32_t address, uint32_t value, uint32_t mask);
    void verifyMd5(uint32_t offset, uint32_t length, const std::string &expected);
    static const esp_stub_t *stubProvider(esp_loader_t *, target_chip_t, void *);
    static EspNativeCore &owner(esp_loader_port_t *port);
    static esp_loader_error_t portRead(esp_loader_port_t *, uint8_t *, uint16_t, uint32_t);
    static esp_loader_error_t portWrite(esp_loader_port_t *, const uint8_t *, uint16_t, uint32_t);
    static esp_loader_error_t portBaud(esp_loader_port_t *, uint32_t);
    static void portEnter(esp_loader_port_t *);
    static void portReset(esp_loader_port_t *);
    static void portTimer(esp_loader_port_t *, uint32_t);
    static uint32_t portRemaining(esp_loader_port_t *);
    static void portDelay(esp_loader_port_t *, uint32_t);
};
}
