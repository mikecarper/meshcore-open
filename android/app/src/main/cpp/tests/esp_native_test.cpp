#include "esp_native_core.h"
#include <algorithm>
#include <deque>
#include <iostream>
#include <map>
#include <stdexcept>
#include <tuple>
#include <zlib.h>
extern "C" {
#include "protocol.h"
}
using meshcore::EspNativeCore;
static void require(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
static uint32_t word(const std::vector<uint8_t> &v, size_t n) {
    return v.at(n) | (uint32_t(v.at(n+1)) << 8) | (uint32_t(v.at(n+2)) << 16) | (uint32_t(v.at(n+3)) << 24);
}
static void put(std::vector<uint8_t> &v, uint32_t n) { for (int i=0;i<4;i++) v.push_back(n >> (i*8)); }
static std::vector<uint8_t> unhex(const std::string &s) {
    std::vector<uint8_t> out; for(size_t i=0;i<s.size();i+=2) out.push_back(std::stoul(s.substr(i,2),nullptr,16)); return out;
}
// Hermetic ROM/stub peer: real official library SLIP and command encoders run
// against this peer, without USB, Flutter, WebView, firmware downloads or resets.
struct Rom final : meshcore::EspTransport {
    std::deque<uint8_t> incoming;
    std::vector<uint8_t> frame, compressed, flash = std::vector<uint8_t>(1<<20,0xff);
    std::vector<uint8_t> commands;
    std::vector<std::tuple<uint32_t,uint32_t,uint32_t>> writes;
    std::vector<std::pair<bool,bool>> pins;
    std::map<uint32_t,uint32_t> registers;
    uint32_t securityFlags=0, chip=9, offset=0, imageSize=0;
    uint8_t crypt=0;
    bool escaped=false, stop=false, badMd5=false, changedMac=false, timeoutOnce=false;
    uint32_t macAddress() {
        switch(chip) {
          case 0:return 0x3ff5a004; case 2:return 0x3f41a044; case 5:return 0x60008844;
          case 9:return 0x60007044; case 12:return 0x60008840; case 13:case 16:return 0x600b0844;
          case 18:return 0x5012d044; case 20:case 23:return 0x600b4844; case 25:return 0x600b4044;
          case 28:return 0x600b1844; case 32:return 0x20715050; default:return 0;
        }
    }
    void packet(const std::vector<uint8_t> &data) {
        incoming.push_back(0xc0);
        for(auto byte:data) { if(byte==0xc0 || byte==0xdb) { incoming.push_back(0xdb); incoming.push_back(byte==0xc0?0xdc:0xdd); } else incoming.push_back(byte); }
        incoming.push_back(0xc0);
    }
    void response(uint8_t cmd, uint32_t value=0, std::vector<uint8_t> data={}) {
        std::vector<uint8_t> result{1,cmd,uint8_t(data.size()+2),0}; put(result,value);
        result.insert(result.end(),data.begin(),data.end()); result.push_back(0); result.push_back(0); packet(result);
    }
    void command() {
        if(frame.size()==4) return; // raw flash-read acknowledgements
        require(frame.size()>=8,"short command"); auto cmd=frame[1]; commands.push_back(cmd);
        if(cmd==SYNC) { for(int i=0;i<8;i++) response(cmd); }
        else if(cmd==GET_SECURITY_INFO) { std::vector<uint8_t> data; put(data,securityFlags); data.push_back(crypt); data.resize(12,0); put(data,chip); put(data,0); response(cmd,0,data); }
        else if(cmd==READ_REG) {
            auto address=word(frame,8); uint32_t value=registers[address];
            if(address==macAddress()) value=changedMac?0xccddeefe:0xccddeeff;
            if(address==macAddress()+4) value=0xaabb;
            if(address==0x60002000 || address==0x60003000 || address==0x3f402000 || address==0x3ff42000 || address==0x5008d000 || address==0x20501000 || address==0x60099000) value=0;
            if(address==0x60002058 || address==0x60003058 || address==0x3f402058 || address==0x3ff42080 || address==0x5008d058 || address==0x20501058 || address==0x60099058) value=0x140000; //1MiB JEDEC
            response(cmd,value);
        } else if(cmd==WRITE_REG) {
            auto a=word(frame,8),v=word(frame,12),m=word(frame,16); writes.emplace_back(a,v,m); registers[a]=(registers[a]&~m)|(v&m); response(cmd);
        } else if(cmd==MEM_END) { response(cmd); packet({'O','H','A','I'}); }
        else if(cmd==FLASH_DEFL_BEGIN) { imageSize=word(frame,8); offset=word(frame,20); compressed.clear(); response(cmd); }
        else if(cmd==FLASH_DEFL_DATA) {
            auto size=word(frame,8); compressed.insert(compressed.end(),frame.begin()+24,frame.begin()+24+size);
            std::vector<uint8_t> data(imageSize); uLongf len=imageSize;
            if(uncompress(data.data(),&len,compressed.data(),compressed.size())==Z_OK) std::copy(data.begin(),data.end(),flash.begin()+offset);
            response(cmd);
        } else if(cmd==SPI_FLASH_MD5) {
            auto start=word(frame,8),size=word(frame,12); auto digest=unhex(EspNativeCore::md5(flash.data()+start,size));
            if(badMd5) digest[0]^=1; response(cmd,0,digest);
        } else if(cmd==ERASE_FLASH) { std::fill(flash.begin(),flash.end(),0xff); response(cmd); }
        else if(cmd==READ_FLASH_STUB) {
            auto start=word(frame,8),size=word(frame,12),block=word(frame,16); response(cmd);
            for(uint32_t n=0;n<size;n+=block) packet(std::vector<uint8_t>(flash.begin()+start+n,flash.begin()+start+std::min(size,n+block)));
            packet(unhex(EspNativeCore::md5(flash.data()+start,size)));
        } else response(cmd);
    }
    void write(const uint8_t *data,size_t size,uint32_t) override {
        for(size_t n=0;n<size;n++) { auto byte=data[n];
            if(byte==0xc0) { if(!frame.empty()) { command(); frame.clear(); } escaped=false; }
            else if(byte==0xdb) escaped=true;
            else { frame.push_back(escaped?(byte==0xdc?0xc0:0xdb):byte); escaped=false; }
        }
    }
    void read(uint8_t *data,size_t size,uint32_t) override { if(timeoutOnce) { timeoutOnce=false; incoming.clear(); throw meshcore::EspTransportTimeout("test timeout"); } require(incoming.size()>=size,"peer queue exhausted"); for(size_t n=0;n<size;n++) { data[n]=incoming.front(); incoming.pop_front(); } }
    void signals(bool dtr,bool rts) override { pins.emplace_back(dtr,rts); }
    void delay(uint32_t) override {}
    void baud(uint32_t) override {}
    bool cancelled() override { return stop; }
    size_t count(uint8_t cmd) const { return std::count(commands.begin(),commands.end(),cmd); }
};
template<class F> static void refuses(F action,const char *message) { bool failed=false; try { action(); } catch(const std::exception &) { failed=true; } require(failed,message); }
int main() {
 try {
    require(EspNativeCore::imageChipId(ESP32C6_CHIP)==13,"C6 image ID");
    require(EspNativeCore::imageChipId(ESP32C2_CHIP)==12,"C2 image ID");
    require(EspNativeCore::imageChipId(ESP32S31_CHIP)==32,"S31 image ID");
    require(EspNativeCore::imageChipId(ESP8266_CHIP)==-1,"unsupported identity target");
    for(uint32_t flags : {1U,4U,256U}) require(!EspNativeCore::securityAllows(flags,0),"security flags");
    require(!EspNativeCore::securityAllows(0,1),"encrypted parity"); require(EspNativeCore::securityAllows(0,3),"even parity");
    require(EspNativeCore::md5(reinterpret_cast<const uint8_t*>("abc"),3)=="900150983cd24fb0d6963f7d28e17f72","MD5 vector");
    for(uint32_t chip : {0U,2U,5U,9U,12U,13U,16U,18U,20U,23U,25U,28U,32U}) {
        Rom peer; peer.chip=chip; EspNativeCore engine(peer); auto info=engine.connect(false,false,false,true);
        require(info.chip==int(chip) && info.mac=="aabbccddeeff","all upstream ESP32 identity/image-ID mappings");
        require(peer.pins.empty(),"expert passive connect reset");
    }
    for(bool encryption : {false,true}) { Rom r; r.securityFlags=encryption?0:1; r.crypt=encryption?1:0; EspNativeCore c(r);
        refuses([&]{c.connect(false,true,true);},"secured target accepted"); require(r.count(MEM_BEGIN)==0 && r.writes.empty() && r.pins.empty(),"security before stub/reset/register mutations"); }
    { Rom r; r.chip=13; EspNativeCore c(r); refuses([&]{c.connect(false,true,true);},"unreviewed normal accepted"); require(r.count(MEM_BEGIN)==0,"normal C6 loaded stub"); }
    { Rom r; r.chip=13; EspNativeCore c(r); auto info=c.connect(false,true,true,true); require(info.chip==13,"expert C6 mapping");
      auto before=r.writes.size(); refuses([&]{c.runApplication(info.mac);},"guessed native C6 reset"); require(r.writes.size()==before && r.pins.empty(),"unqualified reset changed controls"); }
    Rom r; std::string mac;
    { EspNativeCore c(r); auto info=c.connect(false,true,true); mac=info.mac;
      require(mac=="aabbccddeeff" && info.flashBytes==(1U<<20),"ROM identity/capacity"); require(r.pins.empty(),"passive connect reset");
      std::vector<uint8_t> data(5003); for(size_t n=0;n<data.size();n++) data[n]=uint8_t(n);
      auto digest=EspNativeCore::md5(data.data(),data.size());
      auto start=r.count(FLASH_DEFL_BEGIN); refuses([&]{c.write(0,data,"aabbccddeefe",digest);},"wrong MAC accepted");
      refuses([&]{c.write(0,data,mac,std::string(32,'0'));},"bad input digest accepted");
      refuses([&]{c.write(1,data,mac,digest);},"unaligned write accepted");
      refuses([&]{c.write((1U<<20)-4096,data,mac,digest);},"over-capacity accepted");
      require(r.count(FLASH_DEFL_BEGIN)==start,"invalid write reached erase/write");
      c.write(0,data,mac,digest); require(c.read(0,data.size(),mac)==data,"exact readback");
      require(r.count(SPI_FLASH_MD5)>=3,"target postwrite/read digest missing");
      r.changedMac=true; start=r.count(ERASE_FLASH); refuses([&]{c.erase(mac);},"changed physical MAC accepted"); require(r.count(ERASE_FLASH)==start,"wrong-node erase"); r.changedMac=false;
      r.badMd5=true; refuses([&]{c.write(4096,data,mac,digest);},"bad target digest accepted"); require(r.pins.empty(),"verification failure reset"); r.badMd5=false;
      c.erase(mac); require(std::all_of(r.flash.begin(),r.flash.end(),[](uint8_t n){return n==0xff;}),"erase result");
      r.registers[0x6000812c]=0x11; c.runApplication(mac);
      require(r.registers[0x6000812c]==0x10,"force-ROM masked clear"); require(r.pins.empty(),"native watchdog launched via wrong pins");
    }
    require(r.pins.empty(),"destructor reset");
    { Rom reset; EspNativeCore c(reset); c.connect(true,false,false); require(reset.pins==std::vector<std::pair<bool,bool>>{{false,true},{true,false},{false,false}},"explicit UART reset order"); }
    { Rom retry; retry.timeoutOnce=true; EspNativeCore c(retry); c.connect(false,true,true); require(retry.count(SYNC)==2 && retry.pins.empty(),"bounded sync timeout retry/passive reset"); }
    { Rom c3; c3.chip=5; EspNativeCore c(c3); auto info=c.connect(false,true,true); c3.registers[0x600080f4]=0x21; c.runApplication(info.mac); require(c3.registers[0x600080f4]==0x20 && c3.pins.empty(),"C3 force-ROM masked clear/native launch"); }
    { Rom cancel; EspNativeCore c(cancel); cancel.stop=true; refuses([&]{c.connect(false,true,true);},"cancel accepted"); require(cancel.pins.empty(),"cancel/passive reset"); }
    std::cout << "Native ESP protocol/identity/security/hash/reset tests passed\n"; return 0;
 } catch(const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}
